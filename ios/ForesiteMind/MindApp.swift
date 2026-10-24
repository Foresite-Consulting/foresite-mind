// Foresite Mind for iPhone and iPad — a thin native shell around Connor's live Mind dashboard.
// The dashboard stays an artifact on claude.ai, so its connectors and live data keep working;
// the app adds a home-screen icon, a kept sign-in, full-screen display without claude.ai's bar,
// pull to refresh, and a fresh reload when you come back to it after a while.

import UIKit
import WebKit

let mindURL = URL(string: "https://claude.ai/artifact/LmigqKi9fAFxftarLdS7JT")!
// Present as mobile Safari so claude.ai and Google / Microsoft sign-in treat this like a normal browser.
let safariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
let ink = UIColor(red: 0x04 / 255.0, green: 0x28 / 255.0, blue: 0x2C / 255.0, alpha: 1)
let jade = UIColor(red: 0x6D / 255.0, green: 0xA0 / 255.0, blue: 0x97 / 255.0, alpha: 1)
// Pages that may load inside the app. Everything else opens in Safari.
let inAppHosts = ["claude.ai", "anthropic.com", "claudeusercontent.com", "accounts.google.com", "appleid.apple.com",
                  "login.microsoftonline.com", "login.microsoft.com", "login.live.com", "microsoftonline.com", "msauth.net", "msftauth.net"]
// Coming back after this long reloads the page, so the Mind never shows a stale picture.
let reloadAfter: TimeInterval = 10 * 60

func isInAppHost(_ url: URL?) -> Bool {
    guard let url = url else { return true }
    if url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" { return true }
    guard let host = url.host?.lowercased() else { return false }
    return inAppHosts.contains { host == $0 || host.hasSuffix("." + $0) }
}

// Only ordinary web links leave the app. App hand-offs (claude://, etc.) are dropped, so the Mind
// never bounces you into the Claude app.
func openExternally(_ url: URL?) {
    guard let url = url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" || scheme == "mailto" else { return }
    UIApplication.shared.open(url)
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = ink
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = MindViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class MindViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private var web: WKWebView!
    private let refresher = UIRefreshControl()
    private var leftAt: Date?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ink

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // keeps the claude.ai sign-in between launches
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true
        // claude.ai draws its own bar (Chat, Share) across the top of the page; on a phone it costs too much room, so it is
        // hidden. It is found by its Share button, so if claude.ai changes its layout the worst case is the bar stays.
        let barScript = """
        (function(){
          function bar(){var btn=Array.prototype.slice.call(document.querySelectorAll('button')).filter(function(b){return /^\\s*Share\\s*$/.test(b.textContent||'')})[0];if(!btn)return null;
            var el=btn;for(var i=0;i<10&&el;i++){el=el.parentElement;if(!el)break;var r=el.getBoundingClientRect();if(r.width>window.innerWidth*.9&&r.height>0&&r.height<90)return el}return null}
          function apply(){var el=bar();if(el)el.style.display='none'}
          new MutationObserver(apply).observe(document.documentElement,{childList:true,subtree:true});apply();})();
        """
        config.userContentController.addUserScript(WKUserScript(source: barScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = safariUA
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = ink
        web.underPageBackgroundColor = ink
        web.scrollView.backgroundColor = ink
        web.allowsBackForwardNavigationGestures = true
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        refresher.tintColor = jade
        refresher.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        web.scrollView.refreshControl = refresher

        web.load(URLRequest(url: mindURL))

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(wentAway), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(cameBack), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func pullToRefresh() {
        if web.url == nil || !(web.url?.absoluteString.contains("/artifact/") ?? false) { web.load(URLRequest(url: mindURL)) } else { web.reload() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.refresher.endRefreshing() }
    }

    @objc private func wentAway() { leftAt = Date() }

    @objc private func cameBack() {
        if let left = leftAt, Date().timeIntervalSince(left) > reloadAfter { web.reload() }
        leftAt = nil
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Subframes (the artifact itself runs in one) always load; only top-level navigations are filtered.
        if let frame = action.targetFrame, !frame.isMainFrame { decisionHandler(.allow); return }
        if isInAppHost(action.request.url) { decisionHandler(.allow); return }
        // Redirects and form posts (sign-in hand-offs) stay in the app; only links you tap go to Safari.
        let scheme = action.request.url?.scheme?.lowercased()
        if action.navigationType != .linkActivated, scheme == "https" || scheme == "http" {
            decisionHandler(.allow); return
        }
        openExternally(action.request.url)
        decisionHandler(.cancel)
    }

    // Links that ask for a new window: sign-in pages load here, everything else goes to Safari.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isInAppHost(url) { webView.load(action.request) } else { openExternally(url) }
        }
        return nil
    }

    // Page alerts and confirms (claude.ai uses them for a few prompts) show as native dialogs.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
}
