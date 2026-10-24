// Foresite Mind for iPhone and iPad.
// Two native tabs around Connor's live pages on claude.ai (the Mind and its Actions list), so connectors and live data
// keep working, plus what a browser tab can't do: quick add, a home-screen widget, Siri and Shortcuts, and notifications.

import UIKit
import UserNotifications
import WidgetKit

let mindURL = URL(string: "https://claude.ai/artifact/LmigqKi9fAFxftarLdS7JT")!
let actionsURL = URL(string: "https://claude.ai/artifact/VPE28AeUPqaTcKx1Dyj37d")!

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = ink
        window.overrideUserInterfaceStyle = .dark
        window.tintColor = jade
        let root = RootTabs()
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        AppRouter.shared.root = root

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        return true
    }

    // foresitemind://mind, foresitemind://actions, foresitemind://add — from the widget and from Shortcuts.
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard url.scheme == Shared.urlScheme else { return false }
        AppRouter.shared.open(url.host ?? "")
        return true
    }

    // Show banners while the app is open too; that is when they are most likely to fire.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        AppRouter.shared.open((response.notification.request.content.userInfo["open"] as? String) ?? "mind")
        completionHandler()
    }
}

/// One place the widget, Siri, notifications and links all go through to reach the tabs.
final class AppRouter {
    static let shared = AppRouter()
    weak var root: RootTabs?
    private var pending: String?

    func open(_ target: String) {
        guard let root = root else { pending = target; return }
        switch target {
        case "actions": root.show(.actions)
        case "add": root.show(.actions); root.presentQuickAdd()
        default: root.show(.mind)
        }
    }

    func rootDidAppear() { if let p = pending { pending = nil; open(p) } }

    /// Adds a line to the Actions list through its page, waiting up to 20 s for the page to be ready.
    @MainActor
    func add(text: String, section: String = "triage") async -> String {
        guard let root = root else { return "Mind isn't open yet. Try again in a moment." }
        for _ in 0..<40 {
            if root.actions.bridgeFrame != nil { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return await withCheckedContinuation { cont in
            root.addAction(text: text, section: section) { result in
                switch result {
                case .success(let where_): cont.resume(returning: "Added to \(where_).")
                case .failure(let error): cont.resume(returning: error.localizedDescription)
                }
            }
        }
    }
}
