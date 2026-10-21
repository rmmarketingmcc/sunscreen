import AppKit
import IOKit

/// One connected display and how Sunscreen can control it.
struct Screen: Identifiable, Equatable {
    enum Control: Equatable {
        case builtin    // MacBook screen, DisplayServices
        case hardware   // external monitor over DDC/CI
        case software   // no hardware control: dimmed through the colour curve or overlay
    }
    let id: CGDirectDisplayID
    let key: String         // stable across reconnects: vendor-model-serial
    let name: String
    let isBuiltin: Bool
    let control: Control
    let overlay: Bool       // colour drawn by an overlay window (gamma doesn't reach this picture)

    var symbol: String { isBuiltin ? "laptopcomputer" : "display" }
}

enum Screens {
    static func onlineIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func key(for id: CGDirectDisplayID) -> String {
        String(format: "%04X-%04X-%u", CGDisplayVendorNumber(id), CGDisplayModelNumber(id), CGDisplaySerialNumber(id))
    }

    static func nsScreen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }
    }

    static func name(for id: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(id) != 0 { return "MacBook screen" }
        return nsScreen(for: id)?.localizedName ?? "External display"
    }

    /// Screens whose picture is captured or streamed (Sidecar, AirPlay, DisplayLink...): the
    /// gamma curve never reaches them, so the colour has to be drawn on top.
    static func looksStreamed(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["sidecar", "airplay", "displaylink", "luna display", "duet"].contains { n.contains($0) }
    }
}

// MARK: - MacBook screen brightness (DisplayServices, private but stable since 10.12)

enum BuiltinBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn = dlsym(lib, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn = dlsym(lib, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

    static var available: Bool { getFn != nil && setFn != nil }

    static func get(_ id: CGDirectDisplayID) -> Int? {
        var value: Float = 0
        guard let getFn, getFn(id, &value) == 0 else { return nil }
        return Int((value * 100).rounded())
    }

    @discardableResult
    static func set(_ id: CGDirectDisplayID, _ percent: Int) -> Bool {
        guard let setFn else { return false }
        return setFn(id, Float(min(max(percent, 0), 100)) / 100) == 0
    }
}

// MARK: - External monitor brightness (DDC/CI over IOAVService, Apple Silicon)

enum DDC {
    // Private IOKit functions (the ones MonitorControl, Lunar and m1ddc use), looked up at
    // runtime so the app still launches where they don't exist (Intel).
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let create = dlsym(iokit, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
    private static let writeI2C = dlsym(iokit, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: I2CFn.self) }
    private static let readI2C = dlsym(iokit, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: I2CFn.self) }

    struct Service {
        let key: String        // vendor-model-serial, same format as Screen.key
        let partialKey: String // vendor-model, for monitors that report serial differently
        let ref: CFTypeRef
    }

    /// Walks the IO registry: each framebuffer (IOMobileFramebufferShim / AppleCLCD2) is followed by
    /// its DCPAVServiceProxy, so the monitor identity comes from the framebuffer just before it.
    static func services() -> [Service] {
        guard let create else { return [] }
        var iter = io_iterator_t()
        guard IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        let name = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { name.deallocate() }
        var identity: (vendor: Int, model: Int, serial: Int)?
        var found: [Service] = []
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, name) == KERN_SUCCESS else { continue }
            let n = String(cString: name)
            if n == "IOMobileFramebufferShim" || n == "AppleCLCD2" {
                identity = monitorIdentity(entry)
            } else if n == "DCPAVServiceProxy" {
                let location = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "Location" as CFString, kCFAllocatorDefault,
                                                               IOOptionBits(kIORegistryIterateRecursively)) as? String
                guard location == "External", let id = identity,
                      let ref = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                found.append(Service(key: String(format: "%04X-%04X-%u", id.vendor, id.model, id.serial),
                                     partialKey: String(format: "%04X-%04X", id.vendor, id.model), ref: ref))
            }
        }
        return found
    }

    private static func monitorIdentity(_ entry: io_registry_entry_t) -> (vendor: Int, model: Int, serial: Int)? {
        let attrs = (IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any])?["ProductAttributes"] as? [String: Any]
        let edid = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        // EDID UUID starts with the vendor (4 hex) and the model with its bytes swapped (4 hex).
        let edidChars = Array(edid ?? "")
        let edidVendor = edidChars.count >= 8 ? Int(String(edidChars[0..<4]), radix: 16) : nil
        let edidModel = edidChars.count >= 8 ? Int(String(edidChars[6..<8]) + String(edidChars[4..<6]), radix: 16) : nil
        guard let vendor = attrs?["LegacyManufacturerID"] as? Int ?? edidVendor else { return nil }
        let product = attrs?["ProductID"] as? Int
        guard let model = (product.flatMap { $0 <= 0xFFFF ? $0 : nil }) ?? edidModel else { return nil }
        return (vendor, model, attrs?["SerialNumber"] as? Int ?? 0)
    }

    /// Pairs external CoreGraphics displays with DDC services: exact identity first, then vendor+model,
    /// then by order when the counts line up.
    static func match(_ displays: [CGDirectDisplayID], _ services: [Service]) -> [CGDirectDisplayID: CFTypeRef] {
        var result: [CGDirectDisplayID: CFTypeRef] = [:]
        var left = services
        for id in displays {
            let key = Screens.key(for: id)
            if let i = left.firstIndex(where: { $0.key == key }) { result[id] = left.remove(at: i).ref }
        }
        for id in displays where result[id] == nil {
            let partial = String(Screens.key(for: id).split(separator: "-").prefix(2).joined(separator: "-"))
            if let i = left.firstIndex(where: { $0.partialKey == partial }) { result[id] = left.remove(at: i).ref }
        }
        let unmatched = displays.filter { result[$0] == nil }
        if unmatched.count == left.count { for (id, s) in zip(unmatched, left) { result[id] = s.ref } }
        return result
    }

    /// Current and maximum brightness (VCP 0x10). Blocking (~60 ms): call off the main thread.
    static func readBrightness(_ ref: CFTypeRef) -> (current: Int, max: Int)? {
        guard let writeI2C, let readI2C else { return nil }
        var request: [UInt8] = [0x82, 0x01, 0x10, 0]
        request[3] = 0x6E ^ request[0] ^ request[1] ^ request[2]
        for attempt in 0..<4 {
            // Many monitors ignore a lone request and answer with a "null message" (6E 80 BE):
            // sending it twice, like m1ddc does, gets a real reply. Slower monitors get more time per retry.
            var sent = false
            for _ in 0..<2 {
                usleep(10_000)
                if request.withUnsafeMutableBytes({ writeI2C(ref, 0x37, 0x51, $0.baseAddress!, 4) }) == KERN_SUCCESS { sent = true }
            }
            guard sent else { continue }
            usleep(UInt32(40_000 + attempt * 30_000))
            var reply = [UInt8](repeating: 0, count: 11)
            let got = reply.withUnsafeMutableBytes { readI2C(ref, 0x37, 0, $0.baseAddress!, 11) }
            guard got == KERN_SUCCESS, reply[2] == 0x02, reply[3] == 0x00,
                  reply[0..<10].reduce(UInt8(0x50), ^) == reply[10] else { continue }
            let maximum = Int(reply[6]) << 8 | Int(reply[7])
            let current = Int(reply[8]) << 8 | Int(reply[9])
            if maximum > 0 { return (current, maximum) }
        }
        return nil
    }

    /// Sets brightness in the monitor's own units (0...max). Blocking: call off the main thread.
    static func writeBrightness(_ ref: CFTypeRef, _ value: Int) -> Bool {
        guard let writeI2C else { return false }
        let v = UInt16(clamping: max(value, 0))
        var packet: [UInt8] = [0x84, 0x03, 0x10, UInt8(v >> 8), UInt8(v & 0xFF), 0]
        packet[5] = 0x6E ^ 0x51 ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3] ^ packet[4]
        var ok = false
        for _ in 0..<2 {   // monitors drop the odd packet; sending twice is what m1ddc does
            usleep(10_000)
            if packet.withUnsafeMutableBytes({ writeI2C(ref, 0x37, 0x51, $0.baseAddress!, 6) }) == KERN_SUCCESS { ok = true }
        }
        return ok
    }
}
