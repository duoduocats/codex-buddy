import Foundation

enum PetCommunityCatalogTests {
    @MainActor static func run(root:URL,sprite:Data) async throws {
        func source(_ id:String) -> PetSource { PetSource.defaults.first(where:{$0.id == id})! }
        func pets(_ text:String,_ id:String) throws -> [PetTheme] { try PetCatalog.decode(Data(text.utf8),source:source(id)).pets }
        let fixtures:[String:String]=[
            "petdex":#"{"pets":[{"slug":"fixture","displayName":"Fixture","kind":"animal","submittedBy":"Synthetic submitter","spritesheetUrl":"https://example.com/cdn/sprite.png","petJsonUrl":"https://example.com/cdn/metadata.json","spriteVersionNumber":2}]}"#,
            "codexpet":#"{"pets":[{"slug":"fixture","displayName":"Fixture","description":"Synthetic","spritesheetUrl":"https://example.com/cdn/sprite.png","petJson":{"id":"fixture","displayName":"Fixture","spritesheetPath":"spritesheet.png","spriteVersionNumber":2}}]}"#,
            "pokepets":#"{"license_note":"Synthetic rights notice","pets":[{"slug":"fixture-3d","name":"Fixture","description":"Synthetic","category":"pokemon","style":"3d","license":"fan-use","author":"Synthetic converter"}]}"#,
            "petscodex":#"{"repository":"unused","branch":"main","pets":[{"id":"fixture","displayName":"Fixture","description":"Synthetic","path":"fixture"}]}"#,
            "codexpetsorg":#"[{"id":"fixture","displayName":"Fixture","description":"Synthetic","author":"Synthetic author","kind":"animal","pageUrl":"https://example.com/fixture","spritesheetUrl":"https://example.com/fixture/spritesheet.png","manifestUrl":"https://example.com/fixture/pet.json"}]"#,
            "david":#"{"pets":[{"id":"fixture","display_name":"Fixture","display_name_zh":"测试原创","status":"ready","short_description":"Synthetic","category":["original"],"files":{"pet_json":"pets/fixture/pet.json","spritesheet":"pets/fixture/spritesheet.webp"}},{"id":"draft","display_name":"Draft","status":"draft","short_description":"Synthetic","category":[],"files":{"pet_json":"pets/draft/pet.json","spritesheet":"pets/draft/spritesheet.webp"}}]}"#,
            "rito":#"{"pets":[{"id":"fixture","name":"Fixture","description":"Synthetic","sprite":"pets/fixture/spritesheet.webp","version":2}]}"#,
            "arknights":#"{"schemaVersion":1,"pets":[{"id":"fixture","displayName":"Fixture","category":"default","status":"approved","packagePath":"pets/fixture"},{"id":"pending","displayName":"Pending","category":"default","status":"pending","packagePath":"pets/pending"}]}"#
        ]
        for (id,text) in fixtures {
            let themes=try pets(text,id)
            precondition(themes.count == 1 && themes[0].sourceID == id)
        }
        let dex=try pets(fixtures["petdex"]!,"petdex")[0]
        precondition(dex.spriteURL?.lastPathComponent == "sprite.png" && dex.manifestURL.lastPathComponent == "metadata.json")
        precondition(dex.author.contains("Synthetic submitter") && !dex.license.contains("MIT"),"Software licenses cannot be presented as artwork licenses")
        let inline=try pets(fixtures["codexpet"]!,"codexpet")[0]
        precondition(inline.inlineManifest?.version == 2 && inline.spriteURL != nil)
        precondition(try! pets(fixtures["pokepets"]!,"pokepets")[0].license.contains("Synthetic rights notice"))
        precondition(try! pets(fixtures["arknights"]!,"arknights")[0].licenseURL?.path.hasSuffix("pets/fixture/SOURCE.md") == true)
        let alias=try pets(fixtures["petscodex"]!.replacingOccurrences(of:"\"path\":\"fixture\"",with:"\"path\":\"folder-alias\""),"petscodex")[0]
        precondition(alias.remoteID == "fixture" && alias.manifestURL.path.hasSuffix("folder-alias/pet.json"),"A provider may give a pet a different public folder name")
        for (id,original,replacement) in [
            ("petdex","https://example.com/cdn/sprite.png","file:///private/tmp/sprite.png"),
            ("codexpet","spritesheet.png","../../escape.png"),
            ("petscodex","\"path\":\"fixture\"","\"path\":\"../../escape\""),
            ("david","pets/fixture/pet.json","../pet.json"),
            ("rito","pets/fixture/spritesheet.webp","../spritesheet.webp"),
            ("arknights","\"packagePath\":\"pets/fixture\"","\"packagePath\":\"../fixture\"")
        ] {
            PetStoreTests.rejected { _=try pets(fixtures[id]!.replacingOccurrences(of:original,with:replacement),id) }
        }
        let one=try JSONSerialization.jsonObject(with:Data(fixtures["petdex"]!.utf8)) as! [String:Any]
        let item=(one["pets"] as! [[String:Any]])[0]
        let many=(0..<501).map { i -> [String:Any] in var pet=item;pet["slug"]="fixture-\(i)";return pet }
        let large=try JSONSerialization.data(withJSONObject:["pets":many])
        precondition(try! PetCatalog.decode(large,source:source("petdex")).pets.count == 501,"Large verified providers must not hit the custom 500-pet limit")
        var padded=Data(fixtures["petdex"]!.utf8);padded.append(Data(repeating:32,count:2_000_001-padded.count))
        precondition(try! PetCatalog.decode(padded,source:source("petdex")).pets.count == 1)
        PetStoreTests.rejected { _=try PetCatalog.decode(Data(repeating:32,count:6_000_001),source:source("petdex")) }

        let legacy=PetTestPreferences()
        legacy.set(try JSONEncoder().encode(PetSource.defaults.prefix(4).map { var s=$0;s.enabled=false;return s }),forKey:"pets.sources")
        let migrated=ThemeStoreModel(preferences:legacy,cacheDirectory:root.appendingPathComponent("migration-cache"),libraryRoot:root)
        precondition(migrated.sources.count == 12 && migrated.sources.prefix(4).allSatisfy{!$0.enabled} && migrated.sources.dropFirst(4).allSatisfy(\.enabled))

        let client=PetHTTPClient(protocolClasses:[PetFixture.self])
        let cache=root.appendingPathComponent("community-cache",isDirectory:true)
        for id in ["codexpet","petdex","david"] {
            let preferences=PetTestPreferences()
            preferences.set(try JSONEncoder().encode(PetSource.defaults.map { var s=$0;s.enabled=s.id==id;return s }),forKey:"pets.sources")
            let selected=try pets(fixtures[id]!,id)[0]
            var bodies=[source(id).catalogURL.absoluteString:Data(fixtures[id]!.utf8)]
            let sheetURL=selected.spriteURL ?? selected.manifestURL.deletingLastPathComponent().appendingPathComponent("spritesheet.webp")
            bodies[sheetURL.absoluteString]=sprite
            if selected.inlineManifest == nil { bodies[selected.manifestURL.absoluteString]=Data(#"{"id":"fixture","displayName":"Fixture","spritesheetPath":"spritesheet.webp","spriteVersionNumber":2}"#.utf8) }
            if let notice=selected.licenseURL { bodies[notice.absoluteString]=Data("Synthetic source and rights notice".utf8) }
            PetFixture.reset(bodies)
            let model=ThemeStoreModel(preferences:preferences,client:client,cacheDirectory:cache,libraryRoot:root)
            model.open();try await PetStoreTests.wait(model)
            model.select(model.themes.first);try await PetStoreTests.wait(model)
            precondition(model.preparedPackage?.imageURL == sheetURL && model.preparedPackage?.spriteData == sprite)
            if id == "codexpet" { precondition(PetFixture.requests.filter{$0.url == source(id).catalogURL}.count == 1,"Inline manifests must not make a nonexistent per-pet request") }
            if id == "david" { precondition(model.preparedPackage?.license.contains("Synthetic source and rights notice") == true,"The original rights notice must be kept with the install package") }
            model.toggleFavorite(model.themes[0]);model.close()
            let restored=ThemeStoreModel(preferences:preferences,client:client,cacheDirectory:cache,libraryRoot:root)
            precondition(restored.favoriteThemes[0].spriteURL == selected.spriteURL && restored.favoriteThemes[0].inlineManifest == selected.inlineManifest)
        }
        print("Community expansion passed: eight new adapters, CDN/inline manifests, preserved rights notices, large bounded catalogs, unsafe paths, offline favorites and source preference migration")
    }
}
