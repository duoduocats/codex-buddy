import AppKit
import Foundation

private final class CloudFixture:URLProtocol {
    static var requests=[URLRequest]()
    static var body=Data(#"{"pets":[{"id":"pet_fixture","name":"Fixture Cloud Cat","spritesheet_url":"https://files.oaiusercontent.com/fixture.png?sig=fixture","spritesheet_url_expires_at":"2030-01-01T00:00:00Z"}],"cursor":null}"#.utf8)
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        Self.requests.append(request)
        precondition(request.url?.host == "chatgpt.com" && request.url?.path == "/backend-api/pets")
        precondition(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "limit"})?.value == "20")
        precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-test-only")
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
@MainActor private final class SyntheticCloud:CloudPetFetching {
    var key:String?="first"
    var calls=0
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
}
