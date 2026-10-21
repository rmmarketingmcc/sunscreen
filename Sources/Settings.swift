import Foundation

/// Everything the user can change, stored in UserDefaults (domain local.sunscreen).
enum Settings {
    static let defaults = UserDefaults.standard
    static let referenceKelvin = 6500.0   // neutral white: no filter
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
    /// Evening brightness for monitors that don't have their own remembered value yet.
    static var nightBrightness: Int {
        get { defaults.object(forKey: "nightBrightness") != nil ? defaults.integer(forKey: "nightBrightness") : 30 }
        set { defaults.set(newValue, forKey: "nightBrightness") }
    }
    /// Survives relaunch and login. nil when not paused or the pause has run out.
    static var pausedUntil: Date? {
        get { (defaults.object(forKey: "pausedUntil") as? Date).flatMap { $0 > Date() ? $0 : nil } }
        set { defaults.set(newValue, forKey: "pausedUntil") }
    }
    /// "Dark" override: full evening look now, until this time (then back to Auto).
    static var darkUntil: Date? {
        get { (defaults.object(forKey: "darkUntil") as? Date).flatMap { $0 > Date() ? $0 : nil } }
        set { defaults.set(newValue, forKey: "darkUntil") }
    }
    /// Own timing on top of the sun, in minutes (positive = later). The evening look starts this much
    /// after sunset, and the morning comes this much after sunrise. 0 = exactly with the sun.
    static let offsetRange = -180...180
    static var eveningOffsetMinutes: Int {
        get { defaults.integer(forKey: "eveningOffsetMinutes") }
        set { defaults.set(min(max(newValue, offsetRange.lowerBound), offsetRange.upperBound), forKey: "eveningOffsetMinutes") }
    }
    static var morningOffsetMinutes: Int {
        get { defaults.integer(forKey: "morningOffsetMinutes") }
        set { defaults.set(min(max(newValue, offsetRange.lowerBound), offsetRange.upperBound), forKey: "morningOffsetMinutes") }
    }
    /// Panel shows everything (true) or just the essentials (false, default).
    static var showAllSettings: Bool {
        get { defaults.bool(forKey: "showAllSettings") }
        set { defaults.set(newValue, forKey: "showAllSettings") }
    }
    /// Version whose "What's new" the user has already seen.
    static var lastSeenVersion: String? {
        get { defaults.string(forKey: "lastSeenVersion") }
        set { defaults.set(newValue, forKey: "lastSeenVersion") }
    }
    /// Normal colours while a photo/video/design app is in front.
    static var pauseInCreativeApps: Bool {
        get { defaults.object(forKey: "pauseInCreativeApps") != nil ? defaults.bool(forKey: "pauseInCreativeApps") : true }
        set { defaults.set(newValue, forKey: "pauseInCreativeApps") }
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

    // Brightness is remembered per screen (Screen.key), separately for daytime and evening,
    // so whatever the user sets in each period is what they get back the next day.
    static func rememberedBrightness(_ key: String, evening: Bool) -> Int? {
        (defaults.dictionary(forKey: evening ? "eveningBrightness" : "dayBrightness")?[key] as? NSNumber)?.intValue
    }

    static func remember(_ value: Int, for key: String, evening: Bool) {
        let name = evening ? "eveningBrightness" : "dayBrightness"
        var all = defaults.dictionary(forKey: name) ?? [:]
        all[key] = value
        defaults.set(all, forKey: name)
    }

    /// Screens where the colour is drawn with an overlay window instead of gamma (user choice).
    static var overlayScreens: Set<String> {
        get { Set(defaults.stringArray(forKey: "overlayScreens") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "overlayScreens") }
    }
}
