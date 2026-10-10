import Foundation
import CryptoKit

enum PetStoreError: Error, LocalizedError {
    case invalidURL, invalidCatalog, invalidManifest, invalidImage, tooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidURL: return L("请使用不含登录信息的公开 HTTPS 地址。", "Use a public HTTPS URL without login information.")
        case .invalidCatalog: return L("主题目录格式不受支持。", "This theme catalog format is not supported.")
        case .invalidManifest: return L("主题文件信息不完整或格式不受支持。", "The theme manifest is incomplete or unsupported.")
        case .invalidImage: return L("主题精灵图不符合 Codex Pet 格式。", "The sprite sheet does not match the Codex Pet format.")
        case .tooLarge: return L("主题文件超过大小限制。", "This theme file exceeds the size limit.")
        case .unavailable: return L("暂时无法连接，请稍后重试。", "Could not connect. Try again later.")
        }
    }
}

enum PetURL {
    static func validate(_ url: URL) throws -> URL {
        guard let c = URLComponents(url:url,resolvingAgainstBaseURL:false), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, c.fragment == nil, c.port == nil || c.port == 443,
              let host = c.host?.lowercased(), host.contains("."), !host.contains(":"),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              host != "localhost", !host.hasSuffix("."), url.absoluteString.count <= 2048 else { throw PetStoreError.invalidURL }
        let octets = host.split(separator:".")
        if octets.allSatisfy({ Int($0) != nil }) {
            guard octets.count == 4, let a = Int(octets[0]), let b = Int(octets[1]),
                  octets.allSatisfy({ (0...255).contains(Int($0) ?? -1) }),
                  ![0,10,127].contains(a), !(a == 169 && b == 254), !(a == 172 && (16...31).contains(b)),
                  !(a == 192 && b == 168), !(a == 100 && (64...127).contains(b)), a < 224 else { throw PetStoreError.invalidURL }
        }
        if c.queryItems?.contains(where:{ ["token","access_token","api_key","apikey","password","auth"].contains($0.name.lowercased()) }) == true {
            throw PetStoreError.invalidURL
        }
        return url
    }
    static func parse(_ text: String) throws -> URL {
        guard let url = URL(string:text) else { throw PetStoreError.invalidURL }
        return try validate(url)
    }
    static func key(_ text: String) -> String { SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined() }
    static func safeComponent(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 180 && text != "." && text != ".." && text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_ .".unicodeScalars.contains($0)
        } && !text.contains("/") && !text.contains("\\")
    }
}

struct PetSource: Codable, Identifiable, Equatable {
    enum Format: String, Codable { case catalog = "buddy", huaqing, cuteChen, legeling, senyo, petdex, codexPet, pokePets, petsCodex, codexPetsOrg, david, rito, arknights }
    var id: String
    var name: String
    var catalogURL: URL
    var websiteURL: URL
    var format: Format
    var enabled: Bool = true
    var builtIn: Bool = false
    static var defaults: [PetSource] {
        [PetSource(id:"huaqing",name:"Awesome Codex Pets",catalogURL:URL(string:"https://raw.githubusercontent.com/HuaqingAI/awesome-codex-pets/main/catalog/pets.json")!,websiteURL:URL(string:"https://github.com/HuaqingAI/awesome-codex-pets")!,format:.huaqing,builtIn:true),
         PetSource(id:"cutechen",name:"Codex Pet",catalogURL:URL(string:"https://raw.githubusercontent.com/Cute-chen/codex-pet/main/pets.json")!,websiteURL:URL(string:"https://github.com/Cute-chen/codex-pet")!,format:.cuteChen,builtIn:true),
         PetSource(id:"legeling",name:"Codex Pet Gallery",catalogURL:URL(string:"https://raw.githubusercontent.com/legeling/awesome-codex-pet/main/pets.json")!,websiteURL:URL(string:"https://github.com/legeling/awesome-codex-pet")!,format:.legeling,builtIn:true),
         PetSource(id:"senyo",name:"Senyo’s Codex Pets",catalogURL:URL(string:"https://raw.githubusercontent.com/senyo888/codex-pets/main/catalog.json")!,websiteURL:URL(string:"https://github.com/senyo888/codex-pets")!,format:.senyo,builtIn:true),
         PetSource(id:"petdex",name:"Petdex",catalogURL:URL(string:"https://petdex.dev/api/manifest")!,websiteURL:URL(string:"https://petdex.dev")!,format:.petdex,builtIn:true),
         PetSource(id:"codexpet",name:"codex-pet.com",catalogURL:URL(string:"https://codex-pet.com/api/manifest")!,websiteURL:URL(string:"https://codex-pet.com")!,format:.codexPet,builtIn:true),
         PetSource(id:"pokepets",name:"Codex PokéPets",catalogURL:URL(string:"https://raw.githubusercontent.com/dnnyngyen/codex-pokepets/main/pets.json")!,websiteURL:URL(string:"https://github.com/dnnyngyen/codex-pokepets")!,format:.pokePets,builtIn:true),
         PetSource(id:"petscodex",name:"Pets Codex",catalogURL:URL(string:"https://raw.githubusercontent.com/mn8821236/petscodex/main/catalog.json")!,websiteURL:URL(string:"https://github.com/mn8821236/petscodex")!,format:.petsCodex,builtIn:true),
         PetSource(id:"codexpetsorg",name:"codexpets.org",catalogURL:URL(string:"https://raw.githubusercontent.com/eyichan/awesome-codex-pets/main/pets.json")!,websiteURL:URL(string:"https://codexpets.org")!,format:.codexPetsOrg,builtIn:true),
         PetSource(id:"david",name:"David’s Pet Collection",catalogURL:URL(string:"https://raw.githubusercontent.com/David-Lzy/codex_anime_pets/main/catalog.json")!,websiteURL:URL(string:"https://github.com/David-Lzy/codex_anime_pets")!,format:.david,builtIn:true),
         PetSource(id:"rito",name:"Rito’s Pet Gallery",catalogURL:URL(string:"https://rito-w.github.io/codex-pet-gallery/pets.json")!,websiteURL:URL(string:"https://github.com/Rito-w/codex-pet-gallery")!,format:.rito,builtIn:true),
         PetSource(id:"arknights",name:L("明日方舟宠物", "Arknights Pets"),catalogURL:URL(string:"https://raw.githubusercontent.com/lockon-n/Arknights-Codex-Pets/main/registry/pets.json")!,websiteURL:URL(string:"https://github.com/lockon-n/Arknights-Codex-Pets")!,format:.arknights,builtIn:true)]
    }
    var maximumCatalogBytes:Int { format == .catalog ? 2_000_000 : 6_000_000 }
    var maximumThemeCount:Int {
        switch format { case .petdex,.codexPet,.pokePets,.petsCodex:return 8000;default:return 500 }
    }
    var statisticsURL:URL? {
        format == .legeling ? URL(string:"https://raw.githubusercontent.com/legeling/awesome-codex-pet/main/web/public/stats.json") : nil
    }
    static func custom(url:URL) throws -> PetSource {
        let safe = try PetURL.validate(url)
        return .init(id:"custom-"+PetURL.key(safe.absoluteString),name:safe.host ?? "Catalog",catalogURL:safe,websiteURL:safe,format:.catalog)
    }
}

struct PetTheme: Identifiable, Equatable, Codable {
    var remoteID: String
    var sourceID: String
    var name: String
    var summary: String
    var author: String
    var license: String
    var category: String
    var manifestURL: URL
    var previewURL: URL?
    var websiteURL: URL
    var previewIsSprite:Bool = false
    var spriteURL:URL? = nil
    var inlineManifest:PetManifest? = nil
    var licenseURL:URL? = nil
    var id: String { sourceID+":"+remoteID }
}

struct PetManifest: Codable, Equatable {
    var id: String?
    var displayName: String?
    var description: String?
    var spritesheetPath: String?
    var spriteVersionNumber: Int?
    var version: Int { spriteVersionNumber ?? 1 }
    var imagePath: String { spritesheetPath ?? "spritesheet.webp" }
    func validate() throws {
        guard [1,2].contains(version), PetURL.safeComponent(imagePath),
              ["png","webp"].contains((imagePath as NSString).pathExtension.lowercased()),
              (displayName?.count ?? 0) <= 160, (description?.count ?? 0) <= 2000 else { throw PetStoreError.invalidManifest }
    }
    func imageURL(relativeTo manifestURL:URL) throws -> URL {
        try validate()
        return try PetURL.validate(manifestURL.deletingLastPathComponent().appendingPathComponent(imagePath))
    }
    func installURL(imageURL:URL, fallbackName:String) throws -> URL {
        try validate();_ = try PetURL.validate(imageURL)
        let name = displayName?.trimmingCharacters(in:.whitespacesAndNewlines)
        var c = URLComponents();c.scheme = "codex";c.host = "pets";c.path = "/install"
        let finalName=(name?.isEmpty == false ? name! : fallbackName.trimmingCharacters(in:.whitespacesAndNewlines))
        guard !finalName.isEmpty,finalName.count <= 160 else { throw PetStoreError.invalidManifest }
        c.queryItems = [URLQueryItem(name:"name",value:finalName),
                       URLQueryItem(name:"imageUrl",value:imageURL.absoluteString),
                       URLQueryItem(name:"spriteVersionNumber",value:String(version))]
        if let description, !description.isEmpty { c.queryItems?.append(.init(name:"description",value:description)) }
        // The receiving desktop app uses URLSearchParams, which treats literal '+' as a space.
        c.percentEncodedQuery=c.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        guard !fallbackName.isEmpty, let url = c.url else { throw PetStoreError.invalidManifest }
        return url
    }
}

enum PetCatalog {
    private struct CustomFeed: Decodable {
        var schemaVersion: Int
        var name: String
        var websiteURL: URL
        var pets: [CustomPet]
    }
    private struct CustomPet: Decodable {
        var id: String;var name: String;var description: String;var author: String;var license: String
        var category: String?;var manifestURL: URL;var previewURL: URL?;var websiteURL: URL
    }
    private struct HuaqingFeed: Decodable { var pets: [HuaqingPet] }
    private struct HuaqingPet: Decodable {
        struct Author: Decodable { var name: String }
        var id: String;var name: String;var description: String;var category: String;var author: Author;var url: URL
    }
    private struct SenyoFeed: Decodable { var schemaVersion:Int;var pets:[SenyoPet] }
    private struct SenyoPet: Decodable {
        var id:String;var displayName:String;var description:String;var publicationState:String
        var previewPath:String;var installPage:URL
    }
    private struct GalleryPet:Decodable {
        var slug:String;var name:String;var localized_names:[String:String]?
        var author:String;var license:String;var description:String?;var primary_category:String
    }
    private struct CutePet: Decodable {
        var slug: String;var name: String;var author: String;var license: String;var description: String?;var primary_category: String
    }
    static func decode(_ data:Data,source:PetSource) throws -> (name:String,websiteURL:URL,pets:[PetTheme]) {
        guard data.count <= source.maximumCatalogBytes else { throw PetStoreError.tooLarge }
        do {
            let decoder = JSONDecoder()
            let themes: [PetTheme]
            var name = source.name;var site = source.websiteURL
            switch source.format {
            case .catalog:
                let feed = try decoder.decode(CustomFeed.self,from:data)
                guard feed.schemaVersion == 1, !feed.name.isEmpty, feed.name.count <= 100 else { throw PetStoreError.invalidCatalog }
                name = feed.name;site = try PetURL.validate(feed.websiteURL)
                themes = feed.pets.map { .init(remoteID:$0.id,sourceID:source.id,name:$0.name,summary:$0.description,author:$0.author,license:$0.license,category:$0.category ?? "",manifestURL:$0.manifestURL,previewURL:$0.previewURL,websiteURL:$0.websiteURL) }
            case .huaqing:
                let feed = try decoder.decode(HuaqingFeed.self,from:data)
                let base = source.catalogURL.deletingLastPathComponent().deletingLastPathComponent()
                themes = feed.pets.map { .init(remoteID:$0.id,sourceID:source.id,name:$0.name,summary:$0.description,author:$0.author.name,license:L("以原作者说明为准", "See original author’s terms"),category:$0.category,manifestURL:base.appendingPathComponent("pets/\($0.id)/pet.json"),previewURL:base.appendingPathComponent("assets/previews/\($0.id)/idle.gif"),websiteURL:$0.url) }
            case .cuteChen:
                let feed = try decoder.decode([CutePet].self,from:data)
                let base = source.catalogURL.deletingLastPathComponent()
                themes = feed.map { .init(remoteID:$0.slug,sourceID:source.id,name:$0.name,summary:$0.description ?? "",author:$0.author,license:$0.license,category:$0.primary_category,manifestURL:base.appendingPathComponent("pets/\($0.slug)/pet.json"),previewURL:base.appendingPathComponent("assets/previews/\($0.slug)/gifs/idle.gif"),websiteURL:source.websiteURL.appendingPathComponent("tree/main/pets/\($0.slug)")) }
            case .legeling:
                let feed=try decoder.decode([GalleryPet].self,from:data)
                let base=source.catalogURL.deletingLastPathComponent()
                themes=feed.map { pet in
                    let display=(AppLanguage.chinese ? pet.localized_names?["zh"] : pet.localized_names?["en"]) ?? pet.name
                    return .init(remoteID:pet.slug,sourceID:source.id,name:display,summary:pet.description ?? "",author:pet.author,license:pet.license,category:pet.primary_category,
                        manifestURL:base.appendingPathComponent("pets/\(pet.slug)/pet.json"),previewURL:base.appendingPathComponent("pets/\(pet.slug)/spritesheet.webp"),websiteURL:source.websiteURL.appendingPathComponent("tree/main/pets/\(pet.slug)"),previewIsSprite:true)
                }
            case .senyo:
                let feed=try decoder.decode(SenyoFeed.self,from:data)
                guard feed.schemaVersion == 2 else { throw PetStoreError.invalidCatalog }
                let base=source.catalogURL.deletingLastPathComponent()
                themes=try feed.pets.filter { $0.publicationState == "published" }.map { pet in
                    guard pet.previewPath == "pets/\(pet.id)/preview.gif" else { throw PetStoreError.invalidCatalog }
                    return .init(remoteID:pet.id,sourceID:source.id,name:pet.displayName,summary:pet.description,
                        author:pet.id == "aureo" ? "@0MartinSmith0 · Senyo" : "Senyo",license:"CC BY 4.0",category:L("原创小伙伴", "Original companions"),
                        manifestURL:base.appendingPathComponent("pets/\(pet.id)/pet.json"),previewURL:base.appendingPathComponent(pet.previewPath),websiteURL:source.websiteURL.appendingPathComponent("tree/main/pets/\(pet.id)"))
                }
            case .petdex,.codexPet,.pokePets,.petsCodex,.codexPetsOrg,.david,.rito,.arknights:
                themes=try PetCommunityCatalogs.decode(data,source:source)
            }
            guard themes.count <= source.maximumThemeCount, Set(themes.map(\.id)).count == themes.count else { throw PetStoreError.invalidCatalog }
            for theme in themes {
                guard PetURL.safeComponent(theme.remoteID), !theme.name.isEmpty, theme.name.count <= 160,
                      theme.summary.count <= 2000, !theme.author.isEmpty, theme.author.count <= 160,
                      !theme.license.isEmpty, theme.license.count <= 2000, theme.category.count <= 100 else { throw PetStoreError.invalidCatalog }
                _ = try PetURL.validate(theme.manifestURL);_ = try PetURL.validate(theme.websiteURL)
                if let url = theme.previewURL { _ = try PetURL.validate(url) }
                if let url = theme.spriteURL { _ = try PetURL.validate(url) }
                if let url = theme.licenseURL { _ = try PetURL.validate(url) }
                if let manifest=theme.inlineManifest { try manifest.validate() }
            }
            return (name,site,themes)
        } catch let error as PetStoreError { throw error }
        catch { throw PetStoreError.invalidCatalog }
    }
}
