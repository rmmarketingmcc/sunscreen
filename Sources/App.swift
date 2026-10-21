import AppKit
import CoreLocation
import ServiceManagement
import SwiftUI

final class Store: ObservableObject {
    func refresh() { objectWillChange.send() }
}

struct ScreenRow: Identifiable {
    let id: CGDirectDisplayID
    let key: String
    let name: String
    let symbol: String
    let note: String
    let value: Int
    let isBuiltin: Bool
    let overlay: Bool
}

struct Snapshot {
    enum Mode { case day, evening, fading, paused, preview, appPause }
    let mode: Mode
    let now: Date
    let placeName: String
    let exactLocation: Bool
    let kelvin: Double
    let sunrise: Date?
    let sunset: Date?
    let filterOn: Date?    // next time the filter starts (nil if on now)
    let filterOff: Date?   // next time it's fully off again (nil if off now)
    let pausedUntil: Date?
    let appPause: String?  // colour-critical app in front
    let timeline: [Double] // day fraction for today, every 15 min
    let position: Double   // now, 0-1 through today
    let rows: [ScreenRow]
    let editingEvening: Bool
    let problem: Problem?
}

final class App: NSObject, NSApplicationDelegate {
    private struct Hardware {
        var written: Int?    // last brightness % sent to (or confirmed on) the monitor
        var read: Int?       // brightness % read from the monitor
        var max = 100        // the monitor's own scale
        var failures = 0
        var firstReadDone = false
    }

    /// Apps where colours matter: Sunscreen shows normal colours while one is in front (optional).
    static let creativeApps = [
        "com.adobe.Photoshop", "com.adobe.LightroomClassicCC7", "com.adobe.lightroomCC", "com.adobe.Lightroom",
        "com.adobe.PremierePro", "com.adobe.AfterEffects", "com.adobe.illustrator", "com.adobe.InDesign",
        "com.apple.FinalCut", "com.apple.motionapp", "com.blackmagic-design.DaVinciResolve", "com.seriflabs.",
        "com.captureone.", "com.phaseone.captureone", "com.pixelmatorteam.", "com.bohemiancoding.sketch3",
        "com.figma.Desktop", "org.darktable", "org.gimp.gimp",
    ]
    /// Other apps that write gamma curves and fight with Sunscreen when both run.
    static let colourApps: Set<String> = [
        "flux", "f.lux", "lunar", "betterdisplay", "monitorcontrol", "iris", "iris mini", "gamma dimmer",
        "black light", "shades", "quickshade", "luma", "night owl", "displaybuddy",
    ]

    let store = Store()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let filter = ColourFilter()
    private let overlays = Overlays()
    private let ddcQueue = DispatchQueue(label: "sunscreen.ddc")
    private let locationFetcher = LocationFetcher()
    private var place = Sun.currentPlace()
    private var placeName = ""
    private var previewUntil: Date?
    private var clockOffset: TimeInterval = 0   // only for --snapshot at a given hour
    private var now: Date { Date().addingTimeInterval(clockOffset) }

    private var screens: [Screen] = []
    private var ddcRefs: [CGDirectDisplayID: CFTypeRef] = [:]
    private var ddcBroken: Set<String> = []
    private var ddcWorked: Set<String> = []
    private var hardware: [String: Hardware] = [:]
    private var ddcBusy = false
    private var ddcHoldUntil = Date.distantPast
    private var wasFullDay: Bool?
    private var rescanPending = false

    private var shown = 1.0                 // day fraction currently on screen (1 = normal colours)
    private var fadeTimer: Timer?
    private var fadeFrom = 1.0, fadeTo = 1.0
    private var fadeStart = Date()

    private var frontAppPause: String?

    private(set) var update: Updater.Release?
    private(set) var updateStatus: String?   // "Updating...", "Up to date"
    private var lastUpdateCheck = Date.distantPast
    private(set) var problems: [Problem] = []
    private var iconKey = ""

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        resolvePlaceName()
        rescanScreens()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            // Optional hour (e.g. 14) renders the panel as it looks at that time today.
            if i + 2 < args.count, let hour = Double(args[i + 2]) {
                clockOffset = Calendar.current.startOfDay(for: Date()).addingTimeInterval(hour * 3600).timeIntervalSince(Date())
            }
            Task { @MainActor in self.renderSnapshot(to: path); exit(0) }
            return
        }
        Reporter.log("Sunscreen \(Updater.current) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(Reporter.machine)")
        checkPreviousCrash()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePanel)
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let host = NSHostingController(rootView: PanelView(app: self, store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        filter.onConflict = { [weak self] in self?.colourConflict() }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(timeZoneChanged), name: .NSSystemTimeZoneDidChange, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(frontAppChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if !Settings.defaults.bool(forKey: "loginItemConfigured") {
            setStartAtLogin(true)
            Settings.defaults.set(true, forKey: "loginItemConfigured")
        }
        HotKey.register { [weak self] in self?.togglePause() }
        frontAppChanged()
        Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.checkForUpdates() }
        Timer.scheduledTimer(timeInterval: 6 * 3600, target: self, selector: #selector(periodicUpdateCheck), userInfo: nil, repeats: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        fadeTimer?.invalidate()
        filter.restoreAll()
        overlays.removeAll()
    }

    /// sunscreen://show, pause[?minutes=N], pause-tonight, resume, toggle, check, update, report
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
            case "preview": preview()
            case "check": checkForUpdates(manual: true)
            case "update": checkForUpdates(manual: true, thenInstall: true)
            case "report": report(nil)
            case "report-log": Reporter.log("report preview:\n" + diagnostics(problems.first))   // for testing
            default: Reporter.log("unknown URL \(url)")
            }
        }
    }

    @objc private func screensChanged() {
        guard !rescanPending else { return }
        rescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.rescanPending = false
            self.rescanScreens()
            self.tick()
        }
    }

    @objc private func didWake() {
        // Monitors need a moment after wake before they accept DDC again.
        ddcHoldUntil = Date().addingTimeInterval(5)
        screensChanged()
    }

    @objc private func timeZoneChanged() {
        place = Sun.currentPlace()
        resolvePlaceName()
        tick()
    }

    @objc private func frontAppChanged() {
        let front = NSWorkspace.shared.frontmostApplication
        let id = front?.bundleIdentifier ?? ""
        guard id != Bundle.main.bundleIdentifier else { return }   // opening our own panel
        let creative = Settings.pauseInCreativeApps && App.creativeApps.contains { id.hasPrefix($0) }
        let name = creative ? (front?.localizedName ?? "this app") : nil
        if name != frontAppPause {
            frontAppPause = name
            if let name { Reporter.log("normal colours while \(name) is in front") }
        }
        tick()
    }

    // MARK: Screens

    private func rescanScreens() {
        let ids = Screens.onlineIDs()
        ddcRefs = DDC.match(ids.filter { CGDisplayIsBuiltin($0) == 0 }, DDC.services())
        let overlayKeys = Settings.overlayScreens
        let previous = screens
        screens = ids.map { id in
            let key = Screens.key(for: id)
            let name = Screens.name(for: id)
            let builtin = CGDisplayIsBuiltin(id) != 0
            let control: Screen.Control = builtin
                ? (BuiltinBrightness.available ? .builtin : .software)
                : (ddcRefs[id] != nil && !ddcBroken.contains(key) ? .hardware : .software)
            let overlay = !builtin && (overlayKeys.contains(key) || filter.rejected.contains(id) || Screens.looksStreamed(name))
            return Screen(id: id, key: key, name: name, isBuiltin: builtin, control: control, overlay: overlay)
        }
        if screens != previous {
            Reporter.log("screens: " + screens.map { "\($0.name) [\($0.key)] \($0.control)\($0.overlay ? " overlay" : "")" }
                .joined(separator: "; "))
        }
        for s in screens where s.control == .hardware && hardware[s.key]?.firstReadDone != true {
            readHardware(s, first: true)
        }
        store.refresh()
    }

    /// Reads the monitor's brightness.
    /// First read after launch/connect in daylight: the monitor's current level is the user's daytime
    /// choice and is kept as is, unless it's still sitting at last evening's level (Mac was shut down
    /// in the evening), then the remembered daytime level is restored.
    /// `adoptAsDay` (sunset starting): a level the user set on the monitor itself today becomes the daytime value.
    private func readHardware(_ s: Screen, first: Bool = false, adoptAsDay: Bool = false) {
        guard let ref = ddcRefs[s.id] else { return }
        ddcQueue.async {
            let value = DDC.readBrightness(ref)
            DispatchQueue.main.async {
                var hw = self.hardware[s.key] ?? Hardware()
                if first { hw.firstReadDone = true }
                guard let value else {
                    self.hardware[s.key] = hw
                    Reporter.log("\(s.name): brightness can't be read (setting it may still work)")
                    self.driveHardware()
                    return
                }
                hw.max = value.max
                let percent = Int((Double(value.current) * 100 / Double(value.max)).rounded())
                hw.read = percent
                Reporter.log("\(s.name): brightness reads \(percent)% (scale 0-\(value.max))")
                if first && self.brightnessFraction() >= 1 {
                    let evening = Settings.rememberedBrightness(s.key, evening: true) ?? Settings.nightBrightness
                    let day = Settings.rememberedBrightness(s.key, evening: false)
                    if let day, day != evening, abs(percent - evening) <= 2 {
                        Reporter.log("\(s.name): still at the evening level, restoring daytime \(day)%")
                        hw.written = nil
                    } else {
                        Settings.remember(percent, for: s.key, evening: false)
                        hw.written = percent
                    }
                } else if adoptAsDay {
                    Settings.remember(percent, for: s.key, evening: false)
                }
                self.hardware[s.key] = hw
                self.store.refresh()
                self.driveHardware()
            }
        }
    }

    private func brightnessTarget(_ s: Screen, _ f: Double) -> Int {
        let day = Settings.rememberedBrightness(s.key, evening: false) ?? hardware[s.key]?.read ?? 100
        let night = Settings.rememberedBrightness(s.key, evening: true) ?? (s.control == .hardware ? Settings.nightBrightness : 70)
        if f >= 1 { return day }
        if f <= 0 { return night }
        // In 5% steps while fading: fewer writes to the monitor.
        return Int(((Double(night) + f * Double(day - night)) / 5).rounded()) * 5
    }

    /// Sends the next brightness change to one monitor; called again when that write finishes.
    private func driveHardware() {
        guard !ddcBusy, Date() >= ddcHoldUntil else { return }
        let f = brightnessFraction()
        for s in screens where s.control == .hardware {
            guard let ref = ddcRefs[s.id] else { continue }
            var hw = hardware[s.key] ?? Hardware()
            // Wait for the first read so the user's own daytime level is known before changing anything.
            if !hw.firstReadDone && f >= 1 { continue }
            // Fresh start in daylight with nothing remembered yet: leave the monitor as the user has it.
            if hw.written == nil && f >= 1 && Settings.rememberedBrightness(s.key, evening: false) == nil { continue }
            let target = brightnessTarget(s, f)
            guard target != hw.written else { continue }
            hw.written = target
            hardware[s.key] = hw
            ddcBusy = true
            let units = Int((Double(target) * Double(hw.max) / 100).rounded())
            ddcQueue.async {
                let ok = DDC.writeBrightness(ref, units)
                DispatchQueue.main.async { self.hardwareWritten(s, ok) }
            }
            return
        }
    }

    private func hardwareWritten(_ s: Screen, _ ok: Bool) {
        ddcBusy = false
        var hw = hardware[s.key] ?? Hardware()
        if ok {
            hw.failures = 0
            if ddcWorked.insert(s.key).inserted { Reporter.log("\(s.name): hardware brightness works") }
        } else {
            hw.failures += 1
            hw.written = nil
            ddcHoldUntil = Date().addingTimeInterval(10)
            Reporter.log("\(s.name): brightness change failed (\(hw.failures))")
            if hw.failures >= 3 {
                hardware[s.key] = hw
                ddcBroken.insert(s.key)
                if ddcWorked.contains(s.key) {
                    addProblem(Problem(id: "ddc-\(s.key)", title: "\(s.name) stopped responding",
                                       detail: "Its brightness is dimmed in software for now. If this keeps happening, please report it."))
                }
                rescanScreens()
                return
            }
        }
        hardware[s.key] = hw
        driveHardware()
    }

    // MARK: Colour

    private func naturalFraction() -> Double { Sun.dayFraction(place, at: now) }
    private var previewing: Bool { (previewUntil ?? .distantPast) > Date() }

    private func colourFraction() -> Double {
        if previewing { return 0 }
        if Settings.pausedUntil != nil || frontAppPause != nil { return 1 }
        return naturalFraction()
    }

    /// Brightness doesn't jump when a photo app comes to the front, only colours do.
    private func brightnessFraction() -> Double {
        if previewing { return 0 }
        if Settings.pausedUntil != nil { return 1 }
        return naturalFraction()
    }

    var editingEvening: Bool { brightnessFraction() < 0.5 }

    // Runs every 2 s: macOS resets gamma on wake/replug, the filter re-checks it each tick
    // (and only writes when something actually changed).
    @objc private func tick() {
        let natural = naturalFraction()
        if wasFullDay == true && natural < 1 {
            // Sun is going down: pick up any brightness the user set on the monitor itself today.
            ddcHoldUntil = max(ddcHoldUntil, Date().addingTimeInterval(1.5))
            for s in screens where s.control == .hardware { readHardware(s, adoptAsDay: true) }
        }
        wasFullDay = natural >= 1
        fade(to: colourFraction())
        driveHardware()
        updateIcon()
        if popover.isShown { store.refresh() }
    }

    /// Big jumps (pause, resume, preview, launch) fade over ~1 s instead of flashing.
    private func fade(to target: Double) {
        if fadeTimer != nil { fadeTo = target; return }
        if abs(target - shown) < 0.06 { render(target); return }
        fadeFrom = shown
        fadeTo = target
        fadeStart = Date()
        fadeTimer = Timer.scheduledTimer(timeInterval: 1.0 / 30, target: self, selector: #selector(fadeStep), userInfo: nil, repeats: true)
    }

    @objc private func fadeStep() {
        let t = min(Date().timeIntervalSince(fadeStart) / 1.2, 1)
        let eased = t * t * (3 - 2 * t)
        render(fadeFrom + (fadeTo - fadeFrom) * eased)
        if t >= 1 {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    private func render(_ fraction: Double) {
        shown = fraction
        let colour = Colour.at(fraction: fraction)
        let bf = brightnessFraction()
        var dims: [CGDirectDisplayID: Double] = [:]
        for s in screens where s.control == .software && !s.isBuiltin {
            dims[s.id] = max(0.2, Double(brightnessTarget(s, bf)) / 100)
        }
        let rejectedBefore = filter.rejected
        filter.apply(colour, dims: dims, displays: screens.filter { !$0.overlay }.map(\.id))
        overlays.update(colour, dims: dims, displays: screens.filter(\.overlay).map(\.id))
        if filter.rejected != rejectedBefore {
            Reporter.log("colour curve not supported on display \(filter.rejected.subtracting(rejectedBefore)), using overlay")
            rescanScreens()
        }
    }

    private func colourConflict() {
        let others = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
            .filter { App.colourApps.contains($0.lowercased()) }
        Reporter.log("another app keeps changing the colour curve; colour apps running: \(others)")
        let who = others.isEmpty ? "Another app" : others.joined(separator: " and ")
        addProblem(Problem(id: "conflict", title: "\(who) is also changing your screen colours",
                           detail: "Two colour apps fight and make the screen flicker, so Sunscreen stepped back for 5 minutes. Quit \(others.first ?? "the other app") to use Sunscreen.",
                           reportable: others.isEmpty))
    }

    // MARK: Menu bar icon

    private func updateIcon() {
        let symbol = Settings.pausedUntil != nil ? "pause.circle" : (shown < 0.5 ? "moon.stars" : "sun.max")
        let dot = update != nil || !problems.isEmpty
        let key = symbol + (dot ? "+dot" : "")
        guard key != iconKey, let button = statusItem?.button else { return }
        iconKey = key
        button.image = menuBarIcon(symbol, dot: dot)
    }

    /// Menu bar symbol, with a small dot in the corner when an update or a problem is waiting.
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

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem?.button else { return }
        if Date().timeIntervalSince(lastUpdateCheck) > 3600 { checkForUpdates() }
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Actions (panel, hotkey, URLs)

    func pause(minutes: Double) {
        Settings.pausedUntil = Date().addingTimeInterval(minutes * 60)
        previewUntil = nil
        tick()
    }

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

    func toggleCreativePause() {
        Settings.pauseInCreativeApps.toggle()
        frontAppChanged()
    }

    /// Brightness slider: applies right away and is remembered for this screen, for the current
    /// period (daytime or evening; during the evening preview it sets the evening value).
    func setBrightness(_ id: CGDirectDisplayID, _ value: Int) {
        guard let s = screens.first(where: { $0.id == id }) else { return }
        if previewing { previewUntil = Date().addingTimeInterval(8) }
        switch s.control {
        case .builtin:
            BuiltinBrightness.set(id, value)
        case .hardware:
            Settings.remember(value, for: s.key, evening: editingEvening)
            driveHardware()
        case .software:
            Settings.remember(value, for: s.key, evening: editingEvening)
            render(shown)
        }
        store.refresh()
    }

    func toggleOverlay(_ key: String) {
        var keys = Settings.overlayScreens
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        Settings.overlayScreens = keys
        Reporter.log("overlay \(keys.contains(key) ? "on" : "off") for \(key)")
        rescanScreens()
        render(shown)
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

    // MARK: Updates

    @objc private func periodicUpdateCheck() { checkForUpdates() }

    func checkForUpdates(manual: Bool = false, thenInstall: Bool = false) {
        lastUpdateCheck = Date()
        Updater.check { [weak self] release in
            guard let self else { return }
            self.update = release
            if let release { Reporter.log("update available: \(release.version)") }
            if release == nil, manual { self.flash("Up to date") }
            if release != nil, thenInstall { self.installUpdate() }
            self.iconKey = ""
            self.tick()
            self.store.refresh()
        }
    }

    func installUpdate() {
        guard let release = update, updateStatus != "Updating..." else { return }
        updateStatus = "Updating..."
        store.refresh()
        Updater.install(release) { [weak self] error in
            guard let self else { return }
            self.updateStatus = nil
            self.addProblem(Problem(id: "update", title: "The update didn't install",
                                    detail: "Report it with one click, or get the new version from the website.", extra: error))
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

    // MARK: Problems and reports

    private func addProblem(_ p: Problem) {
        guard !problems.contains(where: { $0.id == p.id }) else { return }
        problems.append(p)
        Reporter.log("problem shown: \(p.title)")
        iconKey = ""
        updateIcon()
        store.refresh()
    }

    func dismissProblem(_ id: String) {
        problems.removeAll { $0.id == id }
        iconKey = ""
        updateIcon()
        store.refresh()
    }

    /// Opens a GitHub issue with everything filled in; the user only presses Submit.
    func report(_ problem: Problem?) {
        NSWorkspace.shared.open(Reporter.issueURL(title: problem?.title ?? "Problem with Sunscreen", body: diagnostics(problem)))
        if let problem { dismissProblem(problem.id) }
        popover.performClose(nil)
    }

    private func checkPreviousCrash() {
        let last = Settings.defaults.object(forKey: "lastLaunch") as? Date
        Settings.defaults.set(Date(), forKey: "lastLaunch")
        guard let last, let summary = Reporter.crashSummary(since: last) else { return }
        Reporter.log("previous run crashed")
        addProblem(Problem(id: "crash", title: "Sunscreen quit unexpectedly",
                           detail: "Send the details with one click so it can be fixed.", extra: summary))
    }

    private func diagnostics(_ problem: Problem?) -> String {
        let others = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
            .filter { App.colourApps.contains($0.lowercased()) }
        let mode = Settings.pausedUntil != nil ? "paused" : (previewing ? "preview" : String(format: "day fraction %.2f", naturalFraction()))
        var out = [
            "### What happened?",
            "_Write a line about what you saw if you like, then press **Submit new issue**._",
            "",
            "### Details (filled in automatically)",
            "- Sunscreen \(Updater.current) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(Reporter.machine)",
        ]
        if let problem { out.append("- Problem: \(problem.title). \(problem.detail)") }
        for s in screens {
            let hw = hardware[s.key]
            let ddc = s.control == .hardware ? ", DDC read \(hw?.read.map { "\($0)%" } ?? "n/a"), last set \(hw?.written.map { "\($0)%" } ?? "n/a"), scale \(hw?.max ?? 100)" : ""
            out.append("- Screen: \(s.name) [\(s.key)], \(s.isBuiltin ? "built-in" : "external"), brightness \(s.control), colour \(s.overlay ? "overlay" : "gamma")\(ddc)")
        }
        out.append("- Evening \(Int(Settings.nightKelvin))K, daytime \(Int(Settings.dayKelvin))K, location \(place.exact ? "exact" : "from time zone \(TimeZone.current.identifier)")")
        out.append("- Now: \(mode), colour app conflict: \(filter.inConflict), other colour apps running: \(others.isEmpty ? "none" : others.joined(separator: ", "))")
        if let extra = problem?.extra {
            out.append("\n<details><summary>Error details</summary>\n\n```\n\(extra)\n```\n</details>")
        }
        out.append("\n<details><summary>Recent events</summary>\n\n```\n\(Reporter.recent.suffix(25).joined(separator: "\n"))\n```\n</details>")
        return out.joined(separator: "\n")
    }

    // MARK: Panel data

    func makeSnapshot() -> Snapshot {
        let now = self.now
        let natural = naturalFraction()
        let mode: Snapshot.Mode
        if previewing { mode = .preview }
        else if Settings.pausedUntil != nil { mode = .paused }
        else if frontAppPause != nil && natural < 1 { mode = .appPause }
        else if natural >= 1 { mode = .day }
        else if natural <= 0 { mode = .evening }
        else { mode = .fading }
        let events = Sun.events(place, on: now)
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let length = end.timeIntervalSince(start)
        let timeline = (0...96).map { Sun.dayFraction(place, at: start.addingTimeInterval(length * Double($0) / 96)) }
        let bf = brightnessFraction()
        let rows = screens.filter { !$0.isBuiltin || $0.control == .builtin }.map { s -> ScreenRow in
            let value = s.control == .builtin ? (BuiltinBrightness.get(s.id) ?? 100) : brightnessTarget(s, bf)
            let note = s.overlay ? "Overlay colour" : (s.control == .software && !s.isBuiltin ? "Software dimming" : "")
            return ScreenRow(id: s.id, key: s.key, name: s.name, symbol: s.symbol, note: note, value: value,
                             isBuiltin: s.isBuiltin, overlay: s.overlay)
        }
        return Snapshot(mode: mode, now: now, placeName: placeName, exactLocation: place.exact,
                        kelvin: Colour.kelvinAt(fraction: colourFraction()), sunrise: events.rise, sunset: events.set,
                        filterOn: Sun.nextEveningStart(place, after: now),
                        filterOff: natural < 1 ? Sun.nextFullDay(place, after: now) : nil,
                        pausedUntil: Settings.pausedUntil, appPause: frontAppPause, timeline: timeline,
                        position: now.timeIntervalSince(start) / length, rows: rows, editingEvening: editingEvening,
                        problem: problems.first)
    }

    /// Renders the panel to a PNG without touching any screen: Sunscreen --snapshot out.png [hour]
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
            Reporter.log("login item change failed: \(error.localizedDescription)")
        }
        store.refresh()
    }
}
