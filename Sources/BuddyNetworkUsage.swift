import Foundation
import Combine

enum BuddyTransferKind: String, Codable, CaseIterable { case tags, catalog, preview, petPackage }
struct BuddyTrafficSnapshot: Codable, Equatable {
    var startedAt: Date
    var bytes: [String:Int64] = [:]
    var partial: Set<String> = []
    func value(_ kind: BuddyTransferKind) -> Int64 { bytes[kind.rawValue] ?? 0 }
    var total: Int64 { bytes.values.reduce(0) { Self.sum($0,$1) } }
    static func sum(_ a:Int64,_ b:Int64)->Int64 { let n=a.addingReportingOverflow(b);return n.overflow ? Int64.max : n.partialValue }
}
@MainActor final class BuddyNetworkSettings: ObservableObject {
    static let shared=BuddyNetworkSettings()
    @Published private(set) var traffic: BuddyTrafficSnapshot
    private let preferences: UserDefaults
    init(preferences:UserDefaults = .standard,now:Date = Date()) {
        self.preferences=preferences
        let saved=preferences.data(forKey:"network.traffic.v1").flatMap { try? JSONDecoder().decode(BuddyTrafficSnapshot.self,from:$0) }
        traffic=saved.flatMap { s in
            guard s.startedAt.timeIntervalSince1970.isFinite,s.startedAt <= now,
                  s.bytes.count <= 4,s.bytes.allSatisfy({ BuddyTransferKind(rawValue:$0.key) != nil && $0.value >= 0 }),
                  s.partial.allSatisfy({BuddyTransferKind(rawValue:$0) != nil}) else { return nil };return s
        } ?? .init(startedAt:now)
    }
    func record(_ kind:BuddyTransferKind,bytes:Int64,complete:Bool) {
        guard bytes >= 0 else { return }
        var next=traffic;next.bytes[kind.rawValue]=BuddyTrafficSnapshot.sum(next.value(kind),bytes)
        if !complete { next.partial.insert(kind.rawValue) }
        guard next != traffic else { return };traffic=next
        if let data=try? JSONEncoder().encode(next) { preferences.set(data,forKey:"network.traffic.v1") }
    }
    nonisolated static func recordTransfer(_ kind:BuddyTransferKind,bytes:Int64,complete:Bool) {
        Task { @MainActor in shared.record(kind,bytes:bytes,complete:complete) }
    }
}
