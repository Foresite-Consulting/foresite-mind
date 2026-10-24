// What the app last saw, shared with the widget through the app group.
// The app writes it whenever the Mind or Actions page reports new state; the widget only reads it.

import Foundation

enum Shared {
    static let group = "group.com.wardmark.foresite-mind"
    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }
    static let urlScheme = "foresitemind"
}

struct MindSnapshot: Codable, Equatable {
    var running: Int = 0
    var runningNames: [String] = []
    var openActions: Int?
    var triage: Int?
    var closedWeek: Int?
    var nextSubject: String?
    var nextStart: Date?
    var topActions: [String] = []
    var updated: Date = .distantPast

    static func load() -> MindSnapshot {
        guard let data = Shared.defaults.data(forKey: "snapshot"),
              let snap = try? JSONDecoder().decode(MindSnapshot.self, from: data) else { return MindSnapshot() }
        return snap
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { Shared.defaults.set(data, forKey: "snapshot") }
    }

    /// A sample used for widget previews and the gallery before the app has ever run.
    static var sample: MindSnapshot {
        var s = MindSnapshot()
        s.running = 2; s.runningNames = ["Morning debrief"]; s.openActions = 140; s.triage = 222; s.closedWeek = 19
        s.nextSubject = "SQCDP"; s.nextStart = Date().addingTimeInterval(3600); s.topActions = ["Decide the Werribee headcount"]
        s.updated = Date()
        return s
    }
}
