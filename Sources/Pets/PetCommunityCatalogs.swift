import Foundation

// Adapt public provider catalogs; never execute their installers or download ZIPs.
enum PetCommunityCatalogs {
    private struct Feed<T:Decodable>:Decodable { let pets:[T] }
    private struct PetdexPet:Decodable {
        let slug:String;let displayName:String;let kind:String?;let submittedBy:String?
        let spritesheetUrl:URL;let petJsonUrl:URL;let spriteVersionNumber:Int?
    }
    private struct CodexPet:Decodable {
        let slug:String;let displayName:String;let description:String?;let spritesheetUrl:URL;let petJson:PetManifest
    }
    private struct PokeFeed:Decodable { let pets:[PokePet];let license_note:String }
    private struct PokePet:Decodable {
        let slug:String;let name:String;let description:String;let category:String;let style:String
        let license:String;let author:String
    }
    private struct RepositoryPet:Decodable { let id:String;let displayName:String;let description:String;let path:String }
    private struct OrgPet:Decodable {
        let id:String;let displayName:String;let description:String;let author:String;let kind:String?
        let pageUrl:URL;let spritesheetUrl:URL;let manifestUrl:URL
    }
    private struct DavidPet:Decodable {
        struct Files:Decodable { let pet_json:String;let spritesheet:String }
        let id:String;let display_name:String;let display_name_zh:String?;let status:String
        let short_description:String;let short_description_zh:String?;let category:[String];let files:Files
    }
    private struct RitoPet:Decodable { let id:String;let name:String;let description:String;let sprite:String;let version:Int }
    private struct ArkFeed:Decodable { let schemaVersion:Int;let pets:[ArkPet] }
    private struct ArkPet:Decodable { let id:String;let displayName:String;let category:String;let status:String;let packagePath:String }

    static func decode(_ data:Data,source:PetSource) throws -> [PetTheme] {
        let decoder=JSONDecoder()
        let unknownAuthor=L("作者未提供", "Author not provided")
        let unknownLicense=L("来源未声明素材授权，请查阅原始主题页面。", "The source has not declared an artwork license. See the original theme page.")
        let base=source.catalogURL.deletingLastPathComponent()
        switch source.format {
        case .petdex:
            return try decoder.decode(Feed<PetdexPet>.self,from:data).pets.filter { [1,2].contains($0.spriteVersionNumber ?? 1) }.map { pet in
                let author=pet.submittedBy?.trimmingCharacters(in:.whitespacesAndNewlines)
                return .init(remoteID:pet.slug,sourceID:source.id,name:pet.displayName,summary:"",
                    author:author?.isEmpty == false ? L("投稿：", "Submitted by ")+author! : unknownAuthor,license:unknownLicense,category:pet.kind ?? "",
                    manifestURL:pet.petJsonUrl,previewURL:pet.spritesheetUrl,websiteURL:source.websiteURL.appendingPathComponent("pets/\(pet.slug)"),
                    previewIsSprite:true,spriteURL:pet.spritesheetUrl)
            }
        case .codexPet:
            return try decoder.decode(Feed<CodexPet>.self,from:data).pets.map { pet in
                try pet.petJson.validate()
                return .init(remoteID:pet.slug,sourceID:source.id,name:pet.displayName,summary:pet.description ?? "",
                    author:unknownAuthor,license:unknownLicense,category:"",manifestURL:source.catalogURL,previewURL:pet.spritesheetUrl,
                    websiteURL:source.websiteURL.appendingPathComponent("pets/\(pet.slug)"),previewIsSprite:true,spriteURL:pet.spritesheetUrl,inlineManifest:pet.petJson)
            }
        case .pokePets:
            let feed=try decoder.decode(PokeFeed.self,from:data)
            return feed.pets.map { pet in
                .init(remoteID:pet.slug,sourceID:source.id,name:pet.name+(pet.style == "3d" ? " · 3D" : ""),summary:pet.description,
                    author:pet.author,license:feed.license_note+"\n"+pet.license,category:pet.category,
                    manifestURL:base.appendingPathComponent("pets/\(pet.slug)/pet.json"),previewURL:base.appendingPathComponent("pets/\(pet.slug)/preview.gif"),
                    websiteURL:source.websiteURL.appendingPathComponent("tree/main/pets/\(pet.slug)"))
            }
        case .petsCodex:
            return try decoder.decode(Feed<RepositoryPet>.self,from:data).pets.map { pet in
                guard PetURL.safeComponent(pet.path),!pet.path.hasPrefix(".") else { throw PetStoreError.invalidCatalog }
                return .init(remoteID:pet.id,sourceID:source.id,name:pet.displayName,summary:pet.description,
                    author:unknownAuthor,license:unknownLicense,category:"",manifestURL:base.appendingPathComponent("\(pet.path)/pet.json"),
                    previewURL:base.appendingPathComponent("\(pet.path)/spritesheet.webp"),websiteURL:source.websiteURL.appendingPathComponent("tree/main/\(pet.path)"),previewIsSprite:true)
            }
        case .codexPetsOrg:
            return try decoder.decode([OrgPet].self,from:data).map { pet in
                .init(remoteID:pet.id,sourceID:source.id,name:pet.displayName,summary:pet.description,author:pet.author,license:unknownLicense,
                    category:pet.kind ?? "",manifestURL:pet.manifestUrl,previewURL:pet.spritesheetUrl,websiteURL:pet.pageUrl,previewIsSprite:true,spriteURL:pet.spritesheetUrl)
            }
        case .david:
            return try decoder.decode(Feed<DavidPet>.self,from:data).pets.filter { $0.status == "ready" }.map { pet in
                guard pet.files.pet_json == "pets/\(pet.id)/pet.json",pet.files.spritesheet == "pets/\(pet.id)/spritesheet.webp" else { throw PetStoreError.invalidCatalog }
                return .init(remoteID:pet.id,sourceID:source.id,name:(AppLanguage.chinese ? pet.display_name_zh : nil) ?? pet.display_name,
                    summary:(AppLanguage.chinese ? pet.short_description_zh : nil) ?? pet.short_description,
                    author:L("维护：David-Lzy", "Maintained by David-Lzy"),license:L("原创与同人素材条款见来源声明；同人素材限非商业个人使用。", "See the source notice for original and fan assets; fan assets are for non-commercial personal use."),
                    category:pet.category.joined(separator:", "),manifestURL:base.appendingPathComponent(pet.files.pet_json),
                    previewURL:base.appendingPathComponent("pets/\(pet.id)/assets/previews/idle.gif"),websiteURL:source.websiteURL.appendingPathComponent("tree/main/pets/\(pet.id)"),
                    licenseURL:base.appendingPathComponent("NOTICE.md"))
            }
        case .rito:
            return try decoder.decode(Feed<RitoPet>.self,from:data).pets.filter { [1,2].contains($0.version) }.map { pet in
                guard pet.sprite == "pets/\(pet.id)/spritesheet.webp" else { throw PetStoreError.invalidCatalog }
                return .init(remoteID:pet.id,sourceID:source.id,name:pet.name,summary:pet.description,author:unknownAuthor,license:unknownLicense,category:"",
                    manifestURL:base.appendingPathComponent("pets/\(pet.id)/pet.json"),previewURL:base.appendingPathComponent(pet.sprite),
                    websiteURL:source.websiteURL.appendingPathComponent("tree/main/pets/\(pet.id)"),previewIsSprite:true)
            }
        case .arknights:
            let feed=try decoder.decode(ArkFeed.self,from:data)
            guard feed.schemaVersion == 1 else { throw PetStoreError.invalidCatalog }
            let root=base.deletingLastPathComponent()
            return try feed.pets.filter { $0.status == "approved" }.map { pet in
                guard pet.packagePath == "pets/\(pet.id)" else { throw PetStoreError.invalidCatalog }
                return .init(remoteID:pet.id,sourceID:source.id,name:pet.displayName,summary:"",author:L("转换：lockon-n · 素材：Hypergryph", "Conversion: lockon-n · art: Hypergryph"),
                    license:L("明日方舟游戏素材，权利归原权利人；本包不授予再分发或商业使用权。", "Arknights game assets belong to their rights holders; this package grants no redistribution or commercial rights."),
                    category:pet.category,manifestURL:root.appendingPathComponent("\(pet.packagePath)/pet.json"),previewURL:root.appendingPathComponent("\(pet.packagePath)/spritesheet.webp"),
                    websiteURL:source.websiteURL.appendingPathComponent("tree/main/\(pet.packagePath)"),previewIsSprite:true,licenseURL:root.appendingPathComponent("\(pet.packagePath)/SOURCE.md"))
            }
        default:throw PetStoreError.invalidCatalog
        }
    }
}
