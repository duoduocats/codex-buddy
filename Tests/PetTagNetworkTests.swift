import AppKit
import Foundation

private final class TagTestPreferences:UserDefaults {
    var values=[String:Any]()
    override func object(forKey key:String)->Any? { values[key] }
    override func data(forKey key:String)->Data? { values[key] as? Data }
    override func string(forKey key:String)->String? { values[key] as? String }
    override func bool(forKey key:String)->Bool { values[key] as? Bool ?? false }
    override func set(_ value:Any?,forKey key:String) { values[key]=value }
    override func removeObject(forKey key:String) { values.removeValue(forKey:key) }
}
private struct TagFixtureClient:PetFetching {
    let files:[String:Data]
    func data(from url:URL,limit:Int) async throws -> Data { guard let data=files[url.lastPathComponent],data.count <= limit else { throw PetStoreError.unavailable };return data }
}
private actor TagCountingClient:PetFetching {
    var files:[String:Data]
    var requests:[String]=[]
    init(_ files:[String:Data]) { self.files=files }
    func data(from url:URL,limit:Int) async throws -> Data {
        requests.append(url.lastPathComponent)
        guard let data=files[url.lastPathComponent],data.count <= limit else { throw PetStoreError.unavailable };return data
    }
    func replace(_ files:[String:Data]) { self.files=files;requests=[] }
    func requested()->[String] { requests }
}
private actor TagDelayedClient:PetFetching {
    private var continuation:CheckedContinuation<Data,Error>?
    var pending=false
    func data(from url:URL,limit:Int) async throws -> Data { pending=true;return try await withCheckedThrowingContinuation { continuation=$0 } }
    func release(_ data:Data) { continuation?.resume(returning:data);continuation=nil }
}
private final class TagHTTPProtocol:URLProtocol {
    static var conditional=false
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.conditional=request.value(forHTTPHeaderField:"If-None-Match") == "fixture-etag" && request.value(forHTTPHeaderField:"Cookie") == nil && request.value(forHTTPHeaderField:"Authorization") == nil
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:304,httpVersion:nil,headerFields:["ETag":"fixture-etag"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct PetTagNetworkTests {
    static func check(_ condition:Bool,_ message:String = "Tag regression",line:Int = #line) { if !condition { fatalError("\(message) at line \(line)") } }
    @MainActor static func main() async throws {
        let preferences=TagTestPreferences(),settings=BuddyNetworkSettings(preferences:preferences)
        check(settings.traffic.total == 0)
        settings.record(.tags,bytes:100,complete:true);settings.record(.preview,bytes:200,complete:false)
        settings.record(.petPackage,bytes:300,complete:true)
        let restored=BuddyNetworkSettings(preferences:preferences)
        check(restored.traffic.total == 600 && restored.traffic.partial == ["preview"])
        let label=PetTagLabel(zh:"猫",en:"Cats"),dog=PetTag(id:"subject.dog",label:.init(zh:"狗",en:"Dogs")),cat=PetTag(id:"subject.cat",label:label),pixel=PetTag(id:"style.pixel",label:.init(zh:"像素",en:"Pixel"))
        let taxonomy=PetTagTaxonomy(schemaVersion:1,revision:1,facets:[.init(id:"subject",tags:[cat,dog]),.init(id:"style",tags:[pixel]),.init(id:"color",tags:[])])
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        func file(_ prefix:String,_ data:Data)->PetTagFile { let hash=PetTagStore.hash(data);return .init(path:prefix+"-"+hash+".json",sha256:hash,bytes:data.count,revision:1) }
        let td=try encoder.encode(taxonomy),tf=file("taxonomy",td),source=PetSource.defaults[0]
        let fingerprint=String(repeating:"a",count:64)
        let shard=PetTagShard(schemaVersion:1,revision:1,sourceID:source.id,records:[.init(id:"fixture",fingerprint:fingerprint,tags:[cat.id,pixel.id])])
        let sd=try encoder.encode(shard),sf=file("source-"+source.id,sd),entry=PetTagSourceFile(sourceID:source.id,catalogURL:source.catalogURL,format:source.format.rawValue,file:sf)
        let index=PetTagIndex(schemaVersion:1,revision:1,generatedAt:"2026-10-12T00:00:00Z",taxonomy:tf,sources:[entry]),id=try encoder.encode(index)
        _=try PetTagStore.decodeIndex(id);_ = try PetTagStore.decodeTaxonomy(td,file:tf);_ = try PetTagStore.decodeShard(sd,source:entry,allowed:[cat.id,pixel.id])
        check(!PetTagStore.verified(Data("tampered".utf8),file:sf))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-tag-tests-"+UUID().uuidString)
        let cache=PetCatalogCache(directory:folder);defer { try? FileManager.default.removeItem(at:folder) }
        let store=PetTagStore(preferences:preferences,client:TagFixtureClient(files:["index.json":id,tf.path:td,sf.path:sd]),cache:cache)
        store.sync(force:true);await store.finish();check(store.records.count == 1 && store.lastSynced != nil)
        let theme=PetTheme(remoteID:"fixture",sourceID:source.id,name:"Synthetic",summary:"",author:"Synthetic",license:"Synthetic",category:"",manifestURL:URL(string:"https://example.com/a/pet.json")!,previewURL:nil,websiteURL:URL(string:"https://example.com/a")!,tagFingerprint:fingerprint)
        check(store.tags(for:theme).map(\.id) == [cat.id,pixel.id])
        var stale=theme;stale.tagFingerprint=String(repeating:"b",count:64);check(store.tags(for:stale).isEmpty)
        let engine=PetSearchEngine(),snapshot=PetSearchSnapshot(themes:[theme],favorites:[],popularity:[:],names:[:],tags:[theme.id:[cat,pixel]])
        let matches=try await engine.query(.init(revision:1,query:"",sourceID:"",byInstalls:false,favoritesOnly:false,selectedTagIDs:[cat.id,dog.id,pixel.id]),snapshot:snapshot)
        check(matches.count == 1,"Same facet OR / different facet AND")
        let misses=try await engine.query(.init(revision:1,query:"",sourceID:"",byInstalls:false,favoritesOnly:false,selectedTagIDs:[dog.id,pixel.id]),snapshot:snapshot)
        check(misses.isEmpty)
        try await store.clear();let clearedBytes=try await cache.byteCount();check(store.records.isEmpty && clearedBytes == 0)
        let preferences2=TagTestPreferences()
        let manual=PetTagStore(preferences:preferences2,client:TagFixtureClient(files:[:]),cache:cache)
        manual.setVisible(true);await manual.finish();check(manual.lastChecked == nil && !manual.facets.isEmpty,"Opening pets reads local/default labels without network")
        manual.activateFilters();await manual.finish();check(manual.lastChecked != nil,"First filter interaction checks metadata")
        let incrementalCache=PetCatalogCache(directory:folder.appendingPathComponent("incremental"))
        let counter=TagCountingClient(["index.json":id,tf.path:td,sf.path:sd])
        let onClick=PetTagStore(preferences:TagTestPreferences(),client:counter,cache:incrementalCache)
        onClick.setVisible(true);await onClick.finish()
        let opening=await counter.requested();check(opening.isEmpty,"No metadata request on page open")
        onClick.activateFilters();await onClick.finish()
        let initial=await counter.requested();check(initial == ["index.json",tf.path,sf.path],"First click checks index and only missing files")
        let synced=onClick.lastSynced
        onClick.activateFilters();await onClick.finish()
        let repeated=await counter.requested();check(repeated == initial,"Other tag menus reuse the same check")
        await counter.replace(["index.json":id])
        onClick.setVisible(false);onClick.setVisible(true);await onClick.finish()
        onClick.activateFilters();await onClick.finish()
        let unchanged=await counter.requested();check(unchanged == ["index.json"] && onClick.lastSynced == synced,"Unchanged index downloads no shards and preserves update time")
        let changedShard=PetTagShard(schemaVersion:1,revision:2,sourceID:source.id,records:[.init(id:"fixture",fingerprint:fingerprint,tags:[dog.id])])
        let changedBytes=try encoder.encode(changedShard),changedHash=PetTagStore.hash(changedBytes)
        let changedFile=PetTagFile(path:"source-"+source.id+"-"+changedHash+".json",sha256:changedHash,bytes:changedBytes.count,revision:2)
        let changedSource=PetTagSourceFile(sourceID:source.id,catalogURL:source.catalogURL,format:source.format.rawValue,file:changedFile)
        let changedIndex=try encoder.encode(PetTagIndex(schemaVersion:1,revision:2,generatedAt:index.generatedAt,taxonomy:tf,sources:[changedSource]))
        await counter.replace(["index.json":changedIndex,changedFile.path:changedBytes])
        onClick.setVisible(false);onClick.setVisible(true);await onClick.finish();onClick.activateFilters();await onClick.finish()
        let delta=await counter.requested();check(delta == ["index.json",changedFile.path] && onClick.tags(for:theme).map(\.id) == [dog.id],"Changed shard only; taxonomy reused locally")
        let delayed=TagDelayedClient(),race=PetTagStore(preferences:TagTestPreferences(),client:delayed,cache:cache)
        race.sync(force:true)
        while await !delayed.pending { try await Task.sleep(nanoseconds:1_000_000) }
        try await race.clear();await delayed.release(id)
        try await Task.sleep(nanoseconds:5_000_000)
        let raceBytes=try await cache.byteCount();check(race.records.isEmpty && raceBytes == 0,"Clear generation rejects late network payloads")
        let conditional=try await PetHTTPClient(protocolClasses:[TagHTTPProtocol.self]).response(from:PetTagStore.root.appendingPathComponent("index.json"),limit:65_536,etag:"fixture-etag",kind:.tags)
        check(conditional.notModified && TagHTTPProtocol.conditional,"Anonymous conditional tag fetch and304")
        var bad=try JSONSerialization.jsonObject(with:id) as! [String:Any];bad["sprite"]="not allowed"
        do { _=try PetTagStore.decodeIndex(JSONSerialization.data(withJSONObject:bad));fatalError("Non-metadata field accepted") } catch PetStoreError.invalidCatalog {}
        struct Vector:Decodable { let sourceID:String;let json:String;let expected:String }
        if CommandLine.arguments.count > 1 {
            let vectors=try JSONDecoder().decode([Vector].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
            for v in vectors { let known=PetSource.defaults.first{$0.id == v.sourceID}!;let binding=try PetTagBinding.fingerprints(Data(v.json.utf8),source:known);check(binding["fixture"] == v.expected,"Cross-language raw descriptor binding \(v.sourceID)") }
        }
        print("Tag/network tests passed: sparse source binding, taxonomy/digest limits, OR/AND and canonical queries, last-good sync/cache clear, first-click-only and unchanged/delta downloads, persistent typed traffic and unknown lower bounds")
    }
}
