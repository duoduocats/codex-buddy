import AppKit
import Combine
import CryptoKit
import ImageIO

struct CloudInstalledPet:Identifiable,Equatable {
    let id:String,name:String
    let imageURL:URL?
    let imageExpiresAt:Date?
    let updatedAt:Date?
    static func validImageURL(_ url:URL) -> Bool {
        guard let c=URLComponents(url:url,resolvingAgainstBaseURL:false),c.scheme == "https",c.user == nil,c.password == nil,c.fragment == nil,
              c.port == nil || c.port == 443,url.absoluteString.utf8.count <= 16_384,let host=c.host?.lowercased() else { return false }
        return host == "chatgpt.com" || host == "files.oaiusercontent.com" || host.hasSuffix(".oaiusercontent.com") || host == "oaidalleapiprodscus.blob.core.windows.net"
    }
}
struct CloudPetPage {
    let pets:[CloudInstalledPet],cursor:String?,accountKey:String
    static func decode(_ data:Data,accountKey:String) throws -> CloudPetPage {
        guard data.count <= 1_000_000,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let rows=root["pets"] as? [[String:Any]],rows.count <= 20 else { throw UsageFailure.malformed }
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let plain=ISO8601DateFormatter()
        func date(_ value:Any?) -> Date? { (value as? String).flatMap { formatter.date(from:$0) ?? plain.date(from:$0) } }
        let pets=try rows.compactMap { row -> CloudInstalledPet? in
            guard let id=row["id"] as? String,!id.isEmpty,id.utf8.count <= 180,
                  id.unicodeScalars.allSatisfy({CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)}) else {throw UsageFailure.malformed}
            // The service includes built-in choices; Codex's custom list uses the pet_ namespace.
            guard id.hasPrefix("pet_") else {return nil}
            guard id.count > 4,
                  let name=row["name"] as? String,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count <= 160,
                  !name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw UsageFailure.malformed }
            let image=(row["spritesheet_url"] as? String).flatMap(URL.init(string:)).flatMap { CloudInstalledPet.validImageURL($0) ? $0 : nil }
            return .init(id:id,name:name,imageURL:image,imageExpiresAt:date(row["spritesheet_url_expires_at"]),updatedAt:date(row["updated_at"]))
        }
        guard root["cursor"] == nil || root["cursor"] is NSNull || root["cursor"] is String else { throw UsageFailure.malformed }
        let cursor=(root["cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard cursor == nil || cursor!.utf8.count <= 2048 else { throw UsageFailure.malformed }
        return .init(pets:pets,cursor:cursor,accountKey:accountKey)
    }
}
@MainActor protocol CloudPetFetching {
    func accountKey() -> String?
    func page(cursor:String?) async throws -> CloudPetPage
    func delete(petID:String,accountKey:String) async throws
}
extension CloudPetFetching {
    func delete(petID:String,accountKey:String) async throws {throw UsageFailure.unavailable}
}
struct CloudPetDeletionRequest:Identifiable {
    let id=UUID()
    let pet:CloudInstalledPet
    let accountKey:String
}
@MainActor final class CloudPetClient:CloudPetFetching {
    private let client:UsageClient
    private let salt:Data
    init(client:UsageClient? = nil,salt:Data? = nil) {
        self.client=client ?? UsageClient(petTransfer:{BuddyNetworkSettings.recordTransfer(.catalog,bytes:$0,complete:$1)})
        self.salt=salt ?? Data((0..<32).map { _ in UInt8.random(in:0...255) })
    }
    func accountKey() -> String? { client.petAccountKey(identitySalt:salt) }
    func delete(petID:String,accountKey:String) async throws {
        guard self.accountKey() == accountKey else {throw CancellationError()}
        try await client.deletePet(id:petID,identitySalt:salt,expectedAccountKey:accountKey)
        guard self.accountKey() == accountKey else {throw CancellationError()}
    }
    func page(cursor:String?) async throws -> CloudPetPage {
        let result=try await client.readPetPage(cursor:cursor,identitySalt:salt)
        guard let key=result.accountKey,key == accountKey() else { throw CancellationError() }
        return try CloudPetPage.decode(result.data,accountKey:key)
    }
}
// Metadata and temporary image URLs stay in memory; fetching is driven by visible-page actions.
@MainActor final class PetCloudLibrary:ObservableObject {
    @Published private(set) var pets=[CloudInstalledPet]()
    @Published private(set) var loading=false
    @Published private(set) var unavailable=false
    @Published var deletionRequest:CloudPetDeletionRequest?
    @Published private(set) var deletingPetID:String?
    @Published private(set) var deletionMessage:String?
    @Published private(set) var deletionFailed=false
    private var deletionTask:Task<Void,Never>?
    private var removedIDs=Set<String>()
    @Published private(set) var previewRevision=0
    @Published private(set) var previewing=Set<String>()
    @Published private(set) var previewErrors=Set<String>()
    private let client:CloudPetFetching
    private var visible=false
    private var account:String?
    private var fetchedAt=Date.distantPast,attemptedAt=Date.distantPast
    private var task:Task<Void,Never>?
    private var generation=0
    private var previews=[String:Task<Void,Never>]()
    private var activePreviewLoads=0
    private var previewTickets=[String:UUID]()
    private var visiblePreviewRows=[UUID:String]()
    private var pendingPreviews=[String]()
    private var manualPreviews=Set<String>()
    private var attemptedPreviews=Set<String>()
    private var previewURLRefreshedAt=Date.distantPast
    private let imageFetcher:(URL) async throws -> Data
    private let images=NSCache<NSString,NSImage>()
    init(client:CloudPetFetching,imageFetcher:@escaping(URL) async throws -> Data = { try await PetHTTPClient().cloudImage(from:$0,limit:32_000_000) }) {
        self.client=client;self.imageFetcher=imageFetcher;images.countLimit=24;images.totalCostLimit=8_000_000
    }
    func setVisible(_ value:Bool) {
        visible=value
        if !value {deletionRequest=nil}
        if value { refresh();scheduleVisiblePreviews() } else { generation += 1;task?.cancel();task=nil;loading=false;cancelPreviews() }
    }
    private func cancelPreviews(keepManual:Bool = false) {
        previews.values.forEach {$0.cancel()};previews=[:];previewTickets=[:];pendingPreviews=[];if !keepManual {manualPreviews=[]};attemptedPreviews=[];previewing=[]
    }
    private func clearAccount() {
        generation += 1;task?.cancel();task=nil;cancelPreviews();pets=[];previewErrors=[];images.removeAllObjects();previewRevision += 1
        deletionRequest=nil;deletionMessage=nil;removedIDs=[]
        loading=false;fetchedAt = .distantPast;attemptedAt = .distantPast;previewURLRefreshedAt = .distantPast
    }
    func refresh(force:Bool = false,now:Date = Date()) {
        guard visible else { return }
        let key=client.accountKey()
        if account != key { clearAccount();account=key }
        guard let key else { clearAccount();account=nil;unavailable=true;return }
        guard deletionTask == nil else {return}
        guard task == nil,force || now.timeIntervalSince(fetchedAt) >= 300,force || now.timeIntervalSince(attemptedAt) >= 10 else { return }
        deletionRequest=nil;cancelPreviews(keepManual:true);attemptedAt=now;generation += 1;let ticket=generation;loading=true;unavailable=false
        task=Task {
            defer {if ticket == generation {loading=false;task=nil;scheduleVisiblePreviews()}}
            do {
                var rows=[CloudInstalledPet](),seen=Set<String>(),cursor:String?
                for index in 0..<50 {
                    let page=try await client.page(cursor:cursor)
                    guard !Task.isCancelled,visible,ticket == generation,page.accountKey == key,client.accountKey() == key else {
                        if ticket == generation && client.accountKey() != key {clearAccount();account=nil};return
                    }
                    rows += page.pets;guard rows.count <= 1000 else {throw UsageFailure.malformed};cursor=page.cursor
                    if cursor == nil {break}
                    guard index < 49,seen.insert(cursor!).inserted else {throw UsageFailure.malformed}
                }
                var identities=Set<String>()
                removedIDs.formIntersection(Set(rows.map(\.id)))
                let result=rows.filter {!removedIDs.contains($0.id) && identities.insert($0.id).inserted}.sorted {
                    if $0.updatedAt != $1.updatedAt {return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)}
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                for old in pets {
                    guard let current=result.first(where:{$0.id == old.id}) else {
                        images.removeObject(forKey:old.id as NSString);previewErrors.remove(old.id);continue
                    }
                    if current.updatedAt != old.updatedAt || current.imageURL != old.imageURL {
                        images.removeObject(forKey:old.id as NSString)
                    }
                    if current.imageURL != old.imageURL || current.imageExpiresAt != old.imageExpiresAt || current.updatedAt != old.updatedAt {previewErrors.remove(old.id)}
                }
                manualPreviews.formIntersection(Set(result.map(\.id)))
                if pets != result {pets=result};fetchedAt=now
            } catch {
                guard !Task.isCancelled,visible,ticket == generation else {return}
                if client.accountKey() != key || (error as? UsageFailure) == .authentication {clearAccount();account=nil};unavailable=true
            }
        }
    }
    func requestDeletion(_ pet:CloudInstalledPet) {
        guard visible,!loading,deletionTask == nil,let key=account,key == client.accountKey(),
              let current=pets.first(where:{$0 == pet}),pet.id.hasPrefix("pet_") else {return}
        deletionMessage=nil;deletionRequest = .init(pet:current,accountKey:key)
    }
    func cancelDeletion() {deletionRequest=nil}
    func confirmDeletion() {
        guard visible,!loading,deletionTask == nil,let request=deletionRequest else {return}
        deletionRequest=nil
        guard account == request.accountKey,client.accountKey() == request.accountKey else {
            clearAccount();account=nil;unavailable=true;return
        }
        guard pets.contains(request.pet) else {return}
        task?.cancel();task=nil;generation += 1;loading=false;cancelPreviews()
        deletingPetID=request.pet.id;deletionFailed=false;deletionMessage=nil
        deletionTask=Task {
            defer {deletingPetID=nil;deletionTask=nil;scheduleVisiblePreviews()}
            do {
                try await client.delete(petID:request.pet.id,accountKey:request.accountKey)
                guard account == request.accountKey,client.accountKey() == request.accountKey else {
                    if account == request.accountKey {clearAccount();account=nil}
                    return
                }
                removedIDs.insert(request.pet.id);pets.removeAll {$0.id == request.pet.id}
                images.removeObject(forKey:request.pet.id as NSString);previewErrors.remove(request.pet.id);previewRevision += 1
                fetchedAt = .distantPast
                deletionMessage=L("已从云端删除“\(request.pet.name)”。", "Deleted “\(request.pet.name)” from the cloud.")
            } catch {
                guard account == request.accountKey,client.accountKey() == request.accountKey else {
                    if account == request.accountKey {clearAccount();account=nil}
                    return
                }
                fetchedAt = .distantPast;deletionFailed=true
                deletionMessage=L("未能确认删除结果。请刷新列表，确认后再重试。", "Deletion could not be confirmed. Refresh the list before trying again.")
            }
        }
    }
    func finishDeletion() async {await deletionTask?.value}
    func image(for pet:CloudInstalledPet) -> NSImage? {images.object(forKey:pet.id as NSString)}
    func setPreviewVisible(_ pet:CloudInstalledPet,token:UUID,_ value:Bool) {
        if value {
            visiblePreviewRows[token]=pet.id;scheduleVisiblePreviews()
        } else if let id=visiblePreviewRows.removeValue(forKey:token),!visiblePreviewRows.values.contains(id) {
            manualPreviews.remove(id);attemptedPreviews.remove(id);pendingPreviews.removeAll {$0 == id}
            previews.removeValue(forKey:id)?.cancel();previewTickets[id]=nil;previewing.remove(id)
            scheduleVisiblePreviews()
        }
    }
    func preview(_ pet:CloudInstalledPet) {
        guard visible,pets.contains(where:{$0.id == pet.id}),images.object(forKey:pet.id as NSString) == nil else {return}
        previewErrors.remove(pet.id);attemptedPreviews.remove(pet.id);manualPreviews.insert(pet.id)
        if let current=pets.first(where:{$0.id == pet.id}),current.imageExpiresAt.map({$0 <= Date()}) == true,!loading {
            previewURLRefreshedAt=Date();refresh(force:true)
        } else {scheduleVisiblePreviews()}
    }
    private func scheduleVisiblePreviews(discover:Bool = true) {
        guard visible,!loading,deletionTask == nil,let key=account,key == client.accountKey() else {return}
        let wanted=Set(visiblePreviewRows.values).union(manualPreviews)
        var expired=false
        for pet in pets where discover && wanted.contains(pet.id) {
            guard images.object(forKey:pet.id as NSString) == nil,previews[pet.id] == nil,
                  !pendingPreviews.contains(pet.id),!previewErrors.contains(pet.id),!attemptedPreviews.contains(pet.id),
                  let url=pet.imageURL,CloudInstalledPet.validImageURL(url),let expiry=pet.imageExpiresAt else {continue}
            if expiry <= Date() {previewErrors.insert(pet.id);manualPreviews.remove(pet.id);expired=true;continue}
            pendingPreviews.append(pet.id);previewing.insert(pet.id)
        }
        // Refresh expired signed URLs once for the visible set, rather than once
        // per row. Unchanged/failed results stay retryable without a fetch loop.
        if expired,Date().timeIntervalSince(previewURLRefreshedAt) >= 30 {
            previewURLRefreshedAt=Date();refresh(force:true);return
        }
        while activePreviewLoads < 2,!pendingPreviews.isEmpty {
            let id=pendingPreviews.removeFirst()
            guard wanted.contains(id),let pet=pets.first(where:{$0.id == id}),let url=pet.imageURL,
                  let expiry=pet.imageExpiresAt,expiry > Date() else {previewing.remove(id);continue}
            beginPreview(pet,url:url,accountKey:key)
        }
    }
    private func beginPreview(_ pet:CloudInstalledPet,url:URL,accountKey key:String) {
        let ticket=generation,operation=UUID();previewTickets[pet.id]=operation;attemptedPreviews.insert(pet.id)
        activePreviewLoads += 1
        previews[pet.id]=Task {
            defer {
                activePreviewLoads -= 1
                if ticket == generation,previewTickets[pet.id] == operation {
                    previews[pet.id]=nil;previewTickets[pet.id]=nil;previewing.remove(pet.id);manualPreviews.remove(pet.id)
                }
                scheduleVisiblePreviews(discover:ticket == generation)
            }
            do {
                try Task.checkCancellation()
                let data=try await imageFetcher(url)
                try Task.checkCancellation()
                let thumbnail=try await Task.detached(priority:.utility) {() -> CGImage in
                    guard data.count <= 32_000_000,let source=CGImageSourceCreateWithData(data as CFData,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                          properties[kCGImagePropertyPixelWidth] as? Int == 1536,[1872,2288].contains(properties[kCGImagePropertyPixelHeight] as? Int ?? 0) else {throw PetStoreError.invalidImage}
                    return try PetSprite.thumbnailImage(data,sprite:true)
                }.value
                guard !Task.isCancelled,visible,ticket == generation,previewTickets[pet.id] == operation,
                      key == account,key == client.accountKey(),pets.contains(pet) else {return}
                images.setObject(NSImage(cgImage:thumbnail,size:NSSize(width:thumbnail.width,height:thumbnail.height)),forKey:pet.id as NSString,cost:thumbnail.width*thumbnail.height*4);previewRevision += 1
            } catch {
                if !Task.isCancelled,visible,ticket == generation,previewTickets[pet.id] == operation,key == account,key == client.accountKey() {previewErrors.insert(pet.id)}
            }
        }
    }
    func clearImages() {deletionRequest=nil;generation += 1;task?.cancel();task=nil;loading=false;cancelPreviews();images.removeAllObjects();previewErrors=[];previewRevision += 1}
    func finish() async {await task?.value}
}
