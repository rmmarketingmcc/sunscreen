import AppKit

/// The warm colour (and software dimming) applied through each display's gamma curve.
///
/// Built on the display's own calibrated curve instead of replacing it, rewritten only when
/// something actually changed, and it backs off when another app keeps overwriting the curve
/// (two colour apps fighting is what makes screens flash).
final class ColourFilter {
    private struct Table {
        var r: [CGGammaValue]
        var g: [CGGammaValue]
        var b: [CGGammaValue]
    }

    private var originals: [CGDirectDisplayID: Table] = [:]
    private var written: [CGDirectDisplayID: Table] = [:]
    private var foreignWrites: [CGDirectDisplayID: [Date]] = [:]
    private var backoffUntil: [CGDirectDisplayID: Date] = [:]
    private(set) var rejected: Set<CGDirectDisplayID> = []   // gamma calls fail here: use an overlay
    var onConflict: (() -> Void)?

    var inConflict: Bool { backoffUntil.values.contains { $0 > Date() } }

    func apply(_ colour: Colour, dims: [CGDirectDisplayID: Double], displays: [CGDirectDisplayID]) {
        let now = Date()
        for id in displays {
            if let until = backoffUntil[id], until > now { continue }
            let dim = dims[id] ?? 1
            if colour.isNeutral && dim > 0.999 {
                if written[id] != nil { restore(id) }
                continue
            }
            guard let original = original(for: id) else { rejected.insert(id); continue }
            let want = scaled(original, colour.r * dim, colour.g * dim, colour.b * dim)
            if let last = written[id], let current = read(id) {
                if close(current, last) {
                    if close(last, want) { continue }   // already on screen
                } else if !close(current, original) {
                    // Not ours and not the system's reset after wake: another app is writing curves.
                    let recent = (foreignWrites[id] ?? []).filter { now.timeIntervalSince($0) < 60 } + [now]
                    foreignWrites[id] = recent
                    if recent.count >= 3 {
                        backoffUntil[id] = now.addingTimeInterval(300)
                        foreignWrites[id] = []
                        written[id] = nil
                        onConflict?()
                        continue
                    }
                }
            }
            if write(id, want) { written[id] = want } else { rejected.insert(id) }
        }
        for id in Array(originals.keys) where !displays.contains(id) {
            originals[id] = nil
            written[id] = nil
        }
    }

    func restoreAll() {
        for id in Array(written.keys) { restore(id) }
    }

    private func restore(_ id: CGDirectDisplayID) {
        if let original = originals[id] { _ = write(id, original) }
        // Known macOS bug: restoring can leave an all-zero (black) curve. Never leave it like that.
        if let current = read(id), (current.r.max() ?? 0) < 0.05 { CGDisplayRestoreColorSyncSettings() }
        written[id] = nil
    }

    private func original(for id: CGDirectDisplayID) -> Table? {
        if let o = originals[id] { return o }
        guard var table = read(id) else { return nil }
        if (table.r.max() ?? 0) < 0.05 || (table.g.max() ?? 0) < 0.05 || (table.b.max() ?? 0) < 0.05 {
            let ramp = (0..<256).map { CGGammaValue($0) / 255 }
            table = Table(r: ramp, g: ramp, b: ramp)
        }
        originals[id] = table
        return table
    }

    private func read(_ id: CGDirectDisplayID) -> Table? {
        let capacity = Int(CGDisplayGammaTableCapacity(id))
        guard capacity > 1 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: capacity), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, UInt32(capacity), &r, &g, &b, &count) == .success, count > 1 else { return nil }
        let n = Int(count)
        return Table(r: Array(r.prefix(n)), g: Array(g.prefix(n)), b: Array(b.prefix(n)))
    }

    private func write(_ id: CGDirectDisplayID, _ t: Table) -> Bool {
        CGSetDisplayTransferByTable(id, UInt32(t.r.count), t.r, t.g, t.b) == .success
    }

    private func scaled(_ t: Table, _ r: Double, _ g: Double, _ b: Double) -> Table {
        Table(r: t.r.map { $0 * CGGammaValue(r) }, g: t.g.map { $0 * CGGammaValue(g) }, b: t.b.map { $0 * CGGammaValue(b) })
    }

    private func close(_ a: Table, _ b: Table) -> Bool {
        guard a.r.count == b.r.count, a.r.count > 1 else { return false }
        let last = a.r.count - 1
        for i in Set(stride(from: 0, through: last, by: max(1, last / 8)).map { $0 } + [last]) {
            if abs(a.r[i] - b.r[i]) > 0.004 || abs(a.g[i] - b.g[i]) > 0.004 || abs(a.b[i] - b.b[i]) > 0.004 { return false }
        }
        return true
    }
}

/// Fallback for screens the gamma curve can't reach (Sidecar, AirPlay, DisplayLink): a click-through
/// window tinted warm on top of everything. Not as clean as gamma (blacks get a little lighter) but it works.
final class Overlays {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    func update(_ colour: Colour, dims: [CGDirectDisplayID: Double], displays: [CGDirectDisplayID]) {
        for (id, window) in windows where !displays.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
        }
        // Warm tint strength follows how much blue is removed; dimming adds black on top.
        let warm = 0.4 * (1 - colour.b)
        for id in displays {
            guard let screen = Screens.nsScreen(for: id) else { continue }
            let dim = 1 - (dims[id] ?? 1)
            let alpha = 1 - (1 - warm) * (1 - dim)
            if alpha < 0.01 {
                windows[id]?.orderOut(nil)
                continue
            }
            let orangeShare = warm * (1 - dim) / alpha
            let tint = NSColor(srgbRed: CGFloat(orangeShare), green: CGFloat(orangeShare * 0.45), blue: 0, alpha: CGFloat(alpha))
            let window = windows[id] ?? makeWindow(on: screen)
            windows[id] = window
            if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            window.backgroundColor = tint
            window.orderFrontRegardless()
        }
    }

    func removeAll() {
        windows.values.forEach { $0.orderOut(nil) }
        windows = [:]
    }

    private func makeWindow(on screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        w.isOpaque = false
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return w
    }
}
