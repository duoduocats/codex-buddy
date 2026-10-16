import Foundation

// Decoder-only synthetic snapshots: no URLSession, login or user cache reads.
@main struct ResetAnnouncementTests {
    static let now = Date(timeIntervalSince1970: 1_791_734_400)
    static let formatter = ISO8601DateFormatter()
    static func event(id: String = "synthetic-reset", type: String = "globalReset", status: String = "completed") -> [String: Any] {
        var row: [String: Any] = ["id": id, "revision": 1, "type": type, "status": status,
            "publishedAt": formatter.string(from: now.addingTimeInterval(-60)),
            "expiresAt": formatter.string(from: now.addingTimeInterval(86_400)),
            "title": ["zh": "合成公告", "en": "Synthetic announcement"],
            "body": ["zh": "仅供测试", "en": "Test only"],
            "sourceURL": "https://x.com/thsottiaux/status/1234567890123456789"]
        if type == "globalReset" { row["appliesTo"] = ["zh": "合成范围", "en": "Synthetic scope"] }
        if status == "scheduled" { row["scheduledAt"] = formatter.string(from: now.addingTimeInterval(600)) }
        return row
    }
    static func data(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "events": rows], options: [.sortedKeys])
    }
    static func decode(_ row: [String: Any]) throws -> ResetAnnouncement {
        try ResetAnnouncementDocument.decode(data([row]), now: now).events[0]
    }
    static func rejects(_ rows: [[String: Any]], _ label: String) throws {
        do { _ = try ResetAnnouncementDocument.decode(data(rows), now: now); preconditionFailure("accepted \(label)") }
        catch { }
    }
    static func check(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        let legacy = try decode(event())
        precondition(legacy.resetEffect == nil && legacy.globalScopeID == nil && legacy.campaignID == nil && legacy.relatedEventID == nil)
        let oldMessage = try decode(event(type: "message", status: "scheduled"))
        precondition(oldMessage.resetEffect == nil && oldMessage.type == "message")
        var complete = event()
        complete["resetEffect"] = "immediateQuotaReset"; complete["globalScopeID"] = "all-paid-chatgpt"
        complete["campaignID"] = "challenge-2026"; complete["relatedEventID"] = "prior-event"
        let richer = try decode(complete)
        precondition(richer.resetEffect == .immediateQuotaReset && richer.globalScopeID == "all-paid-chatgpt")
        precondition(richer.campaignID == "challenge-2026" && richer.relatedEventID == "prior-event")
        for status in ["scheduled", "cancelled"] {
            var lifecycle = complete; lifecycle["status"] = status
            if status == "scheduled" { lifecycle["scheduledAt"] = formatter.string(from: now.addingTimeInterval(600)) }
            let item = try decode(lifecycle)
            precondition(item.resetEffect == .immediateQuotaReset && item.status.rawValue == status)
        }
        var credits = event(type: "message"); credits["resetEffect"] = "credits"; credits["campaignID"] = "challenge-2026"
        check(try decode(credits).resetEffect == .credits)
        var other = event(type: "message"); other["resetEffect"] = "other"
        check(try decode(other).resetEffect == .other)
        var partial = event(); partial["globalScopeID"] = "all-paid-chatgpt"
        let partialItem = try decode(partial)
        precondition(partialItem.resetEffect == nil && partialItem.campaignID == nil)
        var explicitUnknown = event()
        for key in ["resetEffect", "globalScopeID", "campaignID", "relatedEventID"] { explicitUnknown[key] = NSNull() }
        let unknown = try decode(explicitUnknown)
        precondition(unknown.resetEffect == nil && unknown.globalScopeID == nil)
        for key in ["globalScopeID", "campaignID", "relatedEventID"] {
            for value in ["", "../bad", "@account", "contains space", String(repeating: "x", count: 81), "dot.id"] {
                var invalid = complete; invalid[key] = value; try rejects([invalid], "unsafe \(key)")
            }
            for value: Any in [true, 42, ["bad"], ["id": "bad"]] {
                var invalid = complete; invalid[key] = value; try rejects([invalid], "wrong-type \(key)")
            }
        }
        for value: Any in ["grant", "ImmediateQuotaReset", "unknown", true, 42] {
            var invalid = complete; invalid["resetEffect"] = value; try rejects([invalid], "unknown effect")
        }
        var typedMessage = complete; typedMessage["type"] = "message"
        let enrichedMessage = try decode(typedMessage)
        precondition(enrichedMessage.type == "message" && enrichedMessage.resetEffect == .immediateQuotaReset)
        precondition(enrichedMessage.globalScopeID == "all-paid-chatgpt" && enrichedMessage.campaignID == "challenge-2026")
        for row in [complete,typedMessage] {
            var missingScopeText = row; missingScopeText.removeValue(forKey: "appliesTo")
            try rejects([missingScopeText], "scope ID without bilingual scope text")
            for invalidText: Any in [["zh": "范围", "en": ""], ["zh": "范围"], ["zh": "  ", "en": "Scope"]] {
                var incompleteScope = row; incompleteScope["appliesTo"] = invalidText
                try rejects([incompleteScope], "incomplete bilingual scope")
            }
        }
        var wrongType = complete; wrongType["type"] = "quotaReset"; try rejects([wrongType], "unknown record type")
        var wrongScope = event(type: "message"); wrongScope["globalScopeID"] = "all-paid-chatgpt"
        try rejects([wrongScope], "generic message scope without appliesTo")
        var wrongCredit = complete; wrongCredit["resetEffect"] = "credits"; try rejects([wrongCredit], "credit grant typed global reset")
        var invalidStatus = complete; invalidStatus["status"] = "verified"; try rejects([invalidStatus], "unknown status")
        var invalidType = complete; invalidType["type"] = "quotaReset"; try rejects([invalidType], "unknown type")
        var selfReference = complete; selfReference["relatedEventID"] = "synthetic-reset"
        try rejects([selfReference], "self-reference")
        var a = event(id: "event-a"), b = event(id: "event-b"), c = event(id: "event-c")
        a["relatedEventID"] = "event-b"; b["relatedEventID"] = "event-c"; c["relatedEventID"] = "event-a"
        try rejects([a,b,c], "reference cycle")
        c["relatedEventID"] = "outside-retained-history"
        let chain = try ResetAnnouncementDocument.decode(data([a,b,c]), now: now)
        precondition(chain.events.count == 3)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let roundTrip = try ResetAnnouncementDocument.decode(encoder.encode(ResetAnnouncementDocument(schemaVersion: 1, events: [richer])), now: now)
        precondition(roundTrip.events[0] == richer)
        print("Reset announcement metadata tests passed: legacy nil compatibility, typed effects/scope/campaign/reference, explicit generic-message resets, complete bilingual scope, lifecycle status, round-trip, malformed IDs/types/effects and relation-cycle rejection")
    }
}
