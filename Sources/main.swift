// Sunscreen: a menu bar app that makes your Mac's screens follow the sun.
// Day: full brightness, normal colours. Evening: no blue light on every
// screen, and a dimmer external monitor (DDC/CI, Apple Silicon).
// Gamma changes are undone by macOS the moment the app quits or crashes.
// Build: ./build.sh
import AppKit
import Carbon.HIToolbox
import CoreLocation
import IOKit
import ServiceManagement
import SwiftUI

// MARK: - Settings

enum Settings {
    static let defaults = UserDefaults.standard
    static let referenceKelvin = 6500.0   // neutral white: no filter
    static let dayBrightness = 100
    // Full day from 3 deg: at 55N in December the sun peaks near 11 deg, so a
    // higher threshold would leave Danish screens half-filtered all winter.
    static let fullDayElevation = 3.0
    static let fullNightElevation = -6.0  // end of civil twilight -> full evening

    static var nightKelvin: Double {
        get { defaults.object(forKey: "nightKelvin") != nil ? defaults.double(forKey: "nightKelvin") : 1900 }
        set { defaults.set(newValue, forKey: "nightKelvin") }
    }
    static var dayKelvin: Double {
        get { defaults.object(forKey: "dayKelvin") != nil ? defaults.double(forKey: "dayKelvin") : 6500 }
        set { defaults.set(newValue, forKey: "dayKelvin") }
    }
    static var nightBrightness: Int {
        get { defaults.object(forKey: "nightBrightness") != nil ? defaults.integer(forKey: "nightBrightness") : 30 }
        set { defaults.set(newValue, forKey: "nightBrightness") }
    }
    /// Survives relaunch and login. nil when not paused or the pause has run out.
    static var pausedUntil: Date? {
        get { (defaults.object(forKey: "pausedUntil") as? Date).flatMap { $0 > Date() ? $0 : nil } }
        set { defaults.set(newValue, forKey: "pausedUntil") }
    }
    /// Exact location (set by "Use exact location", or by hand:
    /// defaults write local.sunscreen lat -float 55.68; defaults write local.sunscreen lon -float 12.57).
    /// Without it, the Mac's time zone is used.
    static var coordinate: (lat: Double, lon: Double)? {
        get {
            guard defaults.object(forKey: "lat") != nil, defaults.object(forKey: "lon") != nil else { return nil }
            return (defaults.double(forKey: "lat"), defaults.double(forKey: "lon"))
        }
        set {
            defaults.set(newValue?.lat, forKey: "lat")
            defaults.set(newValue?.lon, forKey: "lon")
        }
    }
}

// MARK: - Sun

struct Place {
    let lat: Double
    let lon: Double
    let exact: Bool          // false = main city of the Mac's time zone
    let fallbackName: String
}

enum Sun {
    /// Solar elevation in degrees (low-precision almanac formula, ~0.1 deg).
    static func elevation(_ p: Place, at date: Date) -> Double {
        let n = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
        let rad = Double.pi / 180
        let meanLong = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360) * rad
        let eclLong = (meanLong + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        let obliq = (23.439 - 0.0000004 * n) * rad
        let ra = atan2(cos(obliq) * sin(eclLong), cos(eclLong))
        let dec = asin(sin(obliq) * sin(eclLong))
        let gmst = (280.46061837 + 360.98564736629 * n).truncatingRemainder(dividingBy: 360)
        let hourAngle = (gmst + p.lon) * rad - ra
        let lat = p.lat * rad
        return asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(hourAngle)) / rad
    }

    static func currentPlace() -> Place {
        if let c = Settings.coordinate { return Place(lat: c.lat, lon: c.lon, exact: true, fallbackName: "Your location") }
        let tz = TimeZone.current.identifier
        let city = (tz.split(separator: "/").last.map(String.init) ?? tz).replacingOccurrences(of: "_", with: " ")
        if let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) {
            for line in table.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                if parts.count >= 3, parts[2] == tz, let c = parseISO6709(String(parts[1])) {
                    return Place(lat: c.lat, lon: c.lon, exact: false, fallbackName: city)
                }
            }
        }
        return Place(lat: 55.68, lon: 12.57, exact: false, fallbackName: "Copenhagen")
    }

    /// zone.tab coordinates, e.g. "-0507+11924" or "+554521+0373704".
    static func parseISO6709(_ s: String) -> (lat: Double, lon: Double)? {
        let chars = Array(s)
        guard let split = chars.indices.dropFirst().first(where: { chars[$0] == "+" || chars[$0] == "-" }) else { return nil }
        func degrees(_ part: ArraySlice<Character>, _ degDigits: Int) -> Double? {
            let sign: Double = part.first == "-" ? -1 : 1
            let digits = Array(part.dropFirst())
            guard digits.count >= degDigits + 2,
                  let d = Double(String(digits[0..<degDigits])),
                  let m = Double(String(digits[degDigits..<degDigits + 2])) else { return nil }
            let sec = digits.count > degDigits + 2 ? Double(String(digits[(degDigits + 2)...])) ?? 0 : 0
            return sign * (d + m / 60 + sec / 3600)
        }
        guard let lat = degrees(chars[..<split], 2), let lon = degrees(chars[split...], 3) else { return nil }
        return (lat, lon)
    }

    /// Today's sunrise and sunset (sun centre at -0.833 deg), 2-minute resolution.
    static func todaysEvents(_ p: Place, on day: Date = Date()) -> (rise: Date?, set: Date?) {
        let start = Calendar.current.startOfDay(for: day)
        var rise: Date?, set: Date?
        var prev = elevation(p, at: start)
        for minute in stride(from: 2, through: 24 * 60, by: 2) {
            let t = start.addingTimeInterval(Double(minute) * 60)
            let e = elevation(p, at: t)
            if prev < -0.833 && e >= -0.833 { rise = t }
            if prev >= -0.833 && e < -0.833 { set = t }
            prev = e
        }
        return (rise, set)
    }

    /// When full daylight returns after the coming (or current) evening. nil in polar night/day.
    static func nextFullDay(_ p: Place, after date: Date) -> Date? {
        var seenEvening = elevation(p, at: date) < Settings.fullDayElevation
        for minute in stride(from: 2, through: 48 * 60, by: 2) {
            let t = date.addingTimeInterval(Double(minute) * 60)
            if elevation(p, at: t) < Settings.fullDayElevation { seenEvening = true }
            else if seenEvening { return t }
        }
        return nil
    }

    /// When the evening filter next starts fading in. nil if it's already on.
    static func nextEveningStart(_ p: Place, after date: Date) -> Date? {
        guard elevation(p, at: date) >= Settings.fullDayElevation else { return nil }
        for minute in stride(from: 2, through: 48 * 60, by: 2) {
            let t = date.addingTimeInterval(Double(minute) * 60)
            if elevation(p, at: t) < Settings.fullDayElevation { return t }
        }
        return nil
    }
}

// MARK: - Targets

struct Target {
    let fraction: Double   // 0 = full evening, 1 = full day
    let kelvin: Double
    let brightness: Int
    let rgb: (r: Double, g: Double, b: Double)

    init(fraction: Double) {
        self.fraction = fraction
        kelvin = Settings.nightKelvin + fraction * (Settings.dayKelvin - Settings.nightKelvin)
        brightness = Int((Double(Settings.nightBrightness)
            + fraction * Double(Settings.dayBrightness - Settings.nightBrightness)).rounded())
        rgb = Target.kelvinRGB(kelvin)
    }

    static func fraction(elevation: Double) -> Double {
        let span = Settings.fullDayElevation - Settings.fullNightElevation
        return min(max((elevation - Settings.fullNightElevation) / span, 0), 1)
    }

    /// Blackbody colour as 0-1 channel multipliers, normalised so referenceKelvin = 1,1,1.
    static func kelvinRGB(_ kelvin: Double) -> (r: Double, g: Double, b: Double) {
        func raw(_ k: Double) -> [Double] {
            let t = k / 100
            let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
            let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
            let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
            return [r, g, b].map { min(max($0, 0), 255) }
        }
        let ref = raw(Settings.referenceKelvin), c = raw(kelvin)
        return (min(c[0] / ref[0], 1), min(c[1] / ref[1], 1), min(c[2] / ref[2], 1))
    }

    /// How much blue light is left at this colour, 0-100.
    static func bluePercent(_ kelvin: Double) -> Int { Int((kelvinRGB(kelvin).b * 100).rounded()) }
}

// MARK: - Colour filter (gamma, all screens)

enum Gamma {
    private static var active = false

    static func apply(_ rgb: (r: Double, g: Double, b: Double)) {
        if rgb.r > 0.999 && rgb.g > 0.999 && rgb.b > 0.999 {
            if active { restore() }
            return
        }
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids {
            CGSetDisplayTransferByFormula(id, 0, CGGammaValue(rgb.r), 1, 0, CGGammaValue(rgb.g), 1,
                                          0, CGGammaValue(rgb.b), 1)
        }
        active = true
    }

    static func restore() {
        CGDisplayRestoreColorSyncSettings()
        active = false
    }
}

// MARK: - External monitor brightness (DDC/CI over IOAVService, Apple Silicon)

enum DDC {
    // Private IOKit functions (same ones MonitorControl/m1ddc use), looked up at
    // runtime so the app still launches where they don't exist (Intel).
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let create = dlsym(iokit, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
    private static let write = dlsym(iokit, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: WriteFn.self) }

    private static func externalServices() -> [CFTypeRef] {
        guard let create = create else { return [] }
        var iter = io_iterator_t()
        guard IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        let name = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { name.deallocate() }
        var services: [CFTypeRef] = []
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, name) == KERN_SUCCESS,
                  String(cString: name) == "DCPAVServiceProxy" else { continue }
            let location = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "Location" as CFString,
                                                           kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) as? String
            if location == "External", let svc = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                services.append(svc)
            }
        }
        return services
    }

    /// Sets brightness (0-100) on every external monitor. Returns how many accepted it.
    static func setBrightness(_ value: Int) -> Int {
        guard let write = write else { return 0 }
        var accepted = 0
        for svc in externalServices() {
            // VCP 0x10 (luminance) set command; checksum includes the host address 0x6E and 0x51.
            var packet: [UInt8] = [0x84, 0x03, 0x10, 0x00, UInt8(clamping: value), 0]
            packet[5] = 0x6E ^ 0x51 ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3] ^ packet[4]
            var ok = false
            for _ in 0..<2 {
                usleep(10_000)
                let r = packet.withUnsafeMutableBytes { write(svc, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
                if r == KERN_SUCCESS { ok = true }
            }
            if ok { accepted += 1 }
        }
        return accepted
    }
}

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
        NSLog("Sunscreen: location failed: \(error)")
    }
}

// MARK: - Updates (GitHub releases; publish with ./release.sh)

enum Updater {
    static let repo = "rmmarketingmcc/sunscreen"
    static let website = URL(string: "https://rmmarketingmcc.github.io/sunscreen/")!
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    struct Release { let version: String; let notes: String; let zipURL: URL }

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
                let notes = (json["body"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
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
                    // Start the new copy once this one has quit (quitting restores colours for a moment).
                    let relaunch = Process()
                    relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                    relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", installed.path]
                    try? relaunch.run()
                    NSApp.terminate(nil)
                }
            } catch {
                NSLog("Sunscreen: update failed: \(error)")
                DispatchQueue.main.async { failed("Couldn't update automatically") }
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

// MARK: - App

final class Store: ObservableObject {
    func refresh() { objectWillChange.send() }
}

struct Snapshot {
    enum Mode { case day, evening, fading, paused, preview }
    let mode: Mode
    let now: Date
    let placeName: String
    let exactLocation: Bool
    let target: Target
    let sunrise: Date?
    let sunset: Date?
    let filterOn: Date?    // next time the filter starts (nil if on now)
    let filterOff: Date?   // next time it's fully off again (nil if off now)
    let pausedUntil: Date?
    let timeline: [Double] // day fraction for today, every 15 min
    let position: Double   // now, 0-1 through today
    let monitorsFound: Int?
}

final class App: NSObject, NSApplicationDelegate {
    let store = Store()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let ddcQueue = DispatchQueue(label: "sunscreen.ddc")
    private let locationFetcher = LocationFetcher()
    private var place = Sun.currentPlace()
    private var placeName = ""
    private var previewUntil: Date?
    private var lastBrightness: Int?     // last value the monitor accepted
    private var ddcBusy = false
    private var nextDDCAttempt = Date.distantPast
    private var monitorsFound: Int?
    private(set) var update: Updater.Release?
    private(set) var updateStatus: String?   // "Updating...", "Up to date", or an error
    private var lastUpdateCheck = Date.distantPast
    private var iconKey = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        resolvePlaceName()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            // Optional hour (e.g. 14) renders the panel as it looks at that time today.
            if i + 2 < args.count, let hour = Double(args[i + 2]) {
                let target = Calendar.current.startOfDay(for: Date()).addingTimeInterval(hour * 3600)
                clockOffset = target.timeIntervalSince(Date())
            }
            Task { @MainActor in self.renderSnapshot(to: path); exit(0) }
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let host = NSHostingController(rootView: PanelView(app: self, store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(timeZoneChanged), name: .NSSystemTimeZoneDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        if !Settings.defaults.bool(forKey: "loginItemConfigured") {
            setStartAtLogin(true)
            Settings.defaults.set(true, forKey: "loginItemConfigured")
        }
        HotKey.register { [weak self] in self?.togglePause() }
        tick()
        Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.checkForUpdates() }
        Timer.scheduledTimer(timeInterval: 6 * 3600, target: self, selector: #selector(periodicUpdateCheck), userInfo: nil, repeats: true)
    }

    func applicationWillTerminate(_ notification: Notification) { Gamma.restore() }

    /// sunscreen://show, pause[?minutes=N], pause-tonight, resume, toggle
    /// (for Shortcuts, Raycast, Stream Deck, etc.)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "sunscreen" {
            let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "minutes" }?.value.flatMap(Double.init)
            switch url.host {
            case "show": DispatchQueue.main.async { if !self.popover.isShown { self.togglePanel() } }
            case "pause": pause(minutes: minutes ?? 60)
            case "pause-tonight": pauseTonight()
            case "resume": resume()
            case "toggle": togglePause()
            case "check": checkForUpdates(manual: true)
            case "update": checkForUpdates(manual: true, thenInstall: true)
            default: NSLog("Sunscreen: unknown URL \(url)")
            }
        }
    }

    @objc private func screensChanged() { lastBrightness = nil; nextDDCAttempt = .distantPast }
    @objc private func timeZoneChanged() { place = Sun.currentPlace(); resolvePlaceName() }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        if Date().timeIntervalSince(lastUpdateCheck) > 3600 { checkForUpdates() }
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var clockOffset: TimeInterval = 0   // only for --snapshot at a given hour
    private var now: Date { Date().addingTimeInterval(clockOffset) }

    private func naturalFraction() -> Double { Target.fraction(elevation: Sun.elevation(place, at: now)) }

    private func currentTarget() -> Target {
        if let p = previewUntil, p > Date() { return Target(fraction: 0) }
        if Settings.pausedUntil != nil { return Target(fraction: 1) }
        return Target(fraction: naturalFraction())
    }

    // Runs every 2 s: macOS resets gamma on wake/replug, so it is re-applied each tick.
    // The monitor is only written when its target changes, so manual changes stick until the next ramp.
    @objc private func tick() {
        let t = currentTarget()
        Gamma.apply(t.rgb)
        let symbol = Settings.pausedUntil != nil ? "pause.circle" : (t.fraction < 0.5 ? "moon.stars" : "sun.max")
        let key = symbol + (update != nil ? "+dot" : "")
        if key != iconKey, let button = statusItem?.button {
            iconKey = key
            button.image = menuBarIcon(symbol, dot: update != nil)
        }
        if popover.isShown { store.refresh() }

        guard t.brightness != lastBrightness, !ddcBusy, Date() >= nextDDCAttempt else { return }
        ddcBusy = true
        let value = t.brightness
        ddcQueue.async {
            let accepted = DDC.setBrightness(value)
            DispatchQueue.main.async {
                self.ddcBusy = false
                self.monitorsFound = accepted
                if accepted > 0 { self.lastBrightness = value }
                else { self.nextDDCAttempt = Date().addingTimeInterval(60) }  // none attached, check again later
            }
        }
    }

    /// Menu bar symbol, with a small dot in the corner when an update is waiting.
    private func menuBarIcon(_ symbol: String, dot: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sunscreen") else { return nil }
        guard dot else { return base }
        let size = NSSize(width: base.size.width + 4, height: base.size.height + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Updates

    @objc private func periodicUpdateCheck() { checkForUpdates() }

    func checkForUpdates(manual: Bool = false, thenInstall: Bool = false) {
        lastUpdateCheck = Date()
        Updater.check { [weak self] release in
            guard let self else { return }
            self.update = release
            if release == nil, manual { self.flash("Up to date") }
            if release != nil, thenInstall { self.installUpdate() }
            self.tick()
            self.store.refresh()
        }
    }

    func installUpdate() {
        guard let release = update, updateStatus != "Updating..." else { return }
        updateStatus = "Updating..."
        store.refresh()
        Updater.install(release) { [weak self] message in
            self?.updateStatus = message
            self?.store.refresh()
        }
    }

    func openWebsite() { NSWorkspace.shared.open(Updater.website) }

    private func flash(_ text: String) {
        updateStatus = text
        store.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.updateStatus == text else { return }
            self.updateStatus = nil
            self.store.refresh()
        }
    }

    // MARK: Actions (used by the panel, hotkey and URLs)

    func pause(minutes: Double) { Settings.pausedUntil = Date().addingTimeInterval(minutes * 60); previewUntil = nil; tick() }
    func pauseTonight() {
        Settings.pausedUntil = Sun.nextFullDay(place, after: Date()) ?? Date().addingTimeInterval(12 * 3600)
        previewUntil = nil
        tick()
    }
    func resume() { Settings.pausedUntil = nil; tick() }
    func togglePause() { Settings.pausedUntil == nil ? pause(minutes: 60) : resume() }
    func preview(seconds: Double = 10) { previewUntil = Date().addingTimeInterval(seconds); tick() }

    func setNightKelvin(_ k: Double) {
        Settings.nightKelvin = k
        if naturalFraction() > 0 || Settings.pausedUntil != nil { preview(seconds: 5) } else { tick() }
    }
    func setDayKelvin(_ k: Double) { Settings.dayKelvin = k; tick() }
    func setNightBrightness(_ b: Int) {
        Settings.nightBrightness = b
        if naturalFraction() > 0 || Settings.pausedUntil != nil { preview(seconds: 5) } else { tick() }
    }

    func useExactLocation() {
        locationFetcher.fetch { [weak self] loc in
            guard let self else { return }
            Settings.coordinate = (loc.coordinate.latitude, loc.coordinate.longitude)
            self.place = Sun.currentPlace()
            self.resolvePlaceName()
            self.tick()
        }
    }

    private func resolvePlaceName() {
        let key = String(format: "%.2f,%.2f", place.lat, place.lon)
        if Settings.defaults.string(forKey: "placeNameKey") == key, let cached = Settings.defaults.string(forKey: "placeName") {
            placeName = cached
            return
        }
        placeName = place.fallbackName
        let exact = place.exact, fallback = place.fallbackName
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: place.lat, longitude: place.lon),
                                            preferredLocale: Locale(identifier: "en_US")) { [weak self] marks, _ in
            guard let m = marks?.first else { return }
            // subAdministrativeArea/administrativeArea read best: "Bali", "Copenhagen" (locality gives
            // "Kabupaten Badung", "København K"). Time-zone places keep the zone's city name.
            let area = exact ? (m.subAdministrativeArea ?? m.administrativeArea ?? m.locality) : fallback
            let name = [area, m.country].compactMap { $0 }.joined(separator: ", ")
            guard !name.isEmpty else { return }
            DispatchQueue.main.async {
                self?.placeName = name
                Settings.defaults.set(name, forKey: "placeName")
                Settings.defaults.set(key, forKey: "placeNameKey")
                self?.store.refresh()
            }
        }
    }

    func makeSnapshot() -> Snapshot {
        let now = self.now
        let natural = naturalFraction()
        let mode: Snapshot.Mode
        if let p = previewUntil, p > now { mode = .preview }
        else if Settings.pausedUntil != nil { mode = .paused }
        else if natural >= 1 { mode = .day }
        else if natural <= 0 { mode = .evening }
        else { mode = .fading }
        let events = Sun.todaysEvents(place, on: now)
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let timeline = (0...96).map { i in
            Target.fraction(elevation: Sun.elevation(place, at: start.addingTimeInterval(end.timeIntervalSince(start) * Double(i) / 96)))
        }
        return Snapshot(mode: mode, now: now, placeName: placeName, exactLocation: place.exact,
                        target: currentTarget(), sunrise: events.rise, sunset: events.set,
                        filterOn: Sun.nextEveningStart(place, after: now),
                        filterOff: natural < 1 ? Sun.nextFullDay(place, after: now) : nil,
                        pausedUntil: Settings.pausedUntil, timeline: timeline,
                        position: now.timeIntervalSince(start) / end.timeIntervalSince(start),
                        monitorsFound: monitorsFound)
    }

    /// Renders the panel to a PNG without touching any screen: Sunscreen --snapshot out.png
    @MainActor private func renderSnapshot(to path: String) {
        let view = PanelView(app: self, store: store)
            .background(Color(red: 0.13, green: 0.13, blue: 0.15))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Login item

    var startsAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setStartAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Sunscreen: login item change failed: \(error)")
        }
        store.refresh()
    }
}

// MARK: - Panel UI

enum Palette {
    static let amber = (r: 1.0, g: 0.56, b: 0.22)
    static let sky = (r: 0.46, g: 0.72, b: 1.0)
    static let warm = LinearGradient(colors: [Color(red: 1.0, green: 0.68, blue: 0.30), Color(red: 0.96, green: 0.42, blue: 0.24)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
    static let day = LinearGradient(colors: [Color(red: 0.55, green: 0.80, blue: 1.0), Color(red: 0.32, green: 0.56, blue: 0.98)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
    static let pause = LinearGradient(colors: [Color(white: 0.55), Color(white: 0.38)], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Timeline colour: amber where the filter is on, sky blue where colours are normal.
    static func mix(_ f: Double) -> Color {
        Color(red: amber.r + (sky.r - amber.r) * f, green: amber.g + (sky.g - amber.g) * f, blue: amber.b + (sky.b - amber.b) * f)
    }
}

enum Fmt {
    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    static func time(_ d: Date?) -> String { d.map(hm.string) ?? "-" }

    /// "06.10" or "tomorrow 06.10"
    static func when(_ d: Date, from now: Date) -> String {
        Calendar.current.isDate(d, inSameDayAs: now) ? time(d) : "tomorrow \(time(d))"
    }

    /// "at 06.10" or "tomorrow at 06.10"
    static func at(_ d: Date, from now: Date) -> String {
        Calendar.current.isDate(d, inSameDayAs: now) ? "at \(time(d))" : "tomorrow at \(time(d))"
    }

    static func until(_ d: Date, from now: Date) -> String {
        let mins = max(0, Int(d.timeIntervalSince(now) / 60))
        if mins < 60 { return "\(mins) min" }
        return mins % 60 == 0 ? "\(mins / 60) h" : "\(mins / 60) h \(mins % 60) min"
    }
}

struct PanelView: View {
    let app: App
    @ObservedObject var store: Store

    var body: some View {
        let s = app.makeSnapshot()
        VStack(spacing: 10) {
            HeaderView(s: s, app: app)
            if app.update != nil || (app.updateStatus ?? "").hasPrefix("Couldn't") { UpdateCard(app: app) }
            TodayCard(s: s)
            EveningCard(s: s, app: app)
            DaytimeCard(app: app)
            PauseCard(s: s, app: app)
            FooterView(app: app)
        }
        .padding(14)
        .frame(width: 340)
        .fontDesign(.rounded)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct CardTitle: View {
    let title: String
    var trailing: String = ""
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(trailing).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

struct Chip: View {
    let title: String
    var detail: String = ""
    let selected: Bool
    var recommended = false
    var style = Palette.warm
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if recommended { Image(systemName: "star.fill").font(.system(size: 7, weight: .bold)) }
                }
                if !detail.isEmpty { Text(detail).font(.system(size: 10)).opacity(0.75) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? AnyShapeStyle(style) : AnyShapeStyle(Color.primary.opacity(0.07))))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Drawn by hand (not NSSlider) so it matches the panel and renders in --snapshot images.
struct SoftSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        GeometryReader { g in
            let knob: CGFloat = 16
            let span = range.upperBound - range.lowerBound
            let x = (g.size.width - knob) * CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 5)
                Capsule().fill(Palette.warm).frame(width: x + knob / 2, height: 5)
                Circle().fill(.white).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = min(max((drag.location.x - knob / 2) / (g.size.width - knob), 0), 1)
                let stepped = ((range.lowerBound + Double(f) * span) / step).rounded() * step
                if stepped != value { value = stepped }
            })
        }
        .frame(height: 18)
    }
}

struct SoftSwitch: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? AnyShapeStyle(Palette.warm) : AnyShapeStyle(Color.primary.opacity(0.18)))
                    .frame(width: 30, height: 18)
                Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

struct HeaderView: View {
    let s: Snapshot
    let app: App

    private var icon: (String, LinearGradient) {
        switch s.mode {
        case .day: return ("sun.max.fill", Palette.day)
        case .paused: return ("pause.fill", Palette.pause)
        default: return ("moon.stars.fill", Palette.warm)
        }
    }
    private var title: String {
        switch s.mode {
        case .day: return "Daytime"
        case .evening: return "Evening mode"
        case .fading: return s.position > 0.5 ? "Sunset" : "Sunrise"
        case .paused: return "Paused"
        case .preview: return "Preview"
        }
    }
    private var subtitle: String {
        switch s.mode {
        case .day: return "Normal colours"
        case .evening: return "Blue light filtered"
        case .fading: return s.position > 0.5 ? "Filter fading in" : "Filter fading out"
        case .paused: return "Normal colours for now"
        case .preview: return "Showing the evening look"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    Circle().fill(icon.1).frame(width: 40, height: 40)
                    Image(systemName: icon.0).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.time(s.now)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    Text(TimeZone.current.abbreviation() ?? "").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: s.exactLocation ? "location.fill" : "globe").font(.system(size: 9))
                Text(s.placeName + (s.exactLocation ? "" : " (from time zone)")).lineLimit(1)
                Spacer()
                if !s.exactLocation {
                    Button("Use exact location") { app.useExactLocation() }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}

struct TodayCard: View {
    let s: Snapshot

    private var nextLine: (String, String) {
        if s.mode == .paused, let p = s.pausedUntil {
            return ("pause.circle", "Back on \(Fmt.at(p, from: s.now)) · in \(Fmt.until(p, from: s.now))")
        }
        if let on = s.filterOn {
            return ("moon.stars", "Filter turns on \(Fmt.at(on, from: s.now)) · in \(Fmt.until(on, from: s.now))")
        }
        if let off = s.filterOff {
            return ("sun.max", "Filter on now · normal again \(Fmt.at(off, from: s.now))")
        }
        return ("circle", "No sunrise or sunset here today")
    }

    var body: some View {
        Card {
            CardTitle(title: "Today")
            VStack(spacing: 4) {
                GeometryReader { g in
                    let stops = s.timeline.enumerated().map { i, f in
                        Gradient.Stop(color: Palette.mix(f), location: Double(i) / Double(max(s.timeline.count - 1, 1)))
                    }
                    ZStack(alignment: .leading) {
                        Capsule().fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                        Circle().fill(.white).frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                            .offset(x: min(max(g.size.width * s.position - 7, 0), g.size.width - 14))
                    }
                }
                .frame(height: 14)
                HStack {
                    ForEach(["00", "06", "12", "18", "24"], id: \.self) { h in
                        Text(h)
                        if h != "24" { Spacer() }
                    }
                }
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 14) {
                Label(Fmt.time(s.sunrise), systemImage: "sunrise.fill")
                Label(Fmt.time(s.sunset), systemImage: "sunset.fill")
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            Label(nextLine.1, systemImage: nextLine.0)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

struct EveningCard: View {
    let s: Snapshot
    let app: App

    private var advice: String {
        let k = Settings.nightKelvin
        if k <= 2000 { return "Best for sleep: no blue light, like anti-blue-light glasses. Recommended for the last 2-3 hours before bed." }
        if k <= 2500 { return "Very warm. Almost no blue light left." }
        if k <= 3000 { return "About as warm as Night Shift at its strongest. Some blue light left." }
        return "Mild. Colours stay natural, but a fair amount of blue light gets through."
    }

    var body: some View {
        let k = Settings.nightKelvin
        Card {
            HStack {
                Text("Evening").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Blue light \(Target.bluePercent(k))%").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Button { app.preview() } label: { Image(systemName: "eye") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Preview the evening look for 10 seconds")
            }
            HStack(spacing: 6) {
                Chip(title: "Sleep", detail: "No blue", selected: k == 1900, recommended: true) { app.setNightKelvin(1900) }
                Chip(title: "Warm", detail: "Night Shift", selected: k == 2700) { app.setNightKelvin(2700) }
                Chip(title: "Mild", detail: "Some blue", selected: k == 3400) { app.setNightKelvin(3400) }
            }
            HStack(spacing: 8) {
                Image(systemName: "flame").font(.system(size: 11)).foregroundStyle(.secondary)
                SoftSlider(value: Binding(get: { Settings.nightKelvin }, set: { app.setNightKelvin($0) }),
                           range: 1200...4500, step: 100)
                Text(verbatim: "\(Int(k))K").font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 42, alignment: .trailing)
            }
            Text(advice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if s.monitorsFound != 0 {
                HStack(spacing: 8) {
                    Image(systemName: "display").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Monitor").font(.system(size: 12))
                    SoftSlider(value: Binding(get: { Double(Settings.nightBrightness) },
                                              set: { app.setNightBrightness(Int($0)) }),
                               range: 0...100, step: 5)
                    Text(verbatim: "\(Settings.nightBrightness)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
    }
}

struct DaytimeCard: View {
    let app: App

    var body: some View {
        let k = Settings.dayKelvin
        Card {
            CardTitle(title: "Daytime", trailing: "Blue light \(Target.bluePercent(k))%")
            HStack(spacing: 6) {
                Chip(title: "Daylight", selected: k == 6500, recommended: true, style: Palette.day) { app.setDayKelvin(6500) }
                Chip(title: "Soft", selected: k == 5500, style: Palette.day) { app.setDayKelvin(5500) }
                Chip(title: "Warm", selected: k == 4500, style: Palette.day) { app.setDayKelvin(4500) }
            }
            Text(k >= 6500
                 ? "Recommended: blue light by day keeps you alert and helps you fall asleep at night."
                 : "A light filter all day. Daylight is better for your sleep rhythm.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PauseCard: View {
    let s: Snapshot
    let app: App

    var body: some View {
        Card {
            CardTitle(title: "Take a break", trailing: "⌃⌥⌘P")
            if let p = s.pausedUntil {
                Button { app.resume() } label: {
                    Label("Turn back on now", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.warm))
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Paused until \(Fmt.when(p, from: s.now))").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Chip(title: "15 min", selected: false) { app.pause(minutes: 15) }
                    Chip(title: "1 hour", selected: false) { app.pause(minutes: 60) }
                    Chip(title: "Tonight", selected: false) { app.pauseTonight() }
                }
            }
        }
    }
}

struct UpdateCard: View {
    let app: App

    var body: some View {
        let failed = (app.updateStatus ?? "").hasPrefix("Couldn't")
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(Palette.warm).frame(width: 32, height: 32)
                Image(systemName: failed ? "exclamationmark" : "arrow.down").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(failed ? "Update didn't install" : "Update available").font(.system(size: 13, weight: .semibold))
                Text(failed ? "Download it from the website instead."
                            : "Version \(app.update?.version ?? "")" + ((app.update?.notes ?? "").isEmpty ? "" : " · \(app.update!.notes)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if app.updateStatus == "Updating..." {
                Text("Updating...").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            } else {
                Button { failed ? app.openWebsite() : app.installUpdate() } label: {
                    Text(failed ? "Website" : "Update").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Palette.warm)).foregroundStyle(.white)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.14)))
    }
}

struct FooterView: View {
    let app: App

    var body: some View {
        HStack(spacing: 7) {
            SoftSwitch(isOn: app.startsAtLogin) { app.setStartAtLogin(!app.startsAtLogin) }
            Text("Start at login")
            Spacer()
            Button { app.checkForUpdates(manual: true) } label: {
                Text(verbatim: app.updateStatus == "Up to date" ? "Up to date" : "v\(Updater.current)")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Check for updates")
            Text("·").foregroundStyle(.tertiary)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4)
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--status") {
    // Diagnostics without UI: Sunscreen.app/Contents/MacOS/Sunscreen --status
    let place = Sun.currentPlace()
    let elevation = Sun.elevation(place, at: Date())
    let t = Target(fraction: Target.fraction(elevation: elevation))
    let events = Sun.todaysEvents(place)
    print("place: \(place.fallbackName) exact=\(place.exact) lat=\(place.lat) lon=\(place.lon), sun elevation \(String(format: "%.1f", elevation))")
    print("sunrise \(events.rise.map { "\($0)" } ?? "-"), sunset \(events.set.map { "\($0)" } ?? "-")")
    print("target: \(Int(t.kelvin))K rgb=(\(t.rgb.r), \(t.rgb.g), \(t.rgb.b)) monitor \(t.brightness)%")
    print("paused until: \(Settings.pausedUntil.map { "\($0)" } ?? "not paused")")
    print("filter on next: \(Sun.nextEveningStart(place, after: Date()).map { "\($0)" } ?? "now"), off next: \(Sun.nextFullDay(place, after: Date()).map { "\($0)" } ?? "-")")
    print("login item status: \(SMAppService.mainApp.status.rawValue) (1 = enabled)")
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
