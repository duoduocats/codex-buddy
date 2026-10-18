import Foundation
import Combine
import CryptoKit

struct PetTagLabel: Codable, Equatable { let zh:String;let en:String;var text:String { L(zh,en) } }
struct PetTag: Codable, Equatable, Identifiable { let id:String;let label:PetTagLabel }
struct PetTagFacet: Codable, Equatable, Identifiable { let id:String;let tags:[PetTag];var title:String { id == "subject" ? L("类型","Type") : id == "style" ? L("风格","Style") : L("颜色","Color") } }
struct PetTagTaxonomy: Codable { let schemaVersion:Int;let revision:Int;let facets:[PetTagFacet] }
struct PetTagFile: Codable, Equatable { let path:String;let sha256:String;let bytes:Int;let revision:Int }
struct PetTagSourceFile: Codable { let sourceID:String;let catalogURL:URL;let format:String;let file:PetTagFile }
struct PetTagIndex: Codable { let schemaVersion:Int;let revision:Int;let generatedAt:String;let taxonomy:PetTagFile;let sources:[PetTagSourceFile] }
struct PetTagEntry: Codable, Equatable { let id:String;let fingerprint:String;let tags:[String] }
struct PetTagShard: Codable { let schemaVersion:Int;let revision:Int;let sourceID:String;let records:[PetTagEntry] }

// Coverage counts describe the current catalog scope, never all records in a
// feed. A stale descriptor or unknown source is not a filterable association.
struct PetTagCoverage: Equatable {
    let themeCount:Int
    let labeledThemeCount:Int
    let tagCounts:[String:Int]
    var availableTagIDs:Set<String> { Set(tagCounts.keys) }
}

@MainActor final class PetTagStore: ObservableObject {
    static let shared=PetTagStore()
    static let root=URL(string:"https://raw.githubusercontent.com/duoduocats/codex-buddy/main/pet-tags/v1/")!
    @Published private(set) var facets:[PetTagFacet]=PetTagDefaults.facets
    @Published private(set) var records:[String:PetTagEntry]=[:]
    @Published private(set) var revision=""
    @Published private(set) var syncing=false
    @Published private(set) var lastChecked:Date?
    @Published private(set) var lastSynced:Date?
    @Published private(set) var message:String?
    @Published private(set) var preview=false
    let cache:PetCatalogCache
    private let client:PetFetching
    private let preferences:UserDefaults
    private var interactionChecked=false
    private var requestedCheck=false
    private var task:Task<Void,Never>?
    private var generation=0
    private var visible=false
    private var sourceIDs=Set<String>()
    private var loaded=false
    private var cacheComplete=false
    private var index:PetTagIndex?
    private var indexHash=""
    init(preferences:UserDefaults = .standard,client:PetFetching = PetHTTPClient(),cache:PetCatalogCache? = nil) {
        self.preferences=preferences;self.client=client
        self.cache=cache ?? PetCatalogCache(directory:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("com.duoduocat.codexbuddy/PetTags",isDirectory:true))
        lastChecked=preferences.object(forKey:"tags.lastChecked") as? Date
        lastSynced=preferences.object(forKey:"tags.lastSynced") as? Date
    }
    static func hash(_ data:Data)->String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func validFile(_ file:PetTagFile)->Bool {
        file.bytes > 0 && file.bytes <= 1_000_000 && (1...1_000_000).contains(file.revision) && file.sha256.count == 64 && file.sha256.allSatisfy { "0123456789abcdef".contains($0) }
            && file.path == (file.path as NSString).lastPathComponent && file.path.hasSuffix("-"+file.sha256+".json")
            && file.path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }
    private static func onlyKeys(_ object:Any,_ keys:Set<String>) throws -> [String:Any] {
        guard let dictionary=object as? [String:Any],Set(dictionary.keys).isSubset(of:keys) else { throw PetStoreError.invalidCatalog };return dictionary
    }
    static func decodeIndex(_ data:Data) throws -> PetTagIndex {
        guard data.count <= 65_536 else { throw PetStoreError.tooLarge }
        let raw=try onlyKeys(JSONSerialization.jsonObject(with:data),["schemaVersion","revision","generatedAt","taxonomy","sources"])
        _=try onlyKeys(raw["taxonomy"] ?? NSNull(),["path","sha256","bytes","revision"])
        guard let rows=raw["sources"] as? [Any] else { throw PetStoreError.invalidCatalog }
        for item in rows { let row=try onlyKeys(item,["sourceID","catalogURL","format","file"]);_=try onlyKeys(row["file"] ?? NSNull(),["path","sha256","bytes","revision"]) }
        let x=try JSONDecoder().decode(PetTagIndex.self,from:data)
        guard x.schemaVersion == 1,(1...1_000_000).contains(x.revision),x.sources.count <= 12,
              Set(x.sources.map(\.sourceID)).count == x.sources.count,validFile(x.taxonomy),x.taxonomy.path.hasPrefix("taxonomy-"),
              x.sources.reduce(x.taxonomy.bytes,{$0+$1.file.bytes}) <= 4_000_000,
              let date=ISO8601DateFormatter().date(from:x.generatedAt),date <= Date().addingTimeInterval(60),x.generatedAt.hasSuffix("Z") else { throw PetStoreError.invalidCatalog }
        for item in x.sources {
            guard let known=(PetSource.defaults + PetSource.retired).first(where:{$0.id == item.sourceID}),known.catalogURL == item.catalogURL,known.format.rawValue == item.format,
                  validFile(item.file),item.file.path.hasPrefix("source-"+item.sourceID+"-") else { throw PetStoreError.invalidCatalog }
        }
        let activeIDs=Set(PetSource.defaults.map(\.id))
        return PetTagIndex(schemaVersion:x.schemaVersion,revision:x.revision,generatedAt:x.generatedAt,
                           taxonomy:x.taxonomy,sources:x.sources.filter { activeIDs.contains($0.sourceID) })
    }
    static func verified(_ data:Data,file:PetTagFile)->Bool { data.count == file.bytes && hash(data) == file.sha256 }
    static func decodeTaxonomy(_ data:Data,file:PetTagFile) throws -> PetTagTaxonomy {
        guard verified(data,file:file) else { throw PetStoreError.invalidCatalog }
        let raw=try onlyKeys(JSONSerialization.jsonObject(with:data),["schemaVersion","revision","facets"])
        guard let items=raw["facets"] as? [Any] else { throw PetStoreError.invalidCatalog }
        for item in items { let row=try onlyKeys(item,["id","tags"]);guard let tags=row["tags"] as? [Any] else { throw PetStoreError.invalidCatalog };for tag in tags { let r=try onlyKeys(tag,["id","label"]);_=try onlyKeys(r["label"] ?? NSNull(),["zh","en"]) } }
        let t=try JSONDecoder().decode(PetTagTaxonomy.self,from:data)
        guard t.schemaVersion == 1,t.revision == file.revision,t.facets.map(\.id) == ["subject","style","color"],
              t.facets.flatMap(\.tags).count <= 64,Set(t.facets.flatMap(\.tags).map(\.id)).count == t.facets.flatMap(\.tags).count else { throw PetStoreError.invalidCatalog }
        for f in t.facets { for tag in f.tags {
            guard tag.id.hasPrefix(f.id+"."),tag.id.count <= 60,tag.id.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || "-.".contains($0))}),
                  [tag.label.zh,tag.label.en].allSatisfy({ !$0.isEmpty && $0.count <= 60 && !$0.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) }) else { throw PetStoreError.invalidCatalog }
        } }
        return t
    }
    static func decodeShard(_ data:Data,source:PetTagSourceFile,allowed:Set<String>) throws -> PetTagShard {
        guard verified(data,file:source.file) else { throw PetStoreError.invalidCatalog }
        let raw=try onlyKeys(JSONSerialization.jsonObject(with:data),["schemaVersion","revision","sourceID","records"])
        guard let items=raw["records"] as? [Any] else { throw PetStoreError.invalidCatalog }
        for item in items { _=try onlyKeys(item,["id","fingerprint","tags"]) }
        let s=try JSONDecoder().decode(PetTagShard.self,from:data)
        guard s.schemaVersion == 1,s.revision == source.file.revision,s.sourceID == source.sourceID,s.records.count <= 8_000,Set(s.records.map(\.id)).count == s.records.count else { throw PetStoreError.invalidCatalog }
        for row in s.records {
            guard PetURL.safeComponent(row.id),row.fingerprint.count == 64,row.fingerprint.allSatisfy({"0123456789abcdef".contains($0)}),
                  row.tags.count <= 26,Set(row.tags).count == row.tags.count,Set(row.tags).isSubset(of:allowed) else { throw PetStoreError.invalidCatalog }
        };return s
    }
    func tags(for theme:PetTheme)->[PetTag] {
        guard let row=records[theme.id],let fingerprint=theme.tagFingerprint,row.fingerprint == fingerprint else { return [] }
        let selected=Set(row.tags);return facets.flatMap(\.tags).filter { selected.contains($0.id) }
    }
    var hasMetadata:Bool { !revision.isEmpty }
    func coverage(for themes:[PetTheme],sourceID:String = "") -> PetTagCoverage {
        let allowed=Set(facets.flatMap(\.tags).map(\.id))
        var seen=Set<String>(),counts=[String:Int](),total=0,labeled=0
        for theme in themes where sourceID.isEmpty || theme.sourceID == sourceID {
            guard seen.insert(theme.id).inserted else { continue };total += 1
            guard let row=records[theme.id],let fingerprint=theme.tagFingerprint,row.fingerprint == fingerprint else { continue }
            let ids=Set(row.tags).intersection(allowed)
            if !ids.isEmpty { labeled += 1 }
            for id in ids { counts[id,default:0] += 1 }
        }
        return .init(themeCount:total,labeledThemeCount:labeled,tagCounts:counts)
    }
    func setVisible(_ value:Bool,sources:Set<String> = []) {
        sourceIDs=sources
        guard visible != value else { if value { sync() };return }
        visible=value
        if value { interactionChecked=false;requestedCheck=false;sync() }
        else { generation += 1;task?.cancel();task=nil;syncing=false;requestedCheck=false;interactionChecked=false }
    }
    func activateFilters() {
        guard visible,!interactionChecked else { return }
        interactionChecked=true;sync(force:true)
    }
    func sync(force:Bool = false) {
        if force { requestedCheck=true }
        guard task == nil,force || visible else { return }
        generation += 1;let ticket=generation
        task=Task {
            defer { if generation == ticket { task=nil;syncing=false } }
            if !loaded { await loadCache(ticket:ticket) }
            guard generation == ticket,!Task.isCancelled,requestedCheck else { return }
            requestedCheck=false
            syncing=true;message=nil
            do {
                let result=try await client.response(from:Self.root.appendingPathComponent("index.json"),limit:65_536,
                    etag:(preview || !cacheComplete) ? nil : preferences.string(forKey:"tags.etag"),kind:.tags)
                guard generation == ticket,!Task.isCancelled else { return }
                let checked=Date();lastChecked=checked;preferences.set(checked,forKey:"tags.lastChecked")
                if result.notModified { guard cacheComplete,index != nil,!revision.isEmpty else { throw PetStoreError.invalidCatalog };return }
                guard let bytes=result.data else { throw PetStoreError.invalidCatalog }
                let fresh=try Self.decodeIndex(bytes),hash=Self.hash(bytes)
                if let prior=index,!preview {
                    guard fresh.revision >= prior.revision,(fresh.revision != prior.revision || hash == indexHash) else { throw PetStoreError.invalidCatalog }
                    guard fresh.taxonomy.revision >= prior.taxonomy.revision && (fresh.taxonomy.revision != prior.taxonomy.revision || fresh.taxonomy.sha256 == prior.taxonomy.sha256) else { throw PetStoreError.invalidCatalog }
                    for item in fresh.sources { if let old=prior.sources.first(where:{$0.sourceID == item.sourceID}) { guard item.file.revision >= old.file.revision && (item.file.revision != old.file.revision || item.file.sha256 == old.file.sha256) else { throw PetStoreError.invalidCatalog } } }
                }
                if cacheComplete,!preview,hash == indexHash {
                    preferences.set(result.etag,forKey:"tags.etag")
                    return
                }
                let taxonomyData=try await fetch(fresh.taxonomy,ticket:ticket)
                let taxonomy=try Self.decodeTaxonomy(taxonomyData,file:fresh.taxonomy)
                let allowed=Set(taxonomy.facets.flatMap(\.tags).map(\.id))
                var newRecords=[String:PetTagEntry]()
                for source in fresh.sources {
                    let data=try await fetch(source.file,ticket:ticket)
                    let shard=try Self.decodeShard(data,source:source,allowed:allowed)
                    for row in shard.records { newRecords[source.sourceID+":"+row.id]=row }
                }
                guard generation == ticket,!Task.isCancelled else { return }
                try await cache.write(bytes,name:"index.json")
                guard generation == ticket,!Task.isCancelled else { return }
                await cache.pruneTagFiles(keeping:Set(["index.json",fresh.taxonomy.path]+fresh.sources.map { $0.file.path }))
                guard generation == ticket,!Task.isCancelled else { return }
                index=fresh;indexHash=hash;facets=taxonomy.facets;records=newRecords;revision=hash;preview=false;loaded=true;cacheComplete=true
                lastSynced=Date();preferences.set(lastSynced,forKey:"tags.lastSynced");preferences.set(false,forKey:"tags.localPreview")
                preferences.set(result.etag,forKey:"tags.etag")
            } catch {
                guard generation == ticket,!Task.isCancelled else { return }
                // A missing index is normal before the metadata release. Keep
                // a last-good local preview usable, never invent sync success.
                lastChecked=Date();preferences.set(lastChecked,forKey:"tags.lastChecked")
                // A failed first check is still a check for this visit. The
                // retry action can force another one without one request per
                // empty facet menu while the metadata feed is unavailable.
                message=preview ? L("已载入本机标签预览", "Local tag preview loaded") : records.isEmpty
                    ? L("标签尚未就绪，请稍后重试。", "Tags are not available yet. Try again later.")
                    : L("标签暂未更新，继续使用已保存的标签。", "Tags could not update. Saved tags are still available.")
            }
        }
    }
    private func fetch(_ file:PetTagFile,ticket:Int) async throws -> Data {
        if let cached=await cache.read(file.path,limit:file.bytes),Self.verified(cached,file:file) { return cached }
        let response=try await client.response(from:Self.root.appendingPathComponent(file.path),limit:file.bytes,etag:nil,kind:.tags)
        guard generation == ticket,!Task.isCancelled,let data=response.data,Self.verified(data,file:file) else { throw PetStoreError.invalidCatalog }
        try await cache.write(data,name:file.path);return data
    }
    private func loadCache(ticket:Int) async {
        defer { if generation == ticket { loaded=true } }
        guard let data=await cache.read("index.json",limit:65_536),let doc=try? Self.decodeIndex(data),
              let td=await cache.read(doc.taxonomy.path,limit:doc.taxonomy.bytes),let taxonomy=try? Self.decodeTaxonomy(td,file:doc.taxonomy) else { return }
        var complete=true
        var rows=[String:PetTagEntry]();let allowed=Set(taxonomy.facets.flatMap(\.tags).map(\.id))
        for source in doc.sources {
            if let bytes=await cache.read(source.file.path,limit:source.file.bytes),let shard=try? Self.decodeShard(bytes,source:source,allowed:allowed) {
                for row in shard.records { rows[source.sourceID+":"+row.id]=row }
            } else { complete=false }
        }
        guard generation == ticket,!Task.isCancelled else { return }
        cacheComplete=complete
        index=doc;indexHash=Self.hash(data);facets=taxonomy.facets;records=rows;revision=indexHash
        preview=preferences.bool(forKey:"tags.localPreview")
        if preview { message=L("已载入本机标签预览", "Local tag preview loaded") }
    }
    func clear() async throws {
        generation += 1;task?.cancel();task=nil;syncing=false
        try await cache.clear();loaded=false;cacheComplete=false;index=nil;indexHash="";facets=PetTagDefaults.facets;records=[:];revision="";requestedCheck=false;interactionChecked=false
        preferences.removeObject(forKey:"tags.etag");preferences.removeObject(forKey:"tags.lastChecked");lastChecked=nil;lastSynced=nil;preview=false;preferences.removeObject(forKey:"tags.lastSynced");preferences.removeObject(forKey:"tags.localPreview")
    }
    func finish() async { await task?.value }
    func usePreview(_ taxonomy:PetTagTaxonomy,rows:[String:PetTagEntry]) { loaded=true;facets=taxonomy.facets;records=rows;revision="sample-tags";preview=true;lastSynced=Date(timeIntervalSince1970:1791892800) }
}

struct PetTagPreviewClient:PetFetching {
    func data(from url:URL,limit:Int) async throws -> Data { throw PetStoreError.unavailable }
}

enum PetTagDefaults {
    static var facets:[PetTagFacet] {
        let groups:[(String,[(String,String,String)])]=[
            ("subject",[("cat","猫","Cats"),("dog","狗","Dogs"),("bird","鸟","Birds"),("other-animal","其他动物","Other animals"),("fantasy","幻想生物","Fantasy creatures"),("robot","机器人","Robots"),("person","人物","Characters"),("plant","植物","Plants"),("object","物品","Objects")]),
            ("style",[("pixel","像素","Pixel art"),("cartoon","卡通","Cartoon"),("anime","动漫","Anime"),("3d","3D","3D"),("photo","写实","Realistic")]),
            ("color",[("black","黑色","Black"),("white","白色","White"),("gray","灰色","Gray"),("brown","棕色","Brown"),("red","红色","Red"),("orange","橙色","Orange"),("yellow","黄色","Yellow"),("green","绿色","Green"),("blue","蓝色","Blue"),("purple","紫色","Purple"),("pink","粉色","Pink"),("multicolor","多色","Multicolor")])]
        return groups.map { id,values in .init(id:id,tags:values.map { .init(id:id+"."+$0.0,label:.init(zh:$0.1,en:$0.2)) }) }
    }
}
