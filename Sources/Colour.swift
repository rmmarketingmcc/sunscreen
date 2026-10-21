import Foundation

/// Channel multipliers for the colour filter (1, 1, 1 = untouched).
struct Colour: Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let neutral = Colour(r: 1, g: 1, b: 1)
    var isNeutral: Bool { r > 0.999 && g > 0.999 && b > 0.999 }

    /// The colour for a point between full evening (0) and full day (1).
    static func at(fraction f: Double) -> Colour { kelvin(kelvinAt(fraction: f)) }

    static func kelvinAt(fraction f: Double) -> Double {
        Settings.nightKelvin + f * (Settings.dayKelvin - Settings.nightKelvin)
    }

    /// Blackbody colour, normalised so referenceKelvin = 1, 1, 1.
    static func kelvin(_ k: Double) -> Colour {
        func raw(_ k: Double) -> [Double] {
            let t = k / 100
            let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
            let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
            let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
            return [r, g, b].map { min(max($0, 0), 255) }
        }
        let ref = raw(Settings.referenceKelvin), c = raw(k)
        return Colour(r: min(c[0] / ref[0], 1), g: min(c[1] / ref[1], 1), b: min(c[2] / ref[2], 1))
    }

    /// How much blue light is left at this colour temperature, 0-100.
    static func bluePercent(_ k: Double) -> Int { Int((kelvin(k).b * 100).rounded()) }
}
