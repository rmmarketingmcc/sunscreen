import AppKit
import Carbon.HIToolbox
import CoreLocation

// MARK: - Global shortcut (Control-Option-Command-P)

/// Carbon hot keys work system-wide without the Accessibility permission.
enum HotKey {
    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.action?()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x53554E53), id: 1)  // 'SUNS'
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - One-shot location (only when the user asks for exact location)

final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((CLLocation) -> Void)?

    func fetch(_ completion: @escaping (CLLocation) -> Void) {
        self.completion = completion
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { manager.requestLocation() }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        if completion != nil, s != .notDetermined, s != .denied, s != .restricted { m.requestLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, let c = completion else { return }
        completion = nil
        DispatchQueue.main.async { c(l) }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Reporter.log("location failed: \(error.localizedDescription)")
    }
}

// MARK: - Updates (GitHub releases; publish with ./release.sh)

enum Updater {
    static let repo = "rmmarketingmcc/sunscreen"
    static let website = URL(string: "https://rmmarketingmcc.github.io/sunscreen/")!
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    struct Release { let version: String; let notes: [String]; let zipURL: URL }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Calls back on main with the latest release if it's newer than this app, else nil.
    static func check(_ completion: @escaping (Release?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var release: Release?
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String,
               let assets = json["assets"] as? [[String: Any]],
               let link = assets.first(where: { $0["name"] as? String == "Sunscreen.zip" })?["browser_download_url"] as? String,
               let url = URL(string: link) {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let notes = Changelog.bullets(json["body"] as? String ?? "")
                if isNewer(version, than: current) { release = Release(version: version, notes: notes, zipURL: url) }
            }
            DispatchQueue.main.async { completion(release) }
        }.resume()
    }

    /// Downloads the release, swaps it in for the running app and relaunches. Calls `failed` on main on error.
    static func install(_ r: Release, failed: @escaping (String) -> Void) {
        URLSession.shared.downloadTask(with: r.zipURL) { tmp, _, error in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("sunscreen-update-\(UUID().uuidString)")
            do {
                guard let tmp else { throw error ?? URLError(.badServerResponse) }
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("Sunscreen.zip")
                try fm.moveItem(at: tmp, to: zip)   // must happen before this handler returns
                try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                let newApp = work.appendingPathComponent("Sunscreen.app")
                try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
                let installed = URL(fileURLWithPath: Bundle.main.bundlePath)
                do { _ = try fm.replaceItemAt(installed, withItemAt: newApp) }
                catch { try fm.removeItem(at: installed); try fm.copyItem(at: newApp, to: installed) }
                DispatchQueue.main.async {
                    // Start the new copy once this one has quit.
                    let relaunch = Process()
                    relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                    // Waits for this copy's 1.2 s fade-out, otherwise `open` just finds the old one still running.
                    relaunch.arguments = ["-c", "sleep 3; /usr/bin/open \"$0\"", installed.path]
                    try? relaunch.run()
                    NSApp.terminate(nil)
                }
            } catch {
                Reporter.log("update failed: \(error.localizedDescription)")
                DispatchQueue.main.async { failed(error.localizedDescription) }
            }
        }.resume()
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "Sunscreen", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(path) exited \(p.terminationStatus)"])
        }
    }
}

// MARK: - Changelog (written by release.sh, bundled as Resources/changelog.json)

enum Changelog {
    struct Entry { let version: String; let date: String; let notes: [String] }

    static func load() -> [Entry] {
        guard let url = Bundle.main.url(forResource: "changelog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { e in
            guard let v = e["version"] as? String else { return nil }
            return Entry(version: v, date: e["date"] as? String ?? "", notes: e["notes"] as? [String] ?? [])
        }
    }

    /// Entries newer than `version`, newest first (at most `limit`).
    static func since(_ version: String, limit: Int = 2) -> [Entry] {
        Array(load().filter { Updater.isNewer($0.version, than: version) }.prefix(limit))
    }

    /// "- one\n- two" or plain text -> ["one", "two"]
    static func bullets(_ text: String) -> [String] {
        text.split(separator: "\n").map { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("- ") || s.hasPrefix("* ") { s.removeFirst(2) }
            return s
        }.filter { !$0.isEmpty }
    }
}

// MARK: - Problem reports (GitHub issues, pre-filled)

/// Something the user should know about, optionally with a one-click report.
struct Problem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    var reportable = true
    var extra: String?   // technical details for the report (crash summary, error)
}

enum Reporter {
    private static var lines: [String] = []
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Keeps the last 40 events for bug reports (and prints them to the system log).
    static func log(_ message: String) {
        NSLog("Sunscreen: %@", message)
        lines.append("\(clock.string(from: Date())) \(message)")
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
    }

    static var recent: [String] { lines }

    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    static var machine: String { "\(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string"))" }

    /// Summary of the newest Sunscreen crash report written after `since`, if any.
    static func crashSummary(since: Date) -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files
            .filter { $0.lastPathComponent.hasPrefix("Sunscreen") && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { url -> (URL, Date)? in
                guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d > since else { return nil }
                return (url, d)
            }
            .max { $0.1 < $1.1 }
        guard let url = newest?.0, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // .ips = one JSON header line, then the JSON report.
        let parts = text.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2,
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] else {
            return String(text.prefix(1500))
        }
        var out: [String] = []
        if let ex = body["exception"] as? [String: Any] {
            out.append("Exception: \(ex["type"] as? String ?? "?") \(ex["signal"] as? String ?? "")")
        }
        if let term = body["termination"] as? [String: Any], let why = term["indicator"] as? String { out.append("Termination: \(why)") }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        if let threads = body["threads"] as? [[String: Any]], let ft = body["faultingThread"] as? Int, ft < threads.count,
           let frames = threads[ft]["frames"] as? [[String: Any]] {
            for f in frames.prefix(14) {
                let image = (f["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
                out.append("  \(image)  \(f["symbol"] as? String ?? "?")")
            }
        }
        return out.isEmpty ? String(text.prefix(1500)) : out.joined(separator: "\n")
    }

    /// GitHub "new issue" page with title and body filled in; the user only presses Submit.
    static func issueURL(title: String, body: String) -> URL {
        var c = URLComponents(string: "https://github.com/\(Updater.repo)/issues/new")!
        c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: String(body.prefix(6000)))]
        return c.url ?? Updater.website
    }
}
