import Foundation
import Combine

struct PetSearchRequest: Hashable {
    var revision: Int
    var query: String
    var sourceID: String
    var byInstalls: Bool
    var favoritesOnly: Bool
    var tagRevision = ""
    var selectedTagIDs = [String]()
    var locale = Locale.autoupdatingCurrent.identifier
}
struct PetSearchSnapshot {
    var themes: [PetTheme]
    var favorites: [PetTheme]
    var popularity: [String:PetPopularity]
    var names: [String:String]
    var tags: [String:[PetTag]] = [:]
}

// The actor builds both orders once per data revision and bounds repeated query
// results. No catalog decoding, sorting or search runs from a SwiftUI body.
actor PetSearchEngine {
    private var revision = -1
    private var locale = ""
    private var named = [PetTheme](), popular = [PetTheme]()
    private var favoriteIDs = Set<String>()
    private var text = [String:String]()
    private var results = [PetSearchRequest:[PetTheme]]()
    func clear() { revision = -1;named = [];popular = [];favoriteIDs = [];text = [:];results = [:] }
    func query(_ original: PetSearchRequest,snapshot: PetSearchSnapshot) throws -> [PetTheme] {
        var request=original;request.selectedTagIDs=Array(Set(request.selectedTagIDs)).sorted()
        try Task.checkCancellation()
        if revision != request.revision || locale != request.locale {
            var all = snapshot.themes
            let ids = Set(all.map(\.id))
            all += snapshot.favorites.filter { !ids.contains($0.id) }
            named = all.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            popular = named.sorted {
                let x = snapshot.popularity[$0.id]?.installs ?? -1,y = snapshot.popularity[$1.id]?.installs ?? -1
                if x != y { return x > y }
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            favoriteIDs = Set(snapshot.favorites.map(\.id))
            text = Dictionary(uniqueKeysWithValues:all.map { theme in
                (theme.id,([theme.name,theme.author,theme.summary,theme.category,snapshot.names[theme.sourceID] ?? theme.sourceID]+(snapshot.tags[theme.id] ?? []).map { $0.label.text })
                    .joined(separator:"\n").folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:request.locale)))
            })
            revision = request.revision;locale = request.locale;results = [:]
        }
        try Task.checkCancellation()
        if let result = results[request] { return result }
        let needle = request.query.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:request.locale))
        let availableIDs = Set(snapshot.themes.map(\.id))
        let facets=Dictionary(grouping:request.selectedTagIDs) { String($0.split(separator:".").first ?? "") }
        let result = (request.byInstalls ? popular : named).filter { theme in
            (request.favoritesOnly ? favoriteIDs.contains(theme.id) : availableIDs.contains(theme.id)) &&
            (request.sourceID.isEmpty || theme.sourceID == request.sourceID) &&
            (needle.isEmpty || text[theme.id]?.contains(needle) == true) &&
            facets.values.allSatisfy { wanted in !Set(wanted).isDisjoint(with:Set((snapshot.tags[theme.id] ?? []).map(\.id))) }
        }
        try Task.checkCancellation()
        if results.count >= 12 { results = [:] }
        results[request] = result;return result
    }
}

@MainActor final class PetQueryModel: ObservableObject {
    @Published private(set) var themes = [PetTheme]()
    private var generation = 0
    private var previous: PetSearchRequest?
    func load(_ request: PetSearchRequest,store: ThemeStoreModel) async {
        generation += 1;let ticket = generation
        let typing = previous?.query != request.query && !request.query.isEmpty
        previous = request
        do {
            if typing { try await Task.sleep(nanoseconds:120_000_000) }
            let result = try await store.search(request)
            guard !Task.isCancelled,ticket == generation else { return }
            if themes != result { themes = result }
        } catch {}
    }
}
