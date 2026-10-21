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

    /// 0 = full evening, 1 = full day, linear through twilight, including the user's own timing.
    static func dayFraction(_ p: Place, at date: Date) -> Double {
        fraction(p, at: date, evening: Settings.eveningOffsetMinutes, morning: Settings.morningOffsetMinutes)
    }

    // MARK: Own timing
    //
    // Each day has four moments: the evening fade starts (sun at +3 deg) and ends (-6 deg), the morning
    // fade starts (-6 deg) and ends (+3 deg). The user's timing moves the evening pair and the morning
    // pair by any number of minutes, past midnight too. Inside a fade the sun's own curve is used, so it
    // looks exactly like a natural sunset, just at another time.

    enum Moment: Int { case eveningStart, eveningEnd, morningStart, morningEnd }
    private struct Event { let time: Date; let moment: Moment }
    private static var momentCache: [String: [Event]] = [:]

    /// The sun's own four moments on the calendar day containing `day` (cached).
    private static func moments(_ p: Place, on day: Date) -> [Event] {
        let start = Calendar.current.startOfDay(for: day)
        let key = String(format: "%.3f,%.3f,%.0f", p.lat, p.lon, start.timeIntervalSince1970)
        if let cached = momentCache[key] { return cached }
        let hi = Settings.fullDayElevation, lo = Settings.fullNightElevation
        var events: [Event] = []
        var prevT = start
        var prevE = elevation(p, at: start)
        for minute in stride(from: 2, through: 24 * 60, by: 2) {
            let t = start.addingTimeInterval(Double(minute) * 60)
            let e = elevation(p, at: t)
            for (threshold, down, up) in [(hi, Moment.eveningStart, Moment.morningEnd), (lo, Moment.eveningEnd, Moment.morningStart)] {
                if prevE >= threshold && e < threshold { events.append(Event(time: crossing(p, prevT, t, threshold), moment: down)) }
                if prevE < threshold && e >= threshold { events.append(Event(time: crossing(p, prevT, t, threshold), moment: up)) }
            }
            prevT = t
            prevE = e
        }
        if momentCache.count > 60 { momentCache.removeAll() }
        momentCache[key] = events
        return events
    }

    /// Exact time (to ~1 s) the elevation passes `threshold` between a and b.
    private static func crossing(_ p: Place, _ a: Date, _ b: Date, _ threshold: Double) -> Date {
        var lo = a, hi = b
        let rising = elevation(p, at: b) > elevation(p, at: a)
        for _ in 0..<7 {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            if (elevation(p, at: mid) >= threshold) == rising { hi = mid } else { lo = mid }
        }
        return lo
    }

    /// The four moments around `date` (yesterday to tomorrow), moved by the user's timing, in time order.
    private static func shiftedMoments(_ p: Place, around date: Date, evening: Int, morning: Int) -> [Event] {
        let cal = Calendar.current
        let days = [-1, 0, 1].compactMap { cal.date(byAdding: .day, value: $0, to: date) }
        return days.flatMap { moments(p, on: $0) }.map { e in
            let minutes = (e.moment == .eveningStart || e.moment == .eveningEnd) ? evening : morning
            return Event(time: e.time.addingTimeInterval(Double(minutes) * 60), moment: e.moment)
        }.sorted { $0.time < $1.time }
    }

    static func fraction(_ p: Place, at date: Date, evening: Int, morning: Int) -> Double {
        guard let last = shiftedMoments(p, around: date, evening: evening, morning: morning).last(where: { $0.time <= date }) else {
            return sunFraction(p, at: date)   // polar day or night: no sunrise or sunset to move
        }
        switch last.moment {
        case .eveningStart: return sunFraction(p, at: date.addingTimeInterval(-Double(evening) * 60))
        case .eveningEnd: return 0
        case .morningStart: return sunFraction(p, at: date.addingTimeInterval(-Double(morning) * 60))
        case .morningEnd: return 1
        }
    }

    /// Whether this timing still leaves a real day and night (evening and morning can't cross).
    static func timingAllowed(_ p: Place, evening: Int, morning: Int, around date: Date) -> Bool {
        let events = shiftedMoments(p, around: date, evening: evening, morning: morning)
        let order: [Moment] = [.eveningStart, .eveningEnd, .morningStart, .morningEnd]
        for (a, b) in zip(events, events.dropFirst()) {
            guard let i = order.firstIndex(of: a.moment), order[(i + 1) % 4] == b.moment else { return false }
            // At least 30 minutes of full night and of full day.
            if (a.moment == .eveningEnd || a.moment == .morningEnd) && b.time.timeIntervalSince(a.time) < 30 * 60 { return false }
        }
        return true
    }

    /// The sun alone, without the user's timing.
    static func sunFraction(_ p: Place, at date: Date) -> Double {
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
        var seenEvening = dayFraction(p, at: date) < 1
        for minute in stride(from: 2, through: 48 * 60, by: 2) {
            let t = date.addingTimeInterval(Double(minute) * 60)
            if dayFraction(p, at: t) < 1 { seenEvening = true }
            else if seenEvening { return t }
        }
        return nil
    }

    /// When the evening filter next starts fading in (with the user's timing). nil if it's already on.
    static func nextEveningStart(_ p: Place, after date: Date) -> Date? {
        guard dayFraction(p, at: date) >= 1 else { return nil }
        for minute in stride(from: 2, through: 48 * 60, by: 2) {
            let t = date.addingTimeInterval(Double(minute) * 60)
            if dayFraction(p, at: t) < 1 { return t }
        }
        return nil
    }
}
