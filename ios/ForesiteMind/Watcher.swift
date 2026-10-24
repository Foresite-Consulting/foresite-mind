// Reads what the two pages report, keeps the widget's snapshot current, and raises notifications when
// a session finishes or fails, a new agent appears, or new items land in triage.
// iOS pauses web pages soon after the app leaves the screen, so this runs while the app is open or just closed.

import Foundation
import UserNotifications
import WidgetKit

final class Watcher {
    private var snap = MindSnapshot.load()
    private var sessionStatus: [String: String]?   // nil until the first report after launch: that one is the baseline
    private var agentIds: Set<String>?
    private var lastTriage: Int?
    private var lastWidgetReload = Date.distantPast
    private var pendingReload = false

    static func sections(from json: String) -> [(key: String, name: String)]? {
        guard let obj = parse(json), let list = obj["sections"] as? [[String: Any]] else { return nil }
        return list.compactMap { s in
            guard let k = s["key"] as? String, let n = s["name"] as? String else { return nil }
            return (k, n)
        }
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: the Mind page: {type:"state", sessions:[{id,name,device,status,detail,company,updated}], agents:[{id,role,company}], next:{subject,start}}

    func mindState(_ json: String) {
        guard let obj = Watcher.parse(json), (obj["type"] as? String) == "state" else { return }
        let sessions = (obj["sessions"] as? [[String: Any]]) ?? []
        var statuses: [String: String] = [:]
        var running: [String] = []
        for s in sessions {
            guard let id = s["id"] as? String else { continue }
            let status = (s["status"] as? String) ?? "done"
            statuses[id] = status
            if status == "running" { running.append((s["name"] as? String) ?? "Claude session") }
        }
        if let before = sessionStatus {
            for s in sessions {
                guard let id = s["id"] as? String, let now = statuses[id], let was = before[id], was == "running", now != "running" else { continue }
                let name = (s["name"] as? String) ?? "Claude session"
                let detail = (s["detail"] as? String) ?? ""
                if now == "failed" { notify(title: "Failed: \(name)", body: detail, open: "mind", id: "s-\(id)") }
                else { notify(title: "Finished: \(name)", body: detail, open: "mind", id: "s-\(id)") }
            }
            for s in sessions {
                guard let id = s["id"] as? String, before[id] == nil, statuses[id] == "running" else { continue }
                let name = (s["name"] as? String) ?? "Claude session"
                let device = (s["device"] as? String).map { " on \($0)" } ?? ""
                notify(title: "Started: \(name)", body: "Running\(device).", open: "mind", id: "r-\(id)", quiet: true)
            }
        }
        sessionStatus = statuses

        let agents = (obj["agents"] as? [[String: Any]]) ?? []
        let ids = Set(agents.compactMap { $0["id"] as? String })
        if let before = agentIds {
            for a in agents {
                guard let id = a["id"] as? String, !before.contains(id) else { continue }
                let role = (a["role"] as? String) ?? "agent"
                let company = (a["company"] as? String) ?? ""
                notify(title: "New agent: \(role)", body: company.isEmpty ? "Added to the Mind." : "Added for \(company).", open: "mind", id: "a-\(id)")
            }
        }
        agentIds = ids

        var next = snap
        next.running = running.count
        next.runningNames = Array(running.prefix(3))
        if let n = obj["next"] as? [String: Any], let subject = n["subject"] as? String, let start = n["start"] as? Double {
            next.nextSubject = subject
            next.nextStart = Date(timeIntervalSince1970: start / 1000)
        } else if obj["next"] is NSNull {
            next.nextSubject = nil
            next.nextStart = nil
        }
        if next.openActions == nil, let open = obj["actionsOpen"] as? Int { next.openActions = open }
        store(next)
    }

    // MARK: the Actions page: {type:"actions", open, triage, closedWeek, top:[...], sections:[{key,name}]}

    func actionsState(_ json: String) {
        guard let obj = Watcher.parse(json), (obj["type"] as? String) == "actions" else { return }
        var next = snap
        next.openActions = obj["open"] as? Int
        let triage = obj["triage"] as? Int
        next.triage = triage
        next.closedWeek = obj["closedWeek"] as? Int
        next.topActions = (obj["top"] as? [String]) ?? []
        if let before = lastTriage, let now = triage, now > before {
            let n = now - before
            notify(title: n == 1 ? "1 new item in triage" : "\(n) new items in triage", body: "Open Actions to file them.", open: "actions", id: "t-\(Int(Date().timeIntervalSince1970))")
        }
        if triage != nil { lastTriage = triage }
        store(next)
    }

    // MARK: snapshot and widget

    private func store(_ next: MindSnapshot) {
        var n = next
        let changed = n.running != snap.running || n.runningNames != snap.runningNames || n.openActions != snap.openActions ||
            n.triage != snap.triage || n.closedWeek != snap.closedWeek || n.nextSubject != snap.nextSubject ||
            n.nextStart != snap.nextStart || n.topActions != snap.topActions
        n.updated = Date()
        snap = n
        snap.save()
        if changed { reloadWidget() }
    }

    /// WidgetKit budgets reloads, so changes are batched to at most one reload a minute.
    private func reloadWidget() {
        let wait = 60 - Date().timeIntervalSince(lastWidgetReload)
        if wait <= 0 {
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        } else if !pendingReload {
            pendingReload = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.pendingReload = false
                self?.lastWidgetReload = Date()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    // MARK: notifications

    private func notify(title: String, body: String, open: String, id: String, quiet: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(180))
        content.userInfo = ["open": open]
        if !quiet { content.sound = .default }
        if #available(iOS 15.0, *) { content.interruptionLevel = quiet ? .passive : .active }
        content.threadIdentifier = open
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
