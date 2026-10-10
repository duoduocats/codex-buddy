import Foundation

// These are the source's public action counters, not global active-user counts.
struct PetPopularity:Codable,Equatable {
    var installs:Int?
    var likes:Int?
    var installs7d:Int?
    var likes7d:Int?
}
struct PetPopularitySnapshot {
    var generatedAt:Date
    var pets:[String:PetPopularity]
    private struct Feed:Decodable { var generatedAt:Double;var windowDays:Int;var pets:[String:PetPopularity] }
    static func decode(_ data:Data) throws -> Self {
        guard data.count <= 2_000_000 else { throw PetStoreError.tooLarge }
        let feed=try JSONDecoder().decode(Feed.self,from:data)
        let date=Date(timeIntervalSince1970:feed.generatedAt/1000)
        guard feed.generatedAt.isFinite,feed.generatedAt > 0,date <= Date().addingTimeInterval(86400),feed.windowDays == 7,feed.pets.count <= 5000 else { throw PetStoreError.invalidCatalog }
        for (id,stats) in feed.pets {
            guard PetURL.safeComponent(id),[stats.installs,stats.likes,stats.installs7d,stats.likes7d].compactMap({$0}).allSatisfy({$0 >= 0 && $0 <= 1_000_000_000_000}) else { throw PetStoreError.invalidCatalog }
        }
        return .init(generatedAt:date,pets:feed.pets)
    }
}
