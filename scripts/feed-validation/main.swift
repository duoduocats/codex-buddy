import Foundation

@main struct FeedValidation {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 || args.count == 3 else { fatalError("Expected message and challenge paths, plus optional previous directory") }
        let messages = try ResetAnnouncementDocument.decode(Data(contentsOf:URL(fileURLWithPath:args[0])))
        let challenge = try TiboChallengeDocument.decode(Data(contentsOf:URL(fileURLWithPath:args[1])))
        if args.count == 3 {
            let previous = URL(fileURLWithPath:args[2],isDirectory:true)
            let messagePath = previous.appendingPathComponent("messages.json")
            if FileManager.default.fileExists(atPath:messagePath.path) {
                let old = try ResetAnnouncementDocument.decode(Data(contentsOf:messagePath))
                for event in old.events {
                    if let next = messages.events.first(where:{ $0.id == event.id }) {
                        guard next.revision >= event.revision, next.revision != event.revision || next == event else { throw ResetAnnouncementFailure.invalid }
                    } else if event.expiresAt > Date() { throw ResetAnnouncementFailure.invalid }
                }
            }
            let challengePath = previous.appendingPathComponent("tibo-28.json")
            if FileManager.default.fileExists(atPath:challengePath.path) {
                let old = try TiboChallengeDocument.decode(Data(contentsOf:challengePath))
                guard old.accepts(challenge) else { throw ResetAnnouncementFailure.invalid }
            }
        }
        print("Public feed validation passed: \(messages.events.count) messages, \(challenge.records.count) activity records")
    }
}
