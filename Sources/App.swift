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
    enum Mode { case day, evening, fading, bright, dark, preview, appPause }
    let mode: Mode
    let now: Date
    let placeName: String
    let exactLocation: Bool
    let kelvin: Double
    let sunrise: Date?
    let sunset: Date?
    let filterOn: Date?    // next time the filter starts (nil if on now)
    let filterOff: Date?   // next time it's fully off again (nil if off now)
    let override: App.Override
    let overrideUntil: Date?
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

    /// What's on the screens: colour, software dimming and monitor brightness, faded as one.
    private struct Look {
        var colour: Colour
        var dims: [CGDirectDisplayID: Double]   // software dimming, 1 = none
        var levels: [String: Double]            // monitor brightness % (DDC), by screen key

        static func mix(_ a: Look, _ b: Look, _ t: Double) -> Look {
            func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
            var dims: [CGDirectDisplayID: Double] = [:]
            for k in Set(a.dims.keys).union(b.dims.keys) { dims[k] = m(a.dims[k] ?? 1, b.dims[k] ?? 1) }
            var levels: [String: Double] = [:]
            for (k, v) in b.levels { levels[k] = m(a.levels[k] ?? v, v) }
            return Look(colour: Colour(r: m(a.colour.r, b.colour.r), g: m(a.colour.g, b.colour.g), b: m(a.colour.b, b.colour.b)),
                        dims: dims, levels: levels)
        }

        func matches(_ o: Look) -> Bool {
            abs(colour.r - o.colour.r) < 0.002 && abs(colour.g - o.colour.g) < 0.002 && abs(colour.b - o.colour.b) < 0.002
                && Set(dims.keys).union(o.dims.keys).allSatisfy { abs((dims[$0] ?? 1) - (o.dims[$0] ?? 1)) < 0.002 }
                && Set(levels.keys) == Set(o.levels.keys)
                && levels.allSatisfy { abs($0.value - (o.levels[$0.key] ?? -1)) < 0.5 }
        }
    }

    /// Every change glides over this long, so eyes adjust instead of being hit by a jump.
    static let fadeSeconds = 1.6
    private var shownLook: Look?
    private var fadeFrom: Look?
    private var fadeTarget: Look?
    private var fadeStart = Date()
    private var fadeDuration = App.fadeSeconds
    private var fadeEaseOut = false          // clicks: change starts at once, then settles gently
    /// Clicks fade a bit quicker than the sun does, and start changing immediately.
    static let clickFadeSeconds = 1.2
    private var fadeTimer: Timer?
    private var previewFraction = 0.0      // what a preview shows: 0 = evening look, 1 = daytime look

    enum Override { case auto, bright, dark }
    var override: Override {
        if Settings.pausedUntil != nil { return .bright }
        if Settings.darkUntil != nil { return .dark }
        return .auto
    }
    var overrideUntil: Date? { Settings.pausedUntil ?? Settings.darkUntil }
    private var hardwareGoal: [String: Int] = [:]   // brightness each monitor should be at right now
    private var ddcCursor = 0
    private var quitting = false
    private(set) var whatsNew: [Changelog.Entry] = []

    private var frontAppPause: String?

    private(set) var update: Updater.Release?
    private(set) var updateStatus: String?   // "Updating...", "Up to date"
    private var lastUpdateCheck = Date.distantPast
    private(set) var problems: [Problem] = []
    private var iconKey = ""

    // MARK: Lifecycle

    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Login items are started with an "open application" event flagged as a login launch.
        if let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == AEEventID(kAEOpenApplication) {
            launchedAtLogin = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        }
    }

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
            if args.contains("--whats-new") { whatsNew = Array(Changelog.load().prefix(1)) }
            Task { @MainActor in self.renderSnapshot(to: path); exit(0) }
            return
        }
        Reporter.log("Sunscreen \(Updater.current) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(Reporter.machine)")
        checkPreviousCrash()
        checkWhatsNew()

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
        // Opened by hand (Dock, Spotlight, after installing or updating): show the panel so you see
        // it's running. At login it stays quietly in the menu bar.
        if !launchedAtLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if !self.popover.isShown { self.togglePanel() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.checkForUpdates() }
        Timer.scheduledTimer(timeInterval: 6 * 3600, target: self, selector: #selector(periodicUpdateCheck), userInfo: nil, repeats: true)
    }

    /// Clicking Sunscreen in the Dock, Launchpad, Spotlight or Applications while it's running
    /// opens the panel, same as clicking the sun in the menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { if !self.popover.isShown { self.togglePanel() } }
        return false
    }

    /// Quitting (or updating) eases the colours back to normal instead of snapping.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting, let shown = shownLook,
              !shown.colour.isNeutral || shown.dims.values.contains(where: { $0 < 0.999 }) else { return .terminateNow }
        transition(to: Look(colour: .neutral, dims: [:], levels: shown.levels), duration: 1.2)
        quitting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        fadeTimer?.invalidate()
        filter.restoreAll()
        overlays.removeAll()
    }

    /// After an update, show what changed (from the changelog bundled in the app) once.
    private func checkWhatsNew() {
        let current = Updater.current
        // Installs from before this setting existed count as 1.3.
        let last = Settings.lastSeenVersion ?? (Settings.defaults.bool(forKey: "loginItemConfigured") ? "1.3" : nil)
        Settings.lastSeenVersion = current
        guard let last, Updater.isNewer(current, than: last) else { return }
        whatsNew = Changelog.since(last)
    }

    func dismissWhatsNew() {
        whatsNew = []
        store.refresh()
    }

    func openChangelog() { NSWorkspace.shared.open(URL(string: "https://rmmarketingmcc.github.io/sunscreen/#changelog")!) }

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
            case "auto": setMode(.auto)
            case "bright": setMode(.bright)
            case "dark": setMode(.dark)
            case "preview": preview(seconds: Double(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "seconds" }?.value ?? "") ?? 10)
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

    private var lastFrontApp: (id: String, name: String) = ("", "")

    @objc private func frontAppChanged() {
        let front = NSWorkspace.shared.frontmostApplication
        let id = front?.bundleIdentifier ?? ""
        // Our own panel coming to the front doesn't count: judge by the app the user was in.
        if id != Bundle.main.bundleIdentifier { lastFrontApp = (id, front?.localizedName ?? "this app") }
        let creative = Settings.pauseInCreativeApps && App.creativeApps.contains { lastFrontApp.id.hasPrefix($0) }
        let name = creative ? lastFrontApp.name : nil
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

    /// nil = leave this monitor alone (first read still pending, or untouched in daylight).
    private func hardwareLevel(_ s: Screen, _ f: Double) -> Int? {
        let hw = hardware[s.key] ?? Hardware()
        // Wait for the first read so the user's own daytime level is known before changing anything.
        if !hw.firstReadDone && f >= 1 { return nil }
        // Fresh start in daylight with nothing remembered yet: leave the monitor as the user has it.
        if hw.written == nil && f >= 1 && Settings.rememberedBrightness(s.key, evening: false) == nil { return nil }
        return brightnessTarget(s, f)
    }

    /// Sends the newest brightness goal to one monitor at a time (round robin) and runs again when the
    /// write finishes, so during a fade each monitor steps through the in-between levels as fast as it takes them.
    private func driveHardware() {
        guard !ddcBusy, Date() >= ddcHoldUntil else { return }
        let monitors = screens.filter { $0.control == .hardware }
        guard !monitors.isEmpty else { return }
        for offset in 0..<monitors.count {
            let s = monitors[(ddcCursor + offset) % monitors.count]
            guard let ref = ddcRefs[s.id], let goal = hardwareGoal[s.key] else { continue }
            var hw = hardware[s.key] ?? Hardware()
            guard goal != hw.written else { continue }
            ddcCursor = (ddcCursor + offset + 1) % monitors.count
            hw.written = goal
            hardware[s.key] = hw
            ddcBusy = true
            let units = Int((Double(goal) * Double(hw.max) / 100).rounded())
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
        if previewing { return previewFraction }
        switch override {
        case .bright: return 1
        case .dark: return 0
        case .auto: return frontAppPause != nil ? 1 : naturalFraction()
        }
    }

    /// Brightness doesn't jump when a photo app comes to the front, only colours do.
    private func brightnessFraction() -> Double {
        if previewing { return previewFraction }
        switch override {
        case .bright: return 1
        case .dark: return 0
        case .auto: return naturalFraction()
        }
    }

    var editingEvening: Bool { brightnessFraction() < 0.5 }

    // Runs every 2 s: macOS resets gamma on wake/replug, the filter re-checks it each tick
    // (and only writes when something actually changed).
    @objc private func tick() { update() }

    /// Works out what the screens should look like now and glides there.
    private func update(fade duration: Double = App.fadeSeconds, easeOut: Bool = false) {
        guard !quitting else { return }
        let natural = naturalFraction()
        if wasFullDay == true && natural < 1 {
            // Sun is going down: pick up any brightness the user set on the monitor itself today.
            ddcHoldUntil = max(ddcHoldUntil, Date().addingTimeInterval(1.5))
            for s in screens where s.control == .hardware { readHardware(s, adoptAsDay: true) }
        }
        wasFullDay = natural >= 1
        transition(to: targetLook(), duration: duration, easeOut: easeOut)
        scheduleEndOfPreviewOrPause()
        updateIcon()
        if popover.isShown { store.refresh() }
    }

    /// The fade back starts the moment a preview or pause runs out, not at the next 2 s tick.
    private var endTimer: Timer?
    private func scheduleEndOfPreviewOrPause() {
        let ends = [previewUntil, Settings.pausedUntil, Settings.darkUntil].compactMap { $0 }.filter { $0 > Date() }
        guard let next = ends.min(), next.timeIntervalSinceNow < 2.5 else { return }
        if let current = endTimer, current.isValid, abs(current.fireDate.timeIntervalSince(next)) < 0.05 { return }
        endTimer?.invalidate()
        let timer = Timer(fireAt: next.addingTimeInterval(0.02), interval: 0, target: self, selector: #selector(tick), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    private func targetLook() -> Look {
        let bf = brightnessFraction()
        var dims: [CGDirectDisplayID: Double] = [:]
        var levels: [String: Double] = [:]
        for s in screens {
            if s.control == .software && !s.isBuiltin { dims[s.id] = max(0.2, Double(brightnessTarget(s, bf)) / 100) }
            if s.control == .hardware, let level = hardwareLevel(s, bf) { levels[s.key] = Double(level) }
        }
        return Look(colour: Colour.at(fraction: colourFraction()), dims: dims, levels: levels)
    }

    /// Every change glides (colour, dimming and monitor brightness together), never jumps.
    private func transition(to target: Look, duration: Double, easeOut: Bool = false) {
        if fadeTimer != nil, let heading = fadeTarget, heading.matches(target) { return }
        var current = shownLook ?? Look(colour: .neutral, dims: [:], levels: [:])
        // Monitors join the fade from wherever they are now.
        for key in target.levels.keys where current.levels[key] == nil {
            if let level = hardware[key]?.written ?? hardware[key]?.read { current.levels[key] = Double(level) }
        }
        if fadeTimer == nil && current.matches(target) {
            show(target)
            return
        }
        fadeFrom = current
        fadeTarget = target
        fadeStart = Date()
        fadeDuration = duration
        fadeEaseOut = easeOut
        if fadeTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 40, target: self, selector: #selector(fadeStep), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)   // keeps fading while a slider is being dragged
            fadeTimer = timer
        }
    }

    @objc private func fadeStep() {
        guard let from = fadeFrom, let to = fadeTarget else {
            fadeTimer?.invalidate()
            fadeTimer = nil
            return
        }
        let t = min(Date().timeIntervalSince(fadeStart) / fadeDuration, 1)
        // Clicks: changes right away and settles gently. The sun: slow start, slow finish.
        let eased = fadeEaseOut ? 1 - pow(1 - t, 3) : (t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
        show(Look.mix(from, to, eased))
        if t >= 1 {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    private func show(_ look: Look) {
        shownLook = look
        let rejectedBefore = filter.rejected
        filter.apply(look.colour, dims: look.dims, displays: screens.filter { !$0.overlay }.map(\.id))
        overlays.update(look.colour, dims: look.dims, displays: screens.filter(\.overlay).map(\.id))
        for (key, level) in look.levels { hardwareGoal[key] = Int(level.rounded()) }
        driveHardware()
        if filter.rejected != rejectedBefore {
            Reporter.log("colour curve not supported on display \(filter.rejected.subtracting(rejectedBefore)), using overlay")
            rescanScreens()
        }
    }

    /// Sliders follow the finger directly (only automatic changes fade).
    private func followFinger(_ change: (inout Look) -> Void) {
        if var l = shownLook { change(&l); shownLook = l }
        if var l = fadeFrom { change(&l); fadeFrom = l }
        if var l = fadeTarget { change(&l); fadeTarget = l }
        if fadeTimer == nil, let l = shownLook { show(l) }
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
        let symbol: String
        switch override {
        case .bright: symbol = "sun.max.fill"
        case .dark: symbol = "moon.fill"
        case .auto: symbol = colourFraction() < 0.5 ? "moon.stars" : "sun.max"
        }
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

    /// The big switch at the top. Bright = daytime look now, Dark = evening look now.
    /// Both go back to Auto by themselves (Bright at the next sunset, Dark at the next sunrise),
    /// so nobody gets stuck in the wrong mode.
    func setMode(_ mode: Override) {
        previewUntil = nil
        switch mode {
        case .auto:
            Settings.pausedUntil = nil
            Settings.darkUntil = nil
        case .bright:
            Settings.darkUntil = nil
            Settings.pausedUntil = brightUntil()
        case .dark:
            Settings.pausedUntil = nil
            Settings.darkUntil = Sun.nextFullDay(place, after: Date()) ?? Date().addingTimeInterval(12 * 3600)
        }
        Reporter.log("mode \(mode)")
        update(fade: App.clickFadeSeconds, easeOut: true)
    }

    private func brightUntil() -> Date {
        if let evening = Sun.nextEveningStart(place, after: Date()) { return evening }   // daytime: until sunset
        if let morning = Sun.nextFullDay(place, after: Date()),
           let evening = Sun.nextEveningStart(place, after: morning) { return evening }  // night: until tomorrow's sunset
        return Date().addingTimeInterval(12 * 3600)
    }

    /// For links and scripts: bright for a set time.
    func pause(minutes: Double) {
        Settings.darkUntil = nil
        Settings.pausedUntil = Date().addingTimeInterval(minutes * 60)
        previewUntil = nil
        update(fade: App.clickFadeSeconds, easeOut: true)
    }

    func pauseTonight() { setMode(.bright) }
    func resume() { setMode(.auto) }
    /// Control-Option-Command-P: Bright on/off.
    func togglePause() { setMode(override == .bright ? .auto : .bright) }

    /// Shows a look for a few seconds (0 = evening, 1 = daytime) so a change is visible right away.
    func preview(seconds: Double = 10, look fraction: Double = 0) {
        previewFraction = fraction
        previewUntil = Date().addingTimeInterval(seconds)
        update(fade: App.clickFadeSeconds, easeOut: true)
    }

    /// Evening colour as "% blue light". If it isn't evening on screen right now, the evening look
    /// shows for a few seconds so you see what you picked. Dragging glides right behind the finger.
    func setEveningBlue(_ percent: Double, dragging: Bool = false) {
        Settings.nightKelvin = Colour.kelvin(forBluePercent: percent)
        if colourFraction() > 0.05 || previewing {
            previewFraction = 0
            previewUntil = Date().addingTimeInterval(6)
        }
        update(fade: dragging ? 0.35 : App.clickFadeSeconds, easeOut: true)
    }

    /// Daytime colour; in the evening the daytime look shows for a few seconds so you see it.
    func setDayKelvin(_ k: Double) {
        Settings.dayKelvin = k
        if colourFraction() < 0.95 || previewing {
            previewFraction = 1
            previewUntil = Date().addingTimeInterval(6)
        }
        update(fade: App.clickFadeSeconds, easeOut: true)
    }

    func toggleAllSettings() {
        Settings.showAllSettings.toggle()
        store.refresh()
    }

    func toggleCreativePause() {
        Settings.pauseInCreativeApps.toggle()
        frontAppChanged()
        store.refresh()
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
            followFinger { $0.levels[s.key] = Double(value) }
        case .software:
            Settings.remember(value, for: s.key, evening: editingEvening)
            followFinger { $0.dims[s.id] = max(0.2, Double(value) / 100) }
        }
        store.refresh()
    }

    func toggleOverlay(_ key: String) {
        var keys = Settings.overlayScreens
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        Settings.overlayScreens = keys
        Reporter.log("overlay \(keys.contains(key) ? "on" : "off") for \(key)")
        rescanScreens()
        update()
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
        let mode = previewing ? "preview" : "\(override), day fraction \(String(format: "%.2f", naturalFraction()))"
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
        else if override == .bright { mode = .bright }
        else if override == .dark { mode = .dark }
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
                        override: override, overrideUntil: overrideUntil, appPause: frontAppPause, timeline: timeline,
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
        // macOS updates the login-item status a moment later; refresh again so the switch follows.
        for delay in [0.3, 1.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.store.refresh() } }
    }
}
