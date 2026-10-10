import Foundation

enum PetFavoritesTests {
    private final class MemoryPreferences:UserDefaults {
        var values=[String:Any]()
        override func object(forKey key:String) -> Any? { values[key] }
        override func set(_ value:Any?,forKey key:String) { values[key]=value }
    }

    static func run() throws {
        let preferences=MemoryPreferences()
        let repository=PetFavoritesRepository(preferences:preferences)
        let date=Date(timeIntervalSince1970:1_700_000_000)
        var theme=PetTheme(remoteID:"synthetic-cat",sourceID:"synthetic-source",name:"Synthetic Cat",
            summary:"A synthetic fixture",author:"Synthetic Author",license:"CC0\nFixture attribution",
            category:"Cats",manifestURL:URL(string:"https://example.com/pets/cat/pet.json")!,
            previewURL:URL(string:"https://example.com/pets/cat/idle.png")!,
            websiteURL:URL(string:"https://example.com/themes/cat")!)
        let favorite=PetFavorite(theme:theme,savedAt:date)
        precondition(repository.read().isEmpty)
        precondition(repository.save([favorite]))
        precondition(repository.read()==[favorite])
        let restarted=PetFavoritesRepository(preferences:preferences)
        precondition(restarted.read()==[favorite],"Snapshots must survive a new repository instance")
        precondition(preferences.values.count==1 && preferences.values[PetFavoritesRepository.storageKey] is Data,
            "Saving favorites must touch only the app's favorites preference")

        var other=theme;other.sourceID="different-source"
        let otherFavorite=PetFavorite(theme:other,savedAt:date.addingTimeInterval(60))
        precondition(favorite.id != otherFavorite.id)
        precondition(repository.save([favorite,otherFavorite]))
        precondition(repository.read().count==2,"Matching remote names from different sources remain distinct")
        precondition(repository.save(repository.read().filter { $0.id != favorite.id }))
        precondition(repository.read()==[otherFavorite],"Unfavoriting must preserve the other source")
        precondition(repository.save([]) && repository.read().isEmpty)
        precondition(repository.save([favorite]))
        precondition(!repository.save([favorite,favorite]) && repository.read()==[favorite])

        theme.name="Updated Cat";theme.summary="New catalog metadata"
        let refreshed=PetFavoritesRepository.updating([favorite,otherFavorite],with:[theme])
        precondition(refreshed[0].theme==theme && refreshed[0].savedAt==date)
        precondition(refreshed[1]==otherFavorite,"Disabled or unavailable sources keep their saved metadata")
        precondition(PetFavoritesRepository.updating([favorite],with:[])==[favorite])

        for keyPath in [\PetTheme.manifestURL,\PetTheme.websiteURL] {
            var invalid=favorite
            invalid.theme[keyPath:keyPath]=URL(string:"https://user:synthetic@example.com/private")!
            precondition(!repository.save([invalid]) && repository.read()==[favorite])
        }
        for url in ["file:///tmp/fixture.png","http://example.com/image.png","https://127.0.0.1/image.png",
                    "https://example.com/image.png?access_token=synthetic"] {
            var invalid=favorite;invalid.theme.previewURL=URL(string:url)!
            precondition(!repository.save([invalid]) && repository.read()==[favorite])
        }
        for id in ["", "../synthetic", "source:another",String(repeating:"a",count:181)] {
            var invalid=favorite;invalid.theme.sourceID=id
            precondition(!repository.save([invalid]))
        }
        var invalid=favorite;invalid.theme.remoteID="../escape"
        precondition(!repository.save([invalid]))
        invalid=favorite;invalid.theme.name="  \n"
        precondition(!repository.save([invalid]))
        invalid=favorite;invalid.theme.license=String(repeating:"a",count:2001)
        precondition(!repository.save([invalid]))
        invalid=favorite;invalid.savedAt=Date(timeIntervalSince1970:-1)
        precondition(!repository.save([invalid]))
        invalid=favorite;invalid.savedAt=Date(timeIntervalSince1970:.infinity)
        precondition(!repository.save([invalid]))

        var many=[PetFavorite]()
        for index in 0..<PetFavoritesRepository.maximumCount {
            var entry=favorite;entry.theme.remoteID="synthetic-\(index)";many.append(entry)
        }
        precondition(repository.save(many) && repository.read().count==PetFavoritesRepository.maximumCount)
        var extra=favorite;extra.theme.remoteID="over-limit"
        precondition(!repository.save(many+[extra]))
        for index in many.indices {
            many[index].theme.summary=String(repeating:"s",count:2000)
            many[index].theme.license=String(repeating:"l",count:2000)
        }
        precondition(!repository.save(many),"Encoded snapshots must also obey the total byte limit")

        for corrupt in [Data("not JSON".utf8),Data("{}".utf8),Data(repeating:0,count:PetFavoritesRepository.maximumBytes+1)] {
            preferences.values[PetFavoritesRepository.storageKey]=corrupt
            precondition(repository.read().isEmpty)
            precondition(preferences.values[PetFavoritesRepository.storageKey] as? Data==corrupt,
                "Reading corrupted data must never overwrite stored preferences")
        }
        var unsafe=favorite;unsafe.theme.websiteURL=URL(string:"file:///tmp/fixture")!
        preferences.values[PetFavoritesRepository.storageKey]=try JSONEncoder().encode([unsafe])
        precondition(repository.read().isEmpty)
        preferences.values[PetFavoritesRepository.storageKey]="wrong type"
        precondition(repository.read().isEmpty)
        precondition(repository.save([favorite]) && repository.read()==[favorite])
        print("Pet favorites passed: source-qualified identities, bounded offline snapshots, restart persistence, metadata refresh, synthetic URL validation and corruption handling")
    }
}
