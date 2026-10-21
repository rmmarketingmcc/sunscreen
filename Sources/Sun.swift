import Foundation

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

    /// 0 = full evening, 1 = full day, linear through twilight.
    static func dayFraction(_ p: Place, at date: Date) -> Double {
        let span = Settings.fullDayElevation - Settings.fullNightElevation
        return min(max((elevation(p, at: date) - Settings.fullNightElevation) / span, 0), 1)
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

    /// Sunrise and sunset on the given day (sun centre at -0.833 deg), 2-minute resolution.
    static func events(_ p: Place, on day: Date) -> (rise: Date?, set: Date?) {
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
