import AppKit
import Foundation
import ImageIO

private final class CloudFixture:URLProtocol {
    static var requests=[URLRequest]()
    static var deleteStatus=200
    static var deleteBody=Data("{}".utf8)
    static var body=Data(#"{"pets":[{"id":"pet_fixture","name":"Fixture Cloud Cat","spritesheet_url":"https://files.oaiusercontent.com/fixture.png?sig=fixture","spritesheet_url_expires_at":"2030-01-01T00:00:00Z"}],"cursor":null}"#.utf8)
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        Self.requests.append(request)
        precondition(request.url?.host == "chatgpt.com")
        let deleting=request.httpMethod == "DELETE"
        if deleting {
            precondition(request.url?.path == "/backend-api/pets/pet_fixture" && request.url?.query == nil && request.httpBody == nil)
        } else {
            precondition(request.url?.path == "/backend-api/pets")
            precondition(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "limit"})?.value == "20")
        }
        precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-test-only")
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:deleting ? Self.deleteStatus : 200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:deleting ? Self.deleteBody : Self.body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
@MainActor private final class SyntheticCloud:CloudPetFetching {
    var key:String?="first"
    var calls=0
    var deletes=0,deleteDelay:UInt64=0
    var deleteFails=false
    func delete(petID:String,accountKey:String) async throws {
        guard key == accountKey else {throw CancellationError()};deletes += 1
        if deleteDelay > 0 {try? await Task.sleep(nanoseconds:deleteDelay)}
        if deleteFails {throw UsageFailure.timeout}
    }
    var delay:UInt64=0
    var fail=false,repeatCursor=false
    func accountKey()->String? {key}
    func page(cursor:String?) async throws -> CloudPetPage {
        calls += 1;let captured=key
        if delay > 0 {try? await Task.sleep(nanoseconds:delay)}
        if fail {throw UsageFailure.unavailable}
        let id=cursor == nil ? "pet_one" : "pet_two"
        return .init(pets:[.init(id:id,name:id,imageURL:nil,imageExpiresAt:nil,updatedAt:nil)],cursor:repeatCursor ? "same" : cursor == nil ? "next" : nil,accountKey:captured ?? "missing")
    }
}
@MainActor private final class PreviewCloud:CloudPetFetching {
    var key:String?="preview-account"
    var rows:[CloudInstalledPet]
    var replacementAfterFirst:[CloudInstalledPet]?
    var calls=0
    init(_ rows:[CloudInstalledPet]) {self.rows=rows}
    func accountKey()->String? {key}
    func page(cursor:String?) async throws -> CloudPetPage {
        calls += 1
        if calls > 1,let replacementAfterFirst {rows=replacementAfterFirst}
        return .init(pets:rows,cursor:nil,accountKey:key ?? "missing")
    }
}
private actor PreviewImages {
    var bodies=[URL:Data]()
    var requests=[URL]()
    var active=0,peak=0
    var held=Set<URL>()
    var waiters=[URL:[CheckedContinuation<Void,Never>]]()
    func set(_ data:Data,for url:URL) {bodies[url]=data}
    func hold(_ url:URL) {held.insert(url)}
    func release(_ url:URL) {held.remove(url);waiters.removeValue(forKey:url)?.forEach {$0.resume()}}
    func count(_ url:URL? = nil)->Int {url.map { target in requests.filter {$0 == target}.count } ?? requests.count}
    func maximumActive()->Int {peak}
    func fetch(_ url:URL) async throws -> Data {
        requests.append(url);active += 1;peak=max(peak,active);defer {active -= 1}
        guard let data=bodies[url] else {throw PetStoreError.unavailable}
        if held.contains(url) {await withCheckedContinuation {waiters[url,default:[]].append($0)}}
        else {try await Task.sleep(nanoseconds:20_000_000)}
        // Held fixtures deliberately ignore cancellation and return old bytes.
        return data
    }
}
@main struct PetCloudLibraryTests {
    @MainActor static func main() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[CloudFixture.self]
        let credentials=Data(#"{"tokens":{"access_token":"synthetic-test-only","account_id":"synthetic-account-only"}}"#.utf8)
        var currentCredentials=credentials
        let usage=UsageClient(configuration:config,credentialProvider:{currentCredentials})
        let reader=CloudPetClient(client:usage,salt:Data(repeating:7,count:32))
        let page=try await reader.page(cursor:"cursor&other=value")
        precondition(page.pets.count == 1 && page.pets[0].name == "Fixture Cloud Cat")
        let query=URLComponents(url:CloudFixture.requests[0].url!,resolvingAgainstBaseURL:false)!.queryItems!
        precondition(query.first(where:{$0.name == "cursor"})?.value == "cursor&other=value")
        precondition(page.accountKey.count == 64 && !page.accountKey.contains("synthetic"))
        do {_ = try await reader.page(cursor:String(repeating:"x",count:2049));preconditionFailure()} catch UsageFailure.malformed { }
        precondition(CloudFixture.requests.count == 1)
        let firstKey=reader.accountKey()
        currentCredentials=Data(#"{"tokens":{"access_token":"synthetic-second-member","account_id":"synthetic-account-only"}}"#.utf8)
        precondition(reader.accountKey() != firstKey,"Members sharing a workspace must not share pet metadata");currentCredentials=credentials
        let deleteKey=reader.accountKey()!
        try await reader.delete(petID:"pet_fixture",accountKey:deleteKey)
        precondition(CloudFixture.requests.last?.httpMethod == "DELETE")
        let beforeInvalid=CloudFixture.requests.count
        for invalid in ["pet_","codex","../pet_fixture","pet_fixture?x=1","pet_fixture#x","pet_%2Ftest"] {
            do {try await reader.delete(petID:invalid,accountKey:deleteKey);preconditionFailure()} catch { }
        }
        precondition(CloudFixture.requests.count == beforeInvalid,"Reject unsafe or built-in IDs before dispatch")
        for status in [204,404] {
            CloudFixture.deleteStatus=status;CloudFixture.deleteBody=Data()
            try await reader.delete(petID:"pet_fixture",accountKey:deleteKey)
        }
        for status in [202,307,403,500] {
            CloudFixture.deleteStatus=status
            do {try await reader.delete(petID:"pet_fixture",accountKey:deleteKey);preconditionFailure()} catch { }
        }
        CloudFixture.deleteStatus=200
        for body in ["not JSON","{\"success\":false}","{\"error\":\"fixture\"}"] {
            CloudFixture.deleteBody=Data(body.utf8)
            do {try await reader.delete(petID:"pet_fixture",accountKey:deleteKey);preconditionFailure()} catch { }
        }
        CloudFixture.deleteBody=Data("{}".utf8)
        let beforeRace=CloudFixture.requests.count
        var authReads=0
        let raced=UsageClient(configuration:config,credentialProvider:{
            authReads += 1
            return authReads <= 2 ? credentials : Data(#"{"tokens":{"access_token":"synthetic-other","account_id":"synthetic-account-only"}}"#.utf8)
        })
        let raceReader=CloudPetClient(client:raced,salt:Data(repeating:7,count:32))
        let raceKey=raceReader.accountKey()!
        do {try await raceReader.delete(petID:"pet_fixture",accountKey:raceKey);preconditionFailure()} catch { }
        precondition(CloudFixture.requests.count == beforeRace,"Account/member change between confirmation and dispatch must never send DELETE")
        raced.stop()
        CloudFixture.body=Data(repeating:32,count:1_000_001)
        do {_ = try await reader.page(cursor:nil);preconditionFailure()} catch UsageFailure.malformed { }
        usage.stop()
        for raw in [#"{"pets":[{"id":"../unsafe","name":"Fixture"}]}"#,#"{"pets":[{"id":"pet_good","name":""}]}"#] {
            do {_ = try CloudPetPage.decode(Data(raw.utf8),accountKey:"fixture");preconditionFailure()} catch { }
        }
        let mixed=try CloudPetPage.decode(Data(#"{"pets":[{"id":"codex","name":"Codex"},{"id":"pet_owned","name":"Fixture owned pet"}],"cursor":null}"#.utf8),accountKey:"fixture")
        precondition(mixed.pets.map(\.id) == ["pet_owned"],"Built-in choices are not installed custom pets")
        precondition(!CloudInstalledPet.validImageURL(URL(string:"https://files.oaiusercontent.com.evil.test/x")!))
        precondition(!CloudInstalledPet.validImageURL(URL(string:"https://user:pass@files.oaiusercontent.com/x")!))
        precondition(!CloudInstalledPet.validImageURL(URL(string:"http://files.oaiusercontent.com/x")!))
        let fixture=SyntheticCloud();let library=PetCloudLibrary(client:fixture);precondition(fixture.calls == 0)
        library.setVisible(true);await library.finish()
        precondition(library.pets.count == 2 && fixture.calls == 2 && !library.loading && !library.unavailable)
        library.refresh();await library.finish();precondition(fixture.calls == 2,"Fresh metadata must not redownload on repeated navigation")
        fixture.key="second";fixture.delay=40_000_000;library.refresh();precondition(library.pets.isEmpty,"Clear old names before awaiting another account")
        fixture.key="third";await library.finish();precondition(library.pets.isEmpty)
        fixture.delay=0;library.refresh(force:true);await library.finish();precondition(library.pets.count == 2)
        fixture.repeatCursor=true;library.refresh(force:true);await library.finish();precondition(library.unavailable && fixture.calls < 15)
        fixture.repeatCursor=false;fixture.fail=true;library.refresh(force:true);await library.finish();precondition(library.pets.count == 2 && library.unavailable)
        fixture.key=nil;library.refresh(force:true);precondition(library.pets.isEmpty && library.unavailable)
        fixture.key="fourth";fixture.fail=false;fixture.delay=40_000_000;library.refresh(force:true);library.setVisible(false)
        try await Task.sleep(nanoseconds:70_000_000);precondition(library.pets.isEmpty && !library.loading)
        try await deletionLifecycle()
        try await automaticPreviews()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-cloud-local-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let domain="buddy-cloud-local-"+UUID().uuidString
        let memory=UserDefaults(suiteName:domain)!;defer {memory.removePersistentDomain(forName:domain)}
        var sources=PetSource.defaults;for i in sources.indices {sources[i].enabled=false}
        memory.set(try JSONEncoder().encode(sources),forKey:"pets.sources")
        func addPet(_ id:String) throws {
            let directory=root.appendingPathComponent("pets/"+id);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try Data(("{\"displayName\":\"Fixture "+id+"\",\"spritesheetPath\":\"spritesheet.webp\"}").utf8).write(to:directory.appendingPathComponent("pet.json"))
            try Data([1]).write(to:directory.appendingPathComponent("spritesheet.webp"))
        }
        try addPet("one")
        let store=ThemeStoreModel(preferences:memory,cacheDirectory:root.appendingPathComponent("cache"),libraryRoot:root);store.open()
        for _ in 0..<1000 where store.installed.count != 1 {try await Task.sleep(nanoseconds:5_000_000)};precondition(store.installed.count == 1)
        try addPet("two");store.setInstalledPageVisible(true);store.refresh()
        for _ in 0..<1000 where store.installed.count != 2 {try await Task.sleep(nanoseconds:5_000_000)}
        precondition(store.installed.count == 2,"External install remains visible across catalog generation changes");store.close()
        print("Cloud pet checks passed: pagination, bounded response, account/member isolation, lazy refresh, cursor cycles, cancellation and external installation discovery")
    }
    @MainActor static func deletionLifecycle() async throws {
        let client=SyntheticCloud()
        let cloud=PetCloudLibrary(client:client)
        cloud.setVisible(true);await cloud.finish()
        let first=cloud.pets.first!
        cloud.requestDeletion(first);precondition(client.deletes == 0 && cloud.deletionRequest?.pet == first)
        cloud.cancelDeletion();cloud.confirmDeletion();precondition(client.deletes == 0 && cloud.pets.count == 2)
        cloud.requestDeletion(first);cloud.setVisible(false);cloud.confirmDeletion();precondition(client.deletes == 0 && cloud.deletionRequest == nil)
        cloud.setVisible(true);await cloud.finish();cloud.requestDeletion(first)
        client.deleteDelay=30_000_000
        cloud.confirmDeletion();cloud.confirmDeletion();precondition(cloud.deletingPetID == first.id && cloud.pets.count == 2)
        cloud.setVisible(false);await cloud.finishDeletion()
        precondition(client.deletes == 1 && cloud.pets.count == 1 && cloud.deletingPetID == nil && !cloud.deletionFailed)
        cloud.setVisible(true);await cloud.finish()
        precondition(!cloud.pets.contains(where:{$0.id == first.id}),"A stale post-delete listing must not resurrect the removed row")
        let other=cloud.pets.first!
        client.deleteFails=true;cloud.requestDeletion(other);cloud.confirmDeletion();await cloud.finishDeletion()
        precondition(cloud.pets == [other] && cloud.deletionFailed && client.deletes == 2,"Ambiguous failures retain the row and never automatically retry")
        cloud.requestDeletion(other);client.key="different";cloud.confirmDeletion()
        precondition(client.deletes == 2 && cloud.pets.isEmpty,"Changed member invalidates the confirmation without deleting")
        cloud.refresh(force:true);await cloud.finish();cloud.requestDeletion(cloud.pets.first!)
        client.deleteFails=false
        let beforeLate=client.deletes
        cloud.confirmDeletion()
        for _ in 0..<100 where client.deletes == beforeLate {await Task.yield()}
        precondition(client.deletes == beforeLate+1,"Late-ack test must switch members after dispatch")
        client.key="new-member";cloud.refresh(force:true)
        precondition(cloud.pets.isEmpty,"Reopening or refreshing during an old-member deletion clears old names immediately")
        await cloud.finishDeletion()
        precondition(cloud.pets.isEmpty && cloud.deletionMessage == nil,"Late acknowledgements never edit the next member's data")
        let prefs=UsagePreviewPreferences()
        var sources=PetSource.defaults;for i in sources.indices {sources[i].enabled=false}
        prefs.set(try JSONEncoder().encode(sources),forKey:"pets.sources")
        let controller=BuddyPetsController(factory:{ThemeStoreModel(preferences:prefs,cloud:cloud,libraryRoot:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))})
        controller.setVisible(true);cloud.setVisible(true);await cloud.finish()
        cloud.requestDeletion(cloud.pets.first!);cloud.confirmDeletion()
        precondition(controller.modifyingLocalLibrary,"Cloud mutation participates in quit/update/cache coordination")
        await controller.finishCurrentInstallation()
        precondition(!controller.modifyingLocalLibrary && cloud.deletingPetID == nil)
        controller.setVisible(false);cloud.setVisible(false)
        print("Cloud deletion passed: cancel-before-dispatch, single flight, hidden-page completion, stale-list suppression, failure retention, account/member fences and quit/update coordination")
    }
    private static func previewSprite() -> Data {
        let context=CGContext(data:nil,width:1536,height:2288,bitsPerComponent:8,bytesPerRow:1536*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.1,green:0.6,blue:0.9,alpha:1));context.fill(CGRect(x:0,y:2080,width:192,height:208))
        let result=NSMutableData();let writer=CGImageDestinationCreateWithData(result,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(writer,context.makeImage()!,nil);precondition(CGImageDestinationFinalize(writer));return result as Data
    }
    private static func previewPet(_ index:Int,expires:Date = Date().addingTimeInterval(600),revision:Int = 0) -> CloudInstalledPet {
        .init(id:"pet_visible_\(index)",name:"Visible \(index)",imageURL:URL(string:"https://files.oaiusercontent.com/fixture-\(index)-\(revision).png?sig=synthetic"),imageExpiresAt:expires,updatedAt:Date(timeIntervalSince1970:Double(revision)))
    }
    @MainActor private static func waitPreview(_ condition:() -> Bool) async throws {
        for _ in 0..<400 {if condition() {return};try await Task.sleep(nanoseconds:5_000_000)}
        preconditionFailure("Synthetic cloud preview did not settle")
    }
    @MainActor static func automaticPreviews() async throws {
        let data=previewSprite(),rows=(0..<6).map {previewPet($0)}
        let client=PreviewCloud(rows),images=PreviewImages()
        for row in rows {await images.set(data,for:row.imageURL!)}
        let library=PetCloudLibrary(client:client,imageFetcher:{try await images.fetch($0)})
        library.setVisible(true);await library.finish()
        var count=await images.count();precondition(count == 0,"Reading metadata must not download every cloud sprite")
        let tokens=(0..<6).map {_ in UUID()}
        for index in 0..<4 {library.setPreviewVisible(rows[index],token:tokens[index],true)}
        let duplicate=UUID();library.setPreviewVisible(rows[0],token:duplicate,true)
        try await waitPreview {rows.prefix(4).allSatisfy {library.image(for:$0) != nil} && library.previewing.isEmpty}
        count=await images.count();let peak=await images.maximumActive()
        precondition(count == 4 && peak <= 2,"Visible rows must drain beyond the first two with single-flight, bounded concurrent fetching")
        precondition(library.image(for:rows[0])?.size == NSSize(width:192,height:208),"Only the isolated first frame is kept")
        library.setPreviewVisible(rows[0],token:tokens[0],false);library.setPreviewVisible(rows[0],token:duplicate,false)
        library.setPreviewVisible(rows[0],token:tokens[0],true)
        try await Task.sleep(nanoseconds:30_000_000)
        count=await images.count();precondition(count == 4,"Reappearing cached rows should not redownload")
        await images.set(Data("bad image".utf8),for:rows[4].imageURL!)
        library.setPreviewVisible(rows[4],token:tokens[4],true)
        try await waitPreview {library.previewErrors.contains(rows[4].id)}
        library.setPreviewVisible(rows[4],token:tokens[4],true)
        try await Task.sleep(nanoseconds:30_000_000)
        count=await images.count(rows[4].imageURL);precondition(count == 1,"Automatic preview failures must not loop")
        await images.set(data,for:rows[4].imageURL!);library.preview(rows[4])
        try await waitPreview {library.image(for:rows[4]) != nil}
        count=await images.count(rows[4].imageURL);precondition(count == 2 && !library.previewErrors.contains(rows[4].id),"A deliberate retry should recover")
        count=await images.count(rows[5].imageURL);precondition(count == 0,"An offscreen pet must not fetch")
        library.setVisible(false)

        let racePet=previewPet(20),raceClient=PreviewCloud([previewPet(20)]),raceImages=PreviewImages()
        await raceImages.set(data,for:racePet.imageURL!);await raceImages.hold(racePet.imageURL!)
        let race=PetCloudLibrary(client:raceClient,imageFetcher:{try await raceImages.fetch($0)})
        race.setVisible(true);await race.finish();let token=UUID()
        race.setPreviewVisible(race.pets[0],token:token,true)
        for _ in 0..<100 {if await raceImages.count() == 1 {break};try await Task.sleep(nanoseconds:2_000_000)}
        race.clearImages();await raceImages.release(racePet.imageURL!)
        try await Task.sleep(nanoseconds:60_000_000)
        count=await raceImages.count()
        precondition(race.image(for:racePet) == nil && race.previewing.isEmpty && count == 1,"A stale completion after clearing cannot refill or restart the cache")
        race.setPreviewVisible(race.pets[0],token:token,true)
        try await waitPreview {race.image(for:race.pets[0]) != nil}
        race.clearImages();await raceImages.hold(racePet.imageURL!);race.setPreviewVisible(race.pets[0],token:token,true)
        for _ in 0..<100 {if await raceImages.count() == 3 {break};try await Task.sleep(nanoseconds:2_000_000)}
        race.setPreviewVisible(race.pets[0],token:token,false);await raceImages.release(racePet.imageURL!)
        try await Task.sleep(nanoseconds:40_000_000)
        precondition(race.image(for:racePet) == nil && race.previewing.isEmpty,"A row that left the viewport must ignore its late thumbnail")
        race.setPreviewVisible(race.pets[0],token:token,true)
        try await waitPreview {race.image(for:race.pets[0]) != nil}
        race.clearImages();await raceImages.hold(racePet.imageURL!);race.setPreviewVisible(race.pets[0],token:token,true)
        for _ in 0..<100 {if await raceImages.count() == 5 {break};try await Task.sleep(nanoseconds:2_000_000)}
        let next=previewPet(20,revision:1)
        await raceImages.set(data,for:next.imageURL!)
        raceClient.key="second-member";raceClient.rows=[next];race.refresh(force:true);await race.finish()
        await raceImages.release(racePet.imageURL!)
        try await waitPreview {race.image(for:next) != nil && race.previewing.isEmpty}
        count=await raceImages.count(next.imageURL);precondition(count == 1 && race.pets == [next],"A new member must use only the new member's current asset")
        race.clearImages();await raceImages.hold(next.imageURL!);race.setPreviewVisible(next,token:token,true)
        for _ in 0..<100 {if await raceImages.count(next.imageURL) == 2 {break};try await Task.sleep(nanoseconds:2_000_000)}
        race.setVisible(false);await raceImages.release(next.imageURL!)
        try await Task.sleep(nanoseconds:40_000_000)
        precondition(race.image(for:next) == nil && race.previewing.isEmpty)

        let expired=(30..<34).map {previewPet($0,expires:Date(timeIntervalSince1970:1))}
        let renewed=(30..<34).map {previewPet($0)}
        let expiryClient=PreviewCloud(expired);expiryClient.replacementAfterFirst=renewed
        let expiryImages=PreviewImages();for row in renewed {await expiryImages.set(data,for:row.imageURL!)}
        let expiry=PetCloudLibrary(client:expiryClient,imageFetcher:{try await expiryImages.fetch($0)})
        expiry.setVisible(true);await expiry.finish()
        for row in expired {expiry.setPreviewVisible(row,token:UUID(),true)}
        try await waitPreview {renewed.allSatisfy {expiry.image(for:$0) != nil} && expiry.previewing.isEmpty}
        precondition(expiryClient.calls == 2,"All visible expired URLs should share one metadata renewal")
        expiry.setVisible(false)
        let failingClient=PreviewCloud(expired),failingImages=PreviewImages()
        let failing=PetCloudLibrary(client:failingClient,imageFetcher:{try await failingImages.fetch($0)})
        failing.setVisible(true);await failing.finish()
        for row in expired {failing.setPreviewVisible(row,token:UUID(),true)}
        try await waitPreview {!failing.loading && failing.previewErrors.count == expired.count}
        try await Task.sleep(nanoseconds:40_000_000)
        count=await failingImages.count()
        precondition(failingClient.calls == 2 && count == 0,"An unchanged expired response must stop instead of looping refresh or image fetches")
        failing.setVisible(false)
        print("Cloud automatic previews passed: visible-only loading, two active slots, queued rows, duplicate-row single flight, thumbnail reuse, explicit retry, offscreen/clear/member/hidden fences and coalesced signed-URL renewal")
    }

}
