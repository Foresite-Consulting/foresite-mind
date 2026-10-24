// The tab bar: Mind, Actions, and a + that opens quick add instead of a tab.

import UIKit

final class RootTabs: UITabBarController, UITabBarControllerDelegate {
    enum Tab: Int { case mind = 0, actions = 1 }

    let mind = WebTab(url: mindURL, bridge: "mind", title: "Mind", image: "brain.head.profile")
    let actions = WebTab(url: actionsURL, bridge: "actions", title: "Actions", image: "checklist")
    private let addSlot = UIViewController()
    let watcher = Watcher()
    /// Sections as the Actions page last reported them, for the quick-add picker.
    private(set) var sections: [(key: String, name: String)] = [("triage", "Inbox")]

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var childForStatusBarStyle: UIViewController? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        addSlot.tabBarItem = UITabBarItem(title: "Add", image: UIImage(systemName: "plus.circle.fill"), tag: 2)
        viewControllers = [mind, actions, addSlot]

        let look = UITabBarAppearance()
        look.configureWithOpaqueBackground()
        look.backgroundColor = ink
        look.shadowColor = fog.withAlphaComponent(0.12)
        for item in [look.stackedLayoutAppearance, look.inlineLayoutAppearance, look.compactInlineLayoutAppearance] {
            item.normal.iconColor = fog.withAlphaComponent(0.55)
            item.normal.titleTextAttributes = [.foregroundColor: fog.withAlphaComponent(0.55)]
            item.selected.iconColor = jade
            item.selected.titleTextAttributes = [.foregroundColor: jade]
        }
        tabBar.standardAppearance = look
        tabBar.scrollEdgeAppearance = look
        tabBar.tintColor = jade

        // Load both pages at launch so the Actions bridge is ready for quick add, Siri and the widget's counts.
        mind.loadViewIfNeeded()
        actions.loadViewIfNeeded()
        mind.onMessage = { [weak self] json in self?.watcher.mindState(json) }
        actions.onMessage = { [weak self] json in
            guard let self = self else { return }
            self.watcher.actionsState(json)
            if let secs = Watcher.sections(from: json), !secs.isEmpty { self.sections = secs }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppRouter.shared.rootDidAppear()
    }

    func show(_ tab: Tab) {
        presentedViewController?.dismiss(animated: false)
        selectedIndex = tab.rawValue
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController === addSlot { presentQuickAdd(); return false }
        // Tapping the tab you're already on reloads it, as in Safari.
        if viewController === selectedViewController, let tab = viewController as? WebTab { tab.reloadPage() }
        return true
    }

    func presentQuickAdd() {
        guard presentedViewController == nil else { return }
        let sheet = QuickAdd(sections: sections) { [weak self] text, section, done in
            self?.addAction(text: text, section: section, completion: done)
        }
        let nav = UINavigationController(rootViewController: sheet)
        if let pc = nav.sheetPresentationController { pc.detents = [.medium(), .large()]; pc.prefersGrabberVisible = true }
        present(nav, animated: true)
    }

    /// Hands the line to the Actions page, which writes it to the list. Completion gets the section name it went to.
    func addAction(text: String, section: String, completion: @escaping (Result<String, Error>) -> Void) {
        actions.callPage("return await window.__actionsAdd(text, sec);", arguments: ["text": text, "sec": section]) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let value):
                let dict = value as? [String: Any]
                if (dict?["ok"] as? Bool) == true {
                    completion(.success((dict?["section"] as? String) ?? "the list"))
                } else {
                    let msg = (dict?["error"] as? String) ?? "The Actions page didn't take it. Open the Actions tab and try again."
                    completion(.failure(NSError(domain: "Mind", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])))
                }
            }
        }
    }
}
