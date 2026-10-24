// Home-screen and lock-screen widget: what's running, open actions, triage, and the next diary item,
// as of the last time the app was open.

import SwiftUI
import WidgetKit

private let inkC = Color(red: 0x04 / 255.0, green: 0x28 / 255.0, blue: 0x2C / 255.0)
private let jadeC = Color(red: 0x6D / 255.0, green: 0xA0 / 255.0, blue: 0x97 / 255.0)
private let coralC = Color(red: 1, green: 0x66 / 255.0, blue: 0x50 / 255.0)
private let amberC = Color(red: 0xE9 / 255.0, green: 0xB4 / 255.0, blue: 0x4C / 255.0)
private let fogC = Color(red: 0xC9 / 255.0, green: 0xDB / 255.0, blue: 0xD8 / 255.0)

struct MindEntry: TimelineEntry {
    let date: Date
    let snap: MindSnapshot
}

struct MindProvider: TimelineProvider {
    func placeholder(in context: Context) -> MindEntry { MindEntry(date: Date(), snap: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (MindEntry) -> Void) {
        let s = MindSnapshot.load()
        completion(MindEntry(date: Date(), snap: context.isPreview && s.updated == .distantPast ? .sample : s))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MindEntry>) -> Void) {
        // The data only changes when the app runs, which reloads the timeline itself. Refresh every half hour anyway
        // so "next" and "as of" stay truthful as the clock moves.
        let now = Date()
        let s = MindSnapshot.load()
        let entries = (0..<4).map { MindEntry(date: now.addingTimeInterval(Double($0) * 1800), snap: s) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(7200))))
    }
}

private func hhmm(_ d: Date) -> String {
    let f = DateFormatter()
    f.timeZone = TimeZone(identifier: "Australia/Perth")
    f.dateFormat = "HH:mm"
    return f.string(from: d)
}

private func asOf(_ s: MindSnapshot, now: Date) -> String {
    if s.updated == .distantPast { return "Open Mind to sync" }
    let m = Int(now.timeIntervalSince(s.updated) / 60)
    if m < 2 { return "Just now" }
    if m < 60 { return "\(m) min ago" }
    if m < 48 * 60 { return "\(m / 60) h ago" }
    return "\(m / 1440) days ago"
}

private func upcoming(_ s: MindSnapshot, now: Date) -> String? {
    guard let subject = s.nextSubject, let start = s.nextStart, start.addingTimeInterval(3600) > now else { return nil }
    return start <= now ? "Now · \(subject)" : "\(hhmm(start)) · \(subject)"
}

struct Stat: View {
    let value: String
    let label: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 24, weight: .regular, design: .monospaced)).foregroundColor(color).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.system(size: 11)).foregroundColor(fogC.opacity(0.7)).lineLimit(1)
        }
    }
}

struct MindWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: MindEntry

    var body: some View {
        let s = entry.snap
        switch family {
        case .accessoryInline:
            Text(s.running > 0 ? "\(s.running) running · \(s.triage ?? 0) triage" : "\(s.openActions ?? 0) open · \(s.triage ?? 0) triage")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(s.running > 0 ? "● \(s.running) running" : "Mind · idle").font(.headline).widgetAccentable()
                Text("\(s.openActions ?? 0) open · \(s.triage ?? 0) in triage").font(.caption)
                if let next = upcoming(s, now: entry.date) { Text(next).font(.caption).lineLimit(1) }
            }
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    header(s)
                    HStack(spacing: 14) {
                        Stat(value: "\(s.running)", label: "running", color: s.running > 0 ? coralC : .white)
                        Stat(value: s.openActions.map(String.init) ?? "–", label: "open", color: .white)
                        Stat(value: s.triage.map(String.init) ?? "–", label: "triage", color: amberC)
                    }
                    Spacer(minLength: 0)
                    Text(asOf(s, now: entry.date)).font(.system(size: 10, design: .monospaced)).foregroundColor(fogC.opacity(0.45))
                }
                VStack(alignment: .leading, spacing: 5) {
                    if let next = upcoming(s, now: entry.date) {
                        Text("NEXT").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(jadeC)
                        Text(next).font(.system(size: 12)).foregroundColor(.white).lineLimit(2)
                    }
                    if !s.runningNames.isEmpty {
                        Text("NOW").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(coralC).padding(.top, 2)
                        Text(s.runningNames.joined(separator: ", ")).font(.system(size: 12)).foregroundColor(.white).lineLimit(2)
                    } else if let top = s.topActions.first {
                        Text("DECIDE").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(jadeC).padding(.top, 2)
                        Text(top).font(.system(size: 12)).foregroundColor(.white).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .widgetURL(URL(string: "\(Shared.urlScheme)://actions"))
        default:
            VStack(alignment: .leading, spacing: 6) {
                header(s)
                Spacer(minLength: 0)
                Stat(value: "\(s.running)", label: s.running == 1 ? "session running" : "sessions running", color: s.running > 0 ? coralC : .white)
                HStack(spacing: 12) {
                    Stat(value: s.openActions.map(String.init) ?? "–", label: "open", color: .white)
                    Stat(value: s.triage.map(String.init) ?? "–", label: "triage", color: amberC)
                }
            }
            .widgetURL(URL(string: "\(Shared.urlScheme)://mind"))
        }
    }

    @ViewBuilder private func header(_ s: MindSnapshot) -> some View {
        HStack(spacing: 6) {
            Circle().fill(s.running > 0 ? coralC : jadeC).frame(width: 7, height: 7)
            Text("MIND").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(fogC)
        }
    }
}

private struct MindBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) { inkC }
        } else {
            content.padding().background(inkC)
        }
    }
}

struct MindWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MindWidget", provider: MindProvider()) { entry in
            MindWidgetView(entry: entry).modifier(MindBackground())
        }
        .configurationDisplayName("Mind")
        .description("What Claude is running, your open actions and triage, and what's next in the diary.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct MindWidgets: WidgetBundle {
    var body: some Widget { MindWidget() }
}
