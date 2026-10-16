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
}
@MainActor final class CloudPetClient:CloudPetFetching {
    private let client:UsageClient
    private let salt:Data
    init(client:UsageClient? = nil,salt:Data? = nil) {
        self.client=client ?? UsageClient(petTransfer:{BuddyNetworkSettings.recordTransfer(.catalog,bytes:$0,complete:$1)})
        self.salt=salt ?? Data((0..<32).map { _ in UInt8.random(in:0...255) })
    }
    func accountKey() -> String? { client.petAccountKey(identitySalt:salt) }
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
    private let images=NSCache<NSString,NSImage>()
    init(client:CloudPetFetching) { self.client=client;images.countLimit=24;images.totalCostLimit=8_000_000 }
    func setVisible(_ value:Bool) {
        visible=value
        if value { refresh() } else { generation += 1;task?.cancel();task=nil;loading=false;cancelPreviews() }
    }
    private func cancelPreviews() { previews.values.forEach {$0.cancel()};previews=[:];previewing=[] }
    private func clearAccount() {
        generation += 1;task?.cancel();task=nil;cancelPreviews();pets=[];previewErrors=[];images.removeAllObjects();previewRevision += 1
        loading=false;fetchedAt = .distantPast;attemptedAt = .distantPast
    }
    func refresh(force:Bool = false,now:Date = Date()) {
        guard visible else { return }
        let key=client.accountKey()
        if account != key { clearAccount();account=key }
        guard let key else { clearAccount();account=nil;unavailable=true;return }
        guard task == nil,force || now.timeIntervalSince(fetchedAt) >= 300,force || now.timeIntervalSince(attemptedAt) >= 10 else { return }
        cancelPreviews();attemptedAt=now;generation += 1;let ticket=generation;loading=true;unavailable=false
        task=Task {
            defer {if ticket == generation {loading=false;task=nil}}
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
                let result=rows.filter {identities.insert($0.id).inserted}.sorted {
                    if $0.updatedAt != $1.updatedAt {return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)}
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                for old in pets where result.first(where:{$0.id == old.id})?.updatedAt != old.updatedAt {images.removeObject(forKey:old.id as NSString)}
                if pets != result {pets=result};fetchedAt=now
            } catch {
                guard !Task.isCancelled,visible,ticket == generation else {return}
                if client.accountKey() != key || (error as? UsageFailure) == .authentication {clearAccount();account=nil};unavailable=true
            }
        }
    }
    func image(for pet:CloudInstalledPet) -> NSImage? {images.object(forKey:pet.id as NSString)}
    func preview(_ pet:CloudInstalledPet,using fetcher:PetHTTPClient = PetHTTPClient()) {
        if images.object(forKey:pet.id as NSString) != nil {return}
        if visible,pet.imageExpiresAt.map({$0 <= Date()}) == true {
            Task {refresh(force:true);await finish();if let fresh=pets.first(where:{$0.id == pet.id}),fresh.imageExpiresAt.map({$0 > Date()}) == true {preview(fresh,using:fetcher)}};return
        }
        guard visible,previews[pet.id] == nil,previews.count < 2,let key=account,key == client.accountKey(),
              let url=pet.imageURL,let expires=pet.imageExpiresAt,expires > Date() else {return}
        let ticket=generation;previewErrors.remove(pet.id);previewing.insert(pet.id)
        previews[pet.id]=Task {
            defer {if ticket == generation {previews[pet.id]=nil;previewing.remove(pet.id)}}
            do {
                let data=try await fetcher.cloudImage(from:url,limit:32_000_000)
                let thumbnail=try await Task.detached(priority:.utility) {() -> CGImage in
                    guard let source=CGImageSourceCreateWithData(data as CFData,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                          properties[kCGImagePropertyPixelWidth] as? Int == 1536,[1872,2288].contains(properties[kCGImagePropertyPixelHeight] as? Int ?? 0) else {throw PetStoreError.invalidImage}
                    return try PetSprite.thumbnailImage(data,sprite:true)
                }.value
                guard !Task.isCancelled,visible,ticket == generation,key == client.accountKey() else {return}
                images.setObject(NSImage(cgImage:thumbnail,size:NSSize(width:thumbnail.width,height:thumbnail.height)),forKey:pet.id as NSString,cost:thumbnail.width*thumbnail.height*4);previewRevision += 1
            } catch {if !Task.isCancelled,visible,ticket == generation,key == client.accountKey() {previewErrors.insert(pet.id)}}
        }
    }
    func clearImages() {generation += 1;task?.cancel();task=nil;loading=false;cancelPreviews();images.removeAllObjects();previewErrors=[];previewRevision += 1}
    func finish() async {await task?.value}
}
