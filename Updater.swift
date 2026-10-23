// Self-update from GitHub. The app reads the latest release of a PUBLIC releases repo (zips only, no source),
// compares its version with the running app, downloads the zip, swaps the app bundle in place and relaunches.
// Downloads made by the app itself carry no quarantine flag, so the swapped-in app opens without Gatekeeper's
// "could not verify" warning. If anything fails, the running app is left untouched and the error is shown.

import AppKit
import Foundation

final class Updater {
    static let releasesRepo = "Foresite-Consulting/foresite-mind"
    static let latestURL = URL(string: "https://api.github.com/repos/\(releasesRepo)/releases/latest")!

    struct Release { let version: String; let zipURL: URL; let page: URL }

    /// Asks GitHub for the latest release; nil when there is none, the repo is missing, or we are offline.
    static func latest(_ done: @escaping (Release?) -> Void) {
        var req = URLRequest(url: latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, let assets = obj["assets"] as? [[String: Any]],
                  let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let urlString = zip["browser_download_url"] as? String, let url = URL(string: urlString),
                  let pageString = obj["html_url"] as? String, let page = URL(string: pageString) else {
                DispatchQueue.main.async { done(nil) }; return
            }
            // tags look like v1.2 or 1.2 or foresite-mind-1.2; keep the digits and dots
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            DispatchQueue.main.async { done(Release(version: version, zipURL: url, page: page)) }
        }.resume()
    }

    static func isNewer(_ version: String, than current: String) -> Bool {
        version.compare(current, options: .numeric) == .orderedDescending
    }

    /// Downloads the release, replaces this app bundle and relaunches. Reports progress and errors in plain words.
    static func install(_ release: Release, status: @escaping (String) -> Void, failed: @escaping (String) -> Void) {
        status("Downloading Foresite Mind \(release.version)…")
        URLSession.shared.downloadTask(with: release.zipURL) { tmp, _, error in
            guard let tmp = tmp else {
                DispatchQueue.main.async { failed(error?.localizedDescription ?? "The download didn't complete.") }; return
            }
            do {
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("foresite-mind-update-\(UUID().uuidString)")
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("Foresite-Mind.zip")
                try fm.moveItem(at: tmp, to: zip)
                DispatchQueue.main.async { status("Unpacking…") }
                try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "app" }) else { throw Failure("The download had no app inside it.") }
                try run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
                // Where to install. An app opened from Downloads (or still carrying its quarantine flag) runs from a
                // read-only "translocated" copy, so it cannot replace itself where it is: install into Applications instead.
                var current = Bundle.main.bundleURL
                var parent = current.deletingLastPathComponent()
                if current.path.contains("/AppTranslocation/") || !fm.isWritableFile(atPath: parent.path) {
                    let apps = fm.isWritableFile(atPath: "/Applications") ? URL(fileURLWithPath: "/Applications")
                        : fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
                    try? fm.createDirectory(at: apps, withIntermediateDirectories: true)
                    parent = apps
                    current = apps.appendingPathComponent("Foresite Mind.app")
                }
                let staged = parent.appendingPathComponent(".Foresite Mind.new.app")
                let retired = parent.appendingPathComponent(".Foresite Mind.old.app")
                try? fm.removeItem(at: staged); try? fm.removeItem(at: retired)
                DispatchQueue.main.async { status("Installing…") }
                try fm.copyItem(at: newApp, to: staged)        // copy into Applications first, so the swap itself is two renames
                try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path]) // so the new copy never gets translocated
                if fm.fileExists(atPath: current.path) { try fm.moveItem(at: current, to: retired) }
                do { try fm.moveItem(at: staged, to: current) } catch {
                    if fm.fileExists(atPath: retired.path) { try? fm.moveItem(at: retired, to: current) }  // put the old one back
                    throw error
                }
                try? fm.removeItem(at: retired)
                try? fm.removeItem(at: work)
                DispatchQueue.main.async {
                    status("Relaunching…")
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/bin/sh")
                    task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(current.path)\""]
                    try? task.run()
                    NSApp.terminate(nil)
                }
            } catch {
                DispatchQueue.main.async { failed((error as? Failure)?.message ?? error.localizedDescription) }
            }
        }.resume()
    }

    struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
