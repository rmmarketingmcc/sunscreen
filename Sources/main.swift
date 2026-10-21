// Sunscreen: a menu bar app that makes your Mac's screens follow the sun.
// Day: normal colours. Evening: no blue light on every screen, dimmer monitors.
// Colour changes are undone by macOS the moment the app quits or crashes.
// Build: ./build.sh
import AppKit

if CommandLine.arguments.contains("--status") {
    // Diagnostics without UI: Sunscreen.app/Contents/MacOS/Sunscreen --status
    _ = NSApplication.shared
    let place = Sun.currentPlace()
    let f = Sun.dayFraction(place, at: Date())
    let events = Sun.events(place, on: Date())
    print("place: \(place.fallbackName) exact=\(place.exact) lat=\(place.lat) lon=\(place.lon), sun \(String(format: "%.1f", Sun.elevation(place, at: Date()))) deg, day fraction \(String(format: "%.2f", f))")
    print("sunrise \(events.rise.map { "\($0)" } ?? "-"), sunset \(events.set.map { "\($0)" } ?? "-")")
    print("colour now: \(Int(Colour.kelvinAt(fraction: f)))K \(Colour.at(fraction: f))")
    print("paused until: \(Settings.pausedUntil.map { "\($0)" } ?? "not paused")")
    let ids = Screens.onlineIDs()
    let ddc = DDC.match(ids.filter { CGDisplayIsBuiltin($0) == 0 }, DDC.services())
    for id in ids {
        let builtin = CGDisplayIsBuiltin(id) != 0
        print("screen: \(Screens.name(for: id)) [\(Screens.key(for: id))] builtin=\(builtin) ddc=\(ddc[id] != nil)"
              + (builtin ? " brightness=\(BuiltinBrightness.get(id).map { "\($0)%" } ?? "n/a")" : ""))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
