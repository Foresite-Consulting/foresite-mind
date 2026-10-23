// Foresite Mind — a native Mac app around Connor's live Mind dashboard.
// The dashboard itself lives at claude.ai as an artifact, so connectors and live data keep working.
// The page tells the app what it sees (through the "mind" message bridge); the app adds what a browser tab can't:
// a live menu-bar count, Mac notifications, global hot keys, quick add, wallpaper and ambient modes,
// Siri / Shortcuts commands (foresitemind://…), and an update notice.

import AppKit
import AVFoundation
import Carbon
import ServiceManagement
import UserNotifications
import WebKit

let mindURL = URL(string: "https://claude.ai/artifact/LmigqKi9fAFxftarLdS7JT")!
let releasesURL = URL(string: "https://github.com/Foresite-Consulting/foresite-mind/releases/latest")!
// Present as Safari so claude.ai and Google sign-in treat this like a normal browser.
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
let ink = NSColor(srgbRed: 0x04 / 255.0, green: 0x28 / 255.0, blue: 0x2C / 255.0, alpha: 1)
let coral = NSColor(srgbRed: 1, green: 0x66 / 255.0, blue: 0x50 / 255.0, alpha: 1)
let jade = NSColor(srgbRed: 0x6D / 255.0, green: 0xA0 / 255.0, blue: 0x97 / 255.0, alpha: 1)
// Pages that may load in the app's own window. Everything else opens in the default browser.
let inAppHosts = ["claude.ai", "anthropic.com", "claudeusercontent.com", "accounts.google.com", "appleid.apple.com",
                  "login.microsoftonline.com", "login.microsoft.com", "login.live.com", "microsoftonline.com", "msauth.net", "msftauth.net"]
let quietAfterMs = 3.0 * 3600 * 1000

// Only ordinary web links leave the app. App hand-offs (claude://, etc.) are dropped, so the Mind
// never bounces you into the Claude desktop app the way a browser tab can.
func openExternally(_ url: URL?) {
    guard let url = url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" || scheme == "mailto" else { return }
    NSWorkspace.shared.open(url)
}

func isInAppHost(_ url: URL?) -> Bool {
    guard let url = url else { return true }
    if url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" { return true }
    guard let host = url.host?.lowercased() else { return false }
    return inAppHosts.contains { host == $0 || host.hasSuffix("." + $0) }
}

struct Session {
    let id, name, device, status, detail, company: String
    let updated: Double
    /// running · done · failed · quiet (running with no update for 3 hours, as the Mind shows it)
    var state: String {
        if status == "running", Date().timeIntervalSince1970 * 1000 - updated > quietAfterMs { return "quiet" }
        return status
    }
    var place: String {
        switch device {
        case "Mac mini": return "on the Mac mini"
        case "MacBook Air": return "on the MacBook Air"
        case "Cloud": return "in the cloud"
        case "Scheduled task": return "as a scheduled task"
        case "": return ""
        default: return "on " + device
        }
    }
}

/// Receives the page's messages. Kept separate so the web view doesn't hold the app delegate strongly.
final class Bridge: NSObject, WKScriptMessageHandler {
    weak var app: AppDelegate?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        app?.receive(object, frame: message.frameInfo)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
                         UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var status: NSStatusItem!
    var normalFrame: NSRect?
    let bridge = Bridge()
    lazy var quickAdd = QuickAdd()
    let speech = AVSpeechSynthesizer()
    var pendingURLs: [URL] = []
    var launched = false

    // what the page last told us
    var mindFrame: WKFrameInfo?
    var sessions: [Session] = []
    var agents: [(id: String, role: String, company: String)] = []
    var actionsOpen: Int?
    var heard = false
    var latestVersion: String?
    var latestRelease: Updater.Release?
    var updating = false

    // change tracking for notifications
    var seenStates: [String: String] = [:]
    var seenAgents: Set<String> = []
    var seenUpdated: [String: Double] = [:]
    var primed = false

    // modes
    var peeking = false
    var ambientOn = false
    var shownBeforeAmbient = false
    var extraWallpapers: [String: NSWindow] = [:]

    let defaults = UserDefaults.standard
    var wallpaper: Bool {
        get { defaults.bool(forKey: "wallpaperMode") }
        set { defaults.set(newValue, forKey: "wallpaperMode") }
    }
    /// "main", "all", or a display's name
    var wallpaperDisplay: String {
        get { defaults.string(forKey: "wallpaperDisplay") ?? "main" }
        set { defaults.set(newValue, forKey: "wallpaperDisplay") }
    }
    /// minutes of idle before ambient mode; 0 is off
    var ambientMinutes: Int {
        get { defaults.object(forKey: "ambientMinutes") as? Int ?? 10 }
        set { defaults.set(newValue, forKey: "ambientMinutes") }
    }
    /// Hide claude.ai's bar while the Mind is a window too (it is always hidden in wallpaper and ambient modes).
    var hideBarInWindow: Bool {
        get { defaults.object(forKey: "hideBar") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "hideBar") }
    }
    func syncBar() {
        let hide = wallpaper || ambientOn || hideBarInWindow
        web?.evaluateJavaScript("window.__mindSetBar && window.__mindSetBar(\(hide))")
        extraWallpapers.values.forEach { ($0.contentView as? WKWebView)?.evaluateJavaScript("window.__mindSetBar && window.__mindSetBar(true)") }
    }
    var notificationsOn: Bool {
        get { defaults.object(forKey: "notifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifications") }
    }
    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var appVersionWithBuild: String { appVersion + "." + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        bridge.app = self
        buildMainMenu()
        buildWindow()
        buildStatusItem()
        applyMode(animate: false, front: true)
        web.load(URLRequest(url: mindURL))

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        quickAdd.send = { [weak self] text, done in self?.addAction(text, done: done) }
        HotKeys.shared.register(id: 1, keyCode: kVK_ANSI_M, modifiers: optionKey) { [weak self] in self?.toggleMind() }
        HotKeys.shared.register(id: 2, keyCode: kVK_ANSI_A, modifiers: optionKey | shiftKey) { [weak self] in self?.showQuickAdd() }
        HotKeys.shared.register(id: 3, keyCode: kVK_ANSI_W, modifiers: optionKey | shiftKey) { [weak self] in self?.toggleWallpaper() }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Idle watch for ambient mode, and a minute tick so "went quiet" is noticed even when nothing else changes.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.ambientTick() }
        checkForUpdate(quiet: true)
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdate(quiet: true) }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.noticeChanges()
            self.refreshStatusItem()
        }
        launched = true
        pendingURLs.forEach(handle)
        pendingURLs = []
    }

    // MARK: window and web view

    func makeWebView(bridged: Bool) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // keeps the claude.ai sign-in between launches
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        if bridged { config.userContentController.add(bridge, name: "mind") }
        // claude.ai draws its own bar (Home, Chat, Share) across the top of the page. The page can hide it on request:
        // the bar is found by its Share button, so if claude.ai changes its layout the worst case is the bar stays.
        let barScript = """
        (function(){var want=false;
          function bar(){var btn=Array.prototype.slice.call(document.querySelectorAll('button')).filter(function(b){return /^\\s*Share\\s*$/.test(b.textContent||'')})[0];if(!btn)return null;
            var el=btn;for(var i=0;i<10&&el;i++){el=el.parentElement;if(!el)break;var r=el.getBoundingClientRect();if(r.width>window.innerWidth*.9&&r.height>0&&r.height<90)return el}return null}
          function apply(){var el=bar();if(el)el.style.display=want?'none':''}
          window.__mindSetBar=function(h){want=!!h;apply()};
          new MutationObserver(function(){if(want)apply()}).observe(document.documentElement,{childList:true,subtree:true});})();
        """
        config.userContentController.addUserScript(WKUserScript(source: barScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = safariUA
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        view.underPageBackgroundColor = ink
        return view
    }

    func buildWindow() {
        web = makeWebView(bridged: true)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let start = NSRect(x: screen.minX + screen.width * 0.08, y: screen.minY + screen.height * 0.08,
                           width: screen.width * 0.84, height: screen.height * 0.84)
        window = NSWindow(contentRect: start, styleMask: normalStyle, backing: .buffered, defer: false)
        window.title = "Foresite Mind"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ink
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = web
        window.setFrameAutosaveName("ForesiteMindWindow")
    }

    let normalStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

    /// The screen minus the menu bar strip, so the Mind's own header never sits under the clock and menu-bar icons.
    func belowMenuBar(_ screen: NSScreen?) -> NSRect? {
        guard let s = screen else { return nil }
        var f = s.frame
        let menuBar = s.frame.maxY - s.visibleFrame.maxY
        f.size.height -= max(0, menuBar)
        return f
    }

    /// The Dock icon's right-click menu is the same as the menu-bar menu, for a notched screen that hides the icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        fillStatusMenu(menu)
        return menu
    }

    func wallpaperScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if wallpaperDisplay != "main" && wallpaperDisplay != "all",
           let named = screens.first(where: { $0.localizedName == wallpaperDisplay }) { return named }
        return screens.first ?? NSScreen.main
    }

    func applyMode(animate: Bool, front: Bool) {
        peeking = false
        if wallpaper {
            if window.level == .normal { normalFrame = window.frame }
            let frame = belowMenuBar(wallpaperScreen()) ?? window.frame
            window.styleMask = [.borderless]
            window.level = desktopLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.hasShadow = false
            window.setFrame(frame, display: true, animate: false)
            window.orderBack(nil)
        } else {
            window.styleMask = normalStyle
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.level = .normal
            window.collectionBehavior = [.managed, .fullScreenPrimary]
            window.hasShadow = true
            if let f = normalFrame { window.setFrame(f, display: true, animate: animate) }
            if front { window.makeKeyAndOrderFront(nil) }
        }
        syncExtraWallpapers()
        syncBar()
    }

    /// "All displays": every other screen gets its own borderless Mind behind its windows.
    func syncExtraWallpapers() {
        let wanted: [NSScreen] = (wallpaper && wallpaperDisplay == "all")
            ? NSScreen.screens.filter { $0 != wallpaperScreen() } : []
        let names = Set(wanted.map { $0.localizedName })
        for (name, w) in extraWallpapers where !names.contains(name) { w.orderOut(nil); w.close(); extraWallpapers[name] = nil }
        for screen in wanted {
            if let w = extraWallpapers[screen.localizedName] { w.setFrame(belowMenuBar(screen) ?? screen.frame, display: true); continue }
            let w = NSWindow(contentRect: belowMenuBar(screen) ?? screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.backgroundColor = ink
            w.level = desktopLevel
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.hasShadow = false
            let view = makeWebView(bridged: false) // only the main window reports, so nothing is counted twice
            w.contentView = view
            w.setFrame(belowMenuBar(screen) ?? screen.frame, display: true)
            view.load(URLRequest(url: mindURL))
            w.orderBack(nil)
            extraWallpapers[screen.localizedName] = w
        }
    }

    @objc func screensChanged() { if wallpaper { applyMode(animate: false, front: false) } }
    @objc func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.web.reload()
            self.extraWallpapers.values.forEach { ($0.contentView as? WKWebView)?.reload() }
        }
    }

    // Closing the window hides it; the app stays in the menu bar.
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMind(); return true }

    // MARK: page bridge

    func receive(_ object: [String: Any], frame: WKFrameInfo) {
        guard object["type"] as? String == "state" else { return }
        mindFrame = frame
        heard = true
        let rows = object["sessions"] as? [[String: Any]] ?? []
        sessions = rows.map { r in
            Session(id: r["id"] as? String ?? "",
                    name: r["name"] as? String ?? "Claude session",
                    device: r["device"] as? String ?? "",
                    status: r["status"] as? String ?? "done",
                    detail: r["detail"] as? String ?? "",
                    company: r["company"] as? String ?? "",
                    updated: (r["updated"] as? NSNumber)?.doubleValue ?? 0)
        }.filter { !$0.id.isEmpty }
        agents = (object["agents"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = a["id"] as? String else { return nil }
            return (id: id, role: a["role"] as? String ?? id, company: a["company"] as? String ?? "")
        }
        actionsOpen = (object["actionsOpen"] as? NSNumber)?.intValue
        if let latest = object["appLatest"] as? String { noteLatest(latest) }
        noticeChanges()
        refreshStatusItem()
    }

    func noticeChanges() {
        guard heard else { return }
        var states: [String: String] = [:]
        for s in sessions { states[s.id] = s.state }
        let agentIDs = Set(agents.map { $0.id })
        if primed && notificationsOn {
            for s in sessions {
                let before = seenStates[s.id], after = s.state
                // A scheduled task can start and finish between two polls, so it is never seen running.
                // A newer finish time on a done or failed task is a fresh run, and is announced as one.
                if s.id.hasPrefix("task-"), before == after, after == "done" || after == "failed",
                   let then = seenUpdated[s.id], s.updated > then + 1000 {
                    notify((after == "done" ? "Finished: " : "Failed: ") + s.name, "Scheduled task")
                    continue
                }
                guard let was = before, was != after else { continue }
                let line = [s.device, s.company].filter { !$0.isEmpty }.joined(separator: " · ")
                switch after {
                case "done": notify("Finished: " + s.name, [line, s.detail].filter { !$0.isEmpty }.joined(separator: "\n"))
                case "failed": notify("Failed: " + s.name, [line, s.detail].filter { !$0.isEmpty }.joined(separator: "\n"))
                case "quiet": notify("Went quiet: " + s.name, "No update for 3 hours" + (line.isEmpty ? "" : " · " + line))
                default: break
                }
            }
            for a in agents where !seenAgents.contains(a.id) {
                notify("New agent: " + a.role, a.company.isEmpty ? "Added to the Mind" : "Joined " + a.company)
            }
        }
        primed = true
        seenStates = states
        seenAgents = agentIDs
        for s in sessions { seenUpdated[s.id] = s.updated }
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            if response.notification.request.identifier == "update" { self.openUpdate() } else { self.showMind() }
        }
        completionHandler()
    }

    func noteLatest(_ latest: String) {
        guard latest.compare(appVersion, options: .numeric) == .orderedDescending else { latestVersion = nil; return }
        latestVersion = latest
        if defaults.string(forKey: "toldVersion") != latest {
            defaults.set(latest, forKey: "toldVersion")
            let content = UNMutableNotificationContent()
            content.title = "Foresite Mind \(latest) is ready"
            content.body = "Click to install it. The app updates itself and relaunches."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update", content: content, trigger: nil))
        }
    }

    /// Asks the public releases repo for the newest version. Quiet checks only remember what they find;
    /// a check from the menu reports the result either way.
    func checkForUpdate(quiet: Bool) {
        Updater.latest { [weak self] rel in
            guard let self = self else { return }
            self.latestRelease = rel
            if let rel = rel, Updater.isNewer(rel.version, than: self.appVersionWithBuild) {
                self.noteLatest(rel.version)
                if !quiet { self.offerUpdate(rel) }
            } else if !quiet {
                let a = NSAlert()
                a.messageText = rel == nil ? "Couldn't check for updates" : "Foresite Mind is up to date"
                a.informativeText = rel == nil ? "GitHub didn't answer, or the releases repo isn't set up yet." : "Version \(self.appVersion) is the newest."
                NSApp.activate(ignoringOtherApps: true); a.runModal()
            }
        }
    }

    func offerUpdate(_ rel: Updater.Release) {
        guard !updating else { return }
        let a = NSAlert()
        a.messageText = "Foresite Mind \(rel.version) is available"
        a.informativeText = "You have \(appVersion). The app downloads the update, swaps itself in Applications and relaunches. Your sign-in and settings are kept."
        a.addButton(withTitle: "Update Now")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        updating = true
        if let button = status.button { button.attributedTitle = NSAttributedString(string: " updating…") }
        Updater.install(rel, status: { [weak self] text in
            self?.status.button?.toolTip = text
        }, failed: { [weak self] message in
            self?.updating = false
            self?.refreshStatusItem()
            let f = NSAlert()
            f.messageText = "The update didn't install"
            f.informativeText = message + "\n\nNothing was changed. You can download it by hand from the release page."
            f.addButton(withTitle: "Open Release Page"); f.addButton(withTitle: "OK")
            if f.runModal() == .alertFirstButtonReturn { openExternally(rel.page) }
        })
    }

    /// Runs the page's own write path (the same queue the Actions strand uses).
    func addAction(_ text: String, done: @escaping (String?) -> Void) {
        guard let frame = mindFrame else {
            done("The Mind hasn't loaded yet. Open it once and make sure you're signed in.")
            return
        }
        web.callAsyncJavaScript("return await window.__mindAdd(text);", arguments: ["text": text],
                                in: frame, in: .page) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let value):
                    let reply = value as? [String: Any]
                    if reply?["ok"] as? Bool == true { done(nil) }
                    else { done(reply?["error"] as? String ?? "The Mind didn't confirm the write.") }
                case .failure:
                    done("The Mind page didn't answer. Reload it (⌘R) and try again.")
                }
            }
        }
    }

    // MARK: menu bar

    func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = status.button {
            let img = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: "Foresite Mind")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        refreshStatusItem()
    }

    func refreshStatusItem() {
        guard let button = status?.button else { return }
        let running = sessions.filter { $0.state == "running" }.count
        let quiet = sessions.filter { $0.state == "quiet" }.count
        if running > 0 {
            button.contentTintColor = coral
            button.attributedTitle = NSAttributedString(string: " \(running)", attributes: [
                .foregroundColor: coral, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
        } else {
            button.contentTintColor = quiet > 0 ? coral.withAlphaComponent(0.6) : nil
            button.attributedTitle = NSAttributedString(string: "")
        }
        button.toolTip = running > 0 ? "Claude is running \(running) task\(running == 1 ? "" : "s")" : "Foresite Mind"
    }

    func item(_ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = [], state: Bool = false) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
        it.state = state ? .on : .off
        return it
    }

    func fillStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let live = sessions.filter { $0.state == "running" || $0.state == "quiet" }
        let header = NSMenuItem(title: heard ? (live.isEmpty ? "Nothing running" : "Claude is working on") : "Waiting for the Mind to load…",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for s in live.prefix(8) {
            let it = item((s.state == "quiet" ? "◌ " : "● ") + s.name + (s.device.isEmpty ? "" : "  ·  " + s.device), #selector(showMind))
            it.toolTip = s.detail
            if s.state == "running" {
                it.attributedTitle = NSAttributedString(string: it.title, attributes: [.foregroundColor: coral])
            }
            menu.addItem(it)
        }
        if let n = actionsOpen {
            let a = NSMenuItem(title: "\(n) action\(n == 1 ? "" : "s") open", action: nil, keyEquivalent: "")
            a.isEnabled = false
            menu.addItem(a)
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Mind", #selector(toggleMind), key: "m", mods: [.option]))
        menu.addItem(item("Quick Add to Action List…", #selector(showQuickAdd), key: "a", mods: [.option, .shift]))
        menu.addItem(item("Say Claude's Status", #selector(speakStatus)))
        menu.addItem(.separator())
        menu.addItem(item("Wallpaper Mode", #selector(toggleWallpaper), key: "w", mods: [.option, .shift], state: wallpaper))

        let displays = NSMenu()
        displays.addItem(item("Main Display", #selector(pickDisplay(_:)), state: wallpaperDisplay == "main"))
        for screen in NSScreen.screens.dropFirst() {
            let it = item(screen.localizedName, #selector(pickDisplay(_:)), state: wallpaperDisplay == screen.localizedName)
            it.representedObject = screen.localizedName
            displays.addItem(it)
        }
        let all = item("All Displays", #selector(pickDisplay(_:)), state: wallpaperDisplay == "all")
        all.representedObject = "all"
        displays.addItem(all)
        let displaysItem = NSMenuItem(title: "Wallpaper Display", action: nil, keyEquivalent: "")
        displaysItem.submenu = displays
        menu.addItem(displaysItem)

        let ambient = NSMenu()
        for m in [0, 2, 5, 10, 15, 30] {
            let it = item(m == 0 ? "Off" : "After \(m) minutes idle", #selector(pickAmbient(_:)), state: ambientMinutes == m)
            it.tag = m
            ambient.addItem(it)
        }
        ambient.addItem(.separator())
        ambient.addItem(item("Start Now", #selector(startAmbient)))
        let ambientItem = NSMenuItem(title: "Ambient Mode", action: nil, keyEquivalent: "")
        ambientItem.submenu = ambient
        menu.addItem(ambientItem)
        menu.addItem(item("Notifications", #selector(toggleNotifications), state: notificationsOn))
        menu.addItem(item("Hide claude.ai Bar in Window", #selector(toggleBar), state: hideBarInWindow))
        menu.addItem(.separator())
        if let v = latestVersion {
            let up = item("Update to \(v)…", #selector(openUpdate))
            up.attributedTitle = NSAttributedString(string: up.title, attributes: [.foregroundColor: jade])
            menu.addItem(up)
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkNow)))
        }
        menu.addItem(item("Siri & Shortcuts…", #selector(showShortcutsHelp)))
        menu.addItem(item("Reload", #selector(reload)))
        menu.addItem(item("Open at Login", #selector(toggleLogin), state: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Foresite Mind", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
    }

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About Foresite Mind", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Foresite Mind", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Foresite Mind", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        let wp = view.addItem(withTitle: "Wallpaper Mode", action: #selector(toggleWallpaper), keyEquivalent: "w")
        wp.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view

        NSApp.mainMenu = main
    }

    // MARK: actions

    @objc func showMind() {
        if ambientOn { exitAmbient() }
        if wallpaper { wallpaper = false; applyMode(animate: true, front: true) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// ⌥M. In a window: show or hide it. In wallpaper mode: lift the Mind above your windows, and drop it back.
    @objc func toggleMind() {
        if ambientOn { exitAmbient(); return }
        if wallpaper {
            if peeking {
                applyMode(animate: false, front: false)
            } else {
                peeking = true
                window.level = .floating
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
            }
            return
        }
        if window.isVisible && NSApp.isActive && window.isKeyWindow { window.orderOut(nil) } else { showMind() }
    }

    @objc func showQuickAdd() { quickAdd.show() }
    @objc func toggleWallpaper() { wallpaper.toggle(); applyMode(animate: true, front: true) }
    @objc func reload() { web.reload() }
    @objc func openUpdate() {
        if let rel = latestRelease, Updater.isNewer(rel.version, than: appVersionWithBuild) { offerUpdate(rel) }
        else { checkForUpdate(quiet: false) }
    }
    @objc func checkNow() { checkForUpdate(quiet: false) }
    @objc func toggleNotifications() { notificationsOn.toggle() }
    @objc func toggleBar() { hideBarInWindow.toggle(); syncBar() }

    @objc func pickDisplay(_ sender: NSMenuItem) {
        wallpaperDisplay = sender.representedObject as? String ?? "main"
        if wallpaper { applyMode(animate: false, front: false) }
    }

    @objc func pickAmbient(_ sender: NSMenuItem) { ambientMinutes = sender.tag }

    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "Move Foresite Mind into your Applications folder and try again, or add it in System Settings › General › Login Items.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    // MARK: spoken status (Siri / Shortcuts)

    func statusSentence() -> String {
        guard heard else { return "The Mind hasn't loaded yet, so I can't see what Claude is doing." }
        let running = sessions.filter { $0.state == "running" }
        let quiet = sessions.filter { $0.state == "quiet" }
        var parts: [String] = []
        if running.isEmpty {
            parts.append("Claude has nothing running right now.")
        } else {
            let named = running.prefix(4).map { [$0.name, $0.place].filter { !$0.isEmpty }.joined(separator: " ") }
            let list = named.count > 1 ? named.dropLast().joined(separator: ", ") + ", and " + named.last! : named[0]
            parts.append("Claude is running \(running.count) task\(running.count == 1 ? "" : "s"): \(list).")
        }
        if !quiet.isEmpty {
            parts.append("\(quiet.count) task\(quiet.count == 1 ? " has" : "s have") gone quiet.")
        }
        if let n = actionsOpen { parts.append("You have \(n) action\(n == 1 ? "" : "s") open.") }
        return parts.joined(separator: " ")
    }

    @objc func speakStatus() {
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: statusSentence())
        utterance.voice = AVSpeechSynthesisVoice(language: "en-AU")
        speech.speak(utterance)
    }

    @objc func showShortcutsHelp() {
        let alert = NSAlert()
        alert.messageText = "Siri & Shortcuts"
        alert.informativeText = """
        Make a shortcut with one action, Open URLs, using one of these. Siri runs a shortcut when you say its name.

        foresitemind://say — speak what Claude is doing
        foresitemind://show · hide · toggle — the Mind window
        foresitemind://add — open quick add
        foresitemind://add?text=Call%20Shane — add a line straight away
        foresitemind://wallpaper/on · off · toggle
        foresitemind://ambient — start ambient mode now

        For Focus modes, use a Shortcuts automation ("When Do Not Disturb turns on") that opens foresitemind://hide.
        """
        alert.addButton(withTitle: "Open Shortcuts")
        alert.addButton(withTitle: "Copy Status Link")
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("foresitemind://say", forType: .string)
        default: break
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { urls.forEach(handle) } else { pendingURLs += urls }
    }

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "foresitemind" else { return }
        let command = (url.host ?? "").lowercased()
        let argument = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        switch command {
        case "say", "status": speakStatus()
        case "show", "open": showMind()
        case "hide": if ambientOn { exitAmbient() }; if !wallpaper { window.orderOut(nil) }
        case "toggle": toggleMind()
        case "reload": reload()
        case "ambient": startAmbient()
        case "wallpaper":
            switch argument {
            case "on": wallpaper = true
            case "off": wallpaper = false
            default: wallpaper.toggle()
            }
            applyMode(animate: true, front: !wallpaper)
        case "add":
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "text" })?.value ?? ""
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                showQuickAdd()
            } else {
                addAction(text) { [weak self] error in
                    self?.notify(error == nil ? "Added to your Action List queue" : "Not added",
                                 error ?? text)
                }
            }
        default: showMind()
        }
    }

    // MARK: ambient mode

    func idleSeconds() -> Double {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    func screenLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func ambientTick() {
        let idle = idleSeconds()
        if ambientOn {
            if idle < 1 { exitAmbient() }
            return
        }
        guard ambientMinutes > 0, idle >= Double(ambientMinutes * 60), !screenLocked(),
              !(window.styleMask.contains(.fullScreen)) else { return }
        enterAmbient()
    }

    @objc func startAmbient() {
        // started by hand: give the menu or shortcut a moment to settle before the next input wakes it
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.enterAmbient() }
    }

    func enterAmbient() {
        guard !ambientOn else { return }
        ambientOn = true
        shownBeforeAmbient = window.isVisible && !wallpaper
        if window.level == .normal { normalFrame = window.frame }
        let screen = NSScreen.main ?? NSScreen.screens.first
        window.styleMask = [.borderless]
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        if let frame = screen?.frame { window.setFrame(frame, display: true) }
        window.alphaValue = 0
        window.orderFrontRegardless()
        syncBar()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.6
            window.animator().alphaValue = 1
        }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func exitAmbient() {
        guard ambientOn else { return }
        ambientOn = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            window.animator().alphaValue = 0
        }, completionHandler: {
            self.applyMode(animate: false, front: false)
            if !self.wallpaper {
                if self.shownBeforeAmbient { self.window.orderFront(nil) } else { self.window.orderOut(nil) }
            }
            self.window.alphaValue = 1
        })
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Subframes (the artifact itself runs in one) always load; only top-level navigations are filtered.
        if let frame = action.targetFrame, !frame.isMainFrame { decisionHandler(.allow); return }
        if isInAppHost(action.request.url) { decisionHandler(.allow); return }
        // Redirects and form posts (sign-in hand-offs) stay in the app; only links you click go to the browser.
        let scheme = action.request.url?.scheme?.lowercased()
        if action.navigationType != .linkActivated, scheme == "https" || scheme == "http" {
            decisionHandler(.allow); return
        }
        openExternally(action.request.url)
        decisionHandler(.cancel)
    }

    // Links that ask for a new window: sign-in pages load here, everything else goes to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isInAppHost(url) { webView.load(action.request) } else { openExternally(url) }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === web { mindFrame = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.syncBar() }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === status.menu { fillStatusMenu(menu) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
