import Foundation

struct PetFavorite:Codable,Equatable,Identifiable {
    var theme:PetTheme
    var savedAt:Date
    var id:String { theme.id }
}

// Favorites belong only to this application's injected preferences. Keeping a
// catalog snapshot lets a saved theme remain useful when its source is offline.
struct PetFavoritesRepository {
    static let storageKey="pets.favorites"
    static let maximumCount=1000
    static let maximumBytes=4_000_000
    private let preferences:UserDefaults

    init(preferences:UserDefaults) { self.preferences=preferences }

    func read() -> [PetFavorite] {
        guard let data=preferences.object(forKey:Self.storageKey) as? Data,
              data.count <= Self.maximumBytes,
              let favorites=try? JSONDecoder().decode([PetFavorite].self,from:data),
              Self.valid(favorites) else { return [] }
        return favorites
    }

    @discardableResult func save(_ favorites:[PetFavorite]) -> Bool {
        guard Self.valid(favorites),let data=try? JSONEncoder().encode(favorites),
              data.count <= Self.maximumBytes else { return false }
        preferences.set(data,forKey:Self.storageKey)
        return true
    }

    // Only a matching source-qualified identity may refresh a saved snapshot.
    // A refreshed catalog must never change when the user saved the theme.
    static func updating(_ favorites:[PetFavorite],with themes:[PetTheme]) -> [PetFavorite] {
        var current=[String:PetTheme]()
        for theme in themes where valid(theme) { current[theme.id]=theme }
        return favorites.map { favorite in
            guard let theme=current[favorite.id] else { return favorite }
            return PetFavorite(theme:theme,savedAt:favorite.savedAt)
        }
    }

    private static func valid(_ favorites:[PetFavorite]) -> Bool {
        guard favorites.count <= maximumCount,
              Set(favorites.map(\.id)).count == favorites.count else { return false }
        return favorites.allSatisfy {
            let time=$0.savedAt.timeIntervalSince1970
            return time.isFinite && time >= 0 && time <= 253_402_300_799 && valid($0.theme)
        }
    }

    private static func valid(_ theme:PetTheme) -> Bool {
        // Colons are excluded so sourceID:remoteID cannot have ambiguous origins.
        guard !theme.sourceID.isEmpty,theme.sourceID.count <= 180,
              theme.sourceID.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 45 || byte == 95
              }),PetURL.safeComponent(theme.remoteID),
              !theme.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,theme.name.count <= 160,
              theme.summary.count <= 2000,
              !theme.author.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,theme.author.count <= 160,
              !theme.license.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,theme.license.count <= 2000,
              theme.category.count <= 100,
              (try? PetURL.validate(theme.manifestURL)) != nil,
              (try? PetURL.validate(theme.websiteURL)) != nil else { return false }
        if let preview=theme.previewURL,(try? PetURL.validate(preview)) == nil { return false }
        if let sprite=theme.spriteURL,(try? PetURL.validate(sprite)) == nil { return false }
        if let notice=theme.licenseURL,(try? PetURL.validate(notice)) == nil { return false }
        if let manifest=theme.inlineManifest,(try? manifest.validate()) == nil { return false }
        return true
    }
}
