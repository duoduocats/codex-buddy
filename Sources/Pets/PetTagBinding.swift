import Foundation

// Exact raw, unlocalized descriptor binding, shared with raw-metadata-v1-draft.
// Failure leaves the catalog usable but its uncertain label association empty.
enum PetTagBinding {
    static func digest(_ object:Any) throws -> String {
        return PetURL.key(try canonical(object))
    }
    private static func canonical(_ object:Any) throws -> String {
        if let dictionary=object as? [String:Any] {
            let keys=dictionary.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            return "{"+(try keys.map { try canonical($0)+":"+canonical(dictionary[$0]!) }).joined(separator:",")+"}"
        }
        if let array=object as? [Any] { return "["+(try array.map(canonical)).joined(separator:",")+"]" }
        // JSONSerialization.sortedKeys uses natural case-insensitive order,
        // unlike the maintainer's byte-stable Python canonical descriptors.
        let data=try JSONSerialization.data(withJSONObject:[object],options:[.withoutEscapingSlashes])
        let text=String(decoding:data,as:UTF8.self);return String(text.dropFirst().dropLast())
    }
    static func fingerprints(_ data:Data,source:PetSource) throws -> [String:String] {
        let fields:[String:[String]]=[
            "huaqing":["id","name","description","category"],"cuteChen":["slug","name","description","primary_category"],
            "legeling":["slug","name","localized_names","description","primary_category"],"senyo":["id","displayName","description"],
            "petdex":["slug","displayName","kind"],"codexPet":["slug","displayName","description"],
            "pokePets":["slug","name","description","category","style"],"petsCodex":["id","displayName","description"],
            "codexPetsOrg":["id","displayName","description","kind"],"david":["id","display_name","display_name_zh","short_description","short_description_zh","category"],
            "rito":["id","name","description"],"arknights":["id","displayName","category"]]
        let fmt=source.format.rawValue
        guard source.builtIn,let names=fields[fmt] else { return [:] }
        let object=try JSONSerialization.jsonObject(with:data)
        let pets=(["cuteChen","legeling","codexPetsOrg"].contains(fmt) ? object : ((object as? [String:Any])?["pets"] ?? NSNull())) as? [[String:Any]]
        guard let pets,pets.count <= 100_000 else { throw PetStoreError.invalidCatalog }
        let base=source.catalogURL.deletingLastPathComponent().absoluteString
        func url(_ path:String,_ origin:String? = nil) throws -> String {
            guard let value=URL(string:path,relativeTo:URL(string:origin ?? base))?.absoluteURL else { throw PetStoreError.invalidURL }
            return try PetURL.validate(value).absoluteString
        }
        func raw(_ value:Any?) throws -> String { guard let s=value as? String else { throw PetStoreError.invalidCatalog };return try url(s) }
        var result=[String:String]()
        for p in pets {
            if fmt == "senyo" && p["publicationState"] as? String != "published" { continue }
            if fmt == "david" && p["status"] as? String != "ready" { continue }
            if fmt == "arknights" && p["status"] as? String != "approved" { continue }
            if fmt == "rito" && ![1,2].contains(p["version"] as? Int ?? 0) { continue }
            if fmt == "petdex" && ![1,2].contains(p["spriteVersionNumber"] as? Int ?? 1) { continue }
            guard let id=p[names[0]] as? String,PetURL.safeComponent(id),result[id] == nil else { throw PetStoreError.invalidCatalog }
            var allowed=CharacterSet.urlPathAllowed;allowed.remove(charactersIn:"/;?+#%")
            guard let q=id.addingPercentEncoding(withAllowedCharacters:allowed) else { throw PetStoreError.invalidCatalog }
            let text=Dictionary(uniqueKeysWithValues:names.dropFirst().map { ($0,p[$0] ?? NSNull()) })
            var refs=[String:Any]()
            switch fmt {
            case "huaqing":
                let root=source.catalogURL.deletingLastPathComponent().deletingLastPathComponent().absoluteString
                refs=["manifest":try url("pets/\(q)/pet.json",root),"preview":try url("assets/previews/\(q)/idle.gif",root),"sourcePage":try raw(p["url"])]
            case "cuteChen","legeling","pokePets":
                let preview=fmt == "cuteChen" ? "assets/previews/\(q)/gifs/idle.gif" : "pets/\(q)/"+(fmt == "legeling" ? "spritesheet.webp" : "preview.gif")
                refs=["manifest":try url("pets/\(q)/pet.json"),"preview":try url(preview)]
            case "senyo":
                guard p["previewPath"] as? String == "pets/\(id)/preview.gif" else { throw PetStoreError.invalidCatalog }
                refs=["manifest":try url("pets/\(q)/pet.json"),"preview":try raw(p["previewPath"]),"sourcePage":try raw(p["installPage"])]
            case "petdex": refs=["manifest":try raw(p["petJsonUrl"]),"sprite":try raw(p["spritesheetUrl"]),"spriteVersion":p["spriteVersionNumber"] as? Int ?? 1]
            case "codexPet":
                guard let inline=p["petJson"] as? [String:Any] else { throw PetStoreError.invalidCatalog }
                refs=["manifest":source.catalogURL.absoluteString,"inlineEntryKey":id,"inlineMetadataHash":try digest(inline),"sprite":try raw(p["spritesheetUrl"])]
            case "petsCodex":
                guard let path=p["path"] as? String,PetURL.safeComponent(path),!path.hasPrefix("."),let encoded=path.addingPercentEncoding(withAllowedCharacters:allowed) else { throw PetStoreError.invalidCatalog }
                refs=["manifest":try url(encoded+"/pet.json"),"sprite":try url(encoded+"/spritesheet.webp")]
            case "codexPetsOrg": refs=["manifest":try raw(p["manifestUrl"]),"sprite":try raw(p["spritesheetUrl"]),"sourcePage":try raw(p["pageUrl"])]
            case "david":
                let files=p["files"] as? [String:Any] ?? [:]
                guard files["pet_json"] as? String == "pets/\(id)/pet.json",files["spritesheet"] as? String == "pets/\(id)/spritesheet.webp" else { throw PetStoreError.invalidCatalog }
                refs=["manifest":try raw(files["pet_json"]),"sprite":try raw(files["spritesheet"]),"preview":try url("pets/\(q)/assets/previews/idle.gif")]
            case "rito":
                guard p["sprite"] as? String == "pets/\(id)/spritesheet.webp" else { throw PetStoreError.invalidCatalog }
                refs=["manifest":try url("pets/\(q)/pet.json"),"sprite":try raw(p["sprite"]),"spriteVersion":p["version"]!]
            case "arknights":
                guard p["packagePath"] as? String == "pets/\(id)" else { throw PetStoreError.invalidCatalog }
                let root=source.catalogURL.deletingLastPathComponent().deletingLastPathComponent().absoluteString
                refs=["manifest":try url("pets/\(q)/pet.json",root),"sprite":try url("pets/\(q)/spritesheet.webp",root)]
            default: continue
            }
            var version=[String:Any]()
            for key in ["version","revision","contentHash","sha256","checksum","assetDigest","spriteVersionNumber"] { if let value=p[key] { version[key]=value } }
            result[id]=try digest(["adapterVersion":"raw-metadata-v1-draft","sourceID":source.id,"remoteID":id,"catalogURL":source.catalogURL.absoluteString,"format":fmt,"rawText":text,"references":refs,"upstreamVersion":version])
        }
        return result
    }
}
