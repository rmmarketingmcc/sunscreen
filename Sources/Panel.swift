import AppKit
import SwiftUI

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

    /// "Filter turns on at 18.00 · in 4 h" and friends: what happens next, with an icon.
    static func nextLine(_ s: Snapshot) -> (String, String) {
        if s.override != .auto, let until = s.overrideUntil {
            return ("arrow.uturn.backward.circle", "Back to Auto \(at(until, from: s.now)) · in \(self.until(until, from: s.now))")
        }
        if let on = s.filterOn {
            return ("moon.stars", "Filter turns on \(at(on, from: s.now)) · in \(self.until(on, from: s.now))")
        }
        if let off = s.filterOff {
            return ("sun.max", "Filter on now · normal again \(at(off, from: s.now))")
        }
        return ("circle", "No sunrise or sunset here today")
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
            if let problem = s.problem { ProblemCard(problem: problem, app: app) }
            if app.update != nil { UpdateCard(app: app) }
            if !app.whatsNew.isEmpty { WhatsNewCard(app: app) }
            ModeCard(s: s, app: app)
            if Settings.showAllSettings {
                TodayCard(s: s)
                EveningCard(app: app)
                DaytimeCard(app: app)
                BrightnessCard(s: s, app: app)
                OptionsCard(app: app)
            } else {
                EveningCard(app: app, compact: true, status: Fmt.nextLine(s))
            }
            MoreButton(app: app)
            FooterView(app: app)
        }
        .padding(14)
        .frame(width: 340)
        .fontDesign(.rounded)
    }
}

// MARK: - Building blocks

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

struct PillButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Palette.warm)).foregroundStyle(.white)
                .contentShape(Capsule())
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

// MARK: - Cards

struct HeaderView: View {
    let s: Snapshot
    let app: App

    private var icon: (String, LinearGradient) {
        switch s.mode {
        case .day, .appPause, .bright: return ("sun.max.fill", Palette.day)
        default: return ("moon.stars.fill", Palette.warm)
        }
    }
    private var title: String {
        switch s.mode {
        case .day: return "Daytime"
        case .evening: return "Evening mode"
        case .fading: return s.position > 0.5 ? "Sunset" : "Sunrise"
        case .bright: return "Bright"
        case .dark: return "Dark"
        case .preview: return "Preview"
        case .appPause: return "Normal colours"
        }
    }
    private var subtitle: String {
        switch s.mode {
        case .day: return "Normal colours"
        case .evening: return "Blue light filtered"
        case .fading: return s.position > 0.5 ? "Filter fading in" : "Filter fading out"
        case .bright: return "Normal colours and brightness"
        case .dark: return "Evening look, right now"
        case .preview: return "Showing what you picked"
        case .appPause: return "While \(s.appPause ?? "this app") is in front"
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
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
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

struct ProblemCard: View {
    let problem: Problem
    let app: App

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(Palette.warm).frame(width: 28, height: 28)
                    Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(problem.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Dismiss") { app.dismissProblem(problem.id) }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                if problem.reportable { PillButton(title: "Report it") { app.report(problem) } }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.14)))
    }
}

struct UpdateCard: View {
    let app: App

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(Palette.warm).frame(width: 32, height: 32)
                Image(systemName: "arrow.down").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available: \(app.update?.version ?? "")").font(.system(size: 13, weight: .semibold))
                ForEach(Array((app.update?.notes ?? []).prefix(3).enumerated()), id: \.offset) { _, note in
                    Text("• \(note)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if app.updateStatus == "Updating..." {
                Text("Updating...").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            } else {
                PillButton(title: "Update") { app.installUpdate() }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.14)))
    }
}

struct TodayCard: View {
    let s: Snapshot

    private var nextLine: (String, String) { Fmt.nextLine(s) }

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
    let app: App
    var compact = false
    var status: (String, String)? = nil

    /// The evening setting in words people use: how much blue light is left (Kelvin stays internal).
    private var blue: Double {
        min(max(Colour.blueShare(Settings.nightKelvin), Colour.eveningBlueRange.lowerBound), Colour.eveningBlueRange.upperBound)
    }

    private var advice: String {
        let p = blue.rounded()
        if p <= 0 { return "Max sleep: no blue light at all, like anti-blue-light glasses. Best for the last 2-3 hours before bed." }
        if p <= 20 { return "Very little blue light. Almost as good for sleep as Max sleep." }
        if p <= 45 { return "Balanced: about as warm as Night Shift at its strongest." }
        return "Natural: colours look almost normal, but most of the blue light gets through."
    }

    var body: some View {
        let p = blue.rounded()
        Card {
            HStack {
                Text("Evening colour").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(verbatim: "\(Int(p))% blue light").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Chip(title: "Max sleep", detail: "0% blue", selected: p <= 2, recommended: true) { app.setEveningBlue(0) }
                Chip(title: "Balanced", detail: "35% blue", selected: abs(p - 35) <= 2) { app.setEveningBlue(35) }
                Chip(title: "Natural", detail: "75% blue", selected: p >= 73) { app.setEveningBlue(75) }
            }
            if compact {
                if let status {
                    Label(status.1, systemImage: status.0).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
            VStack(spacing: 3) {
                SoftSlider(value: Binding(get: { blue }, set: { app.setEveningBlue($0, dragging: true) }),
                           range: Colour.eveningBlueRange, step: 5)
                HStack {
                    Text("Max sleep")
                    Spacer()
                    Text("Natural")
                }
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
            }
            Text(advice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Folds the panel open (all settings) or closed (just the essentials).
struct MoreButton: View {
    let app: App

    var body: some View {
        Button { app.toggleAllSettings() } label: {
            HStack(spacing: 5) {
                Text(Settings.showAllSettings ? "Fewer settings" : "All settings")
                Image(systemName: Settings.showAllSettings ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WhatsNewCard: View {
    let app: App

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Palette.warm)
                Text("What's new in \(app.whatsNew.first?.version ?? Updater.current)").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            ForEach(Array(app.whatsNew.flatMap(\.notes).prefix(5).enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(note).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
            }
            HStack(spacing: 12) {
                Button("All changes") { app.openChangelog() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                PillButton(title: "Got it") { app.dismissWhatsNew() }
            }
            .font(.system(size: 12))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.14)))
    }
}

struct BrightnessCard: View {
    let s: Snapshot
    let app: App

    var body: some View {
        Card {
            CardTitle(title: "Brightness", trailing: s.editingEvening ? "Evening" : "Daytime")
            ForEach(s.rows) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name).font(.system(size: 12)).lineLimit(1)
                        if !row.note.isEmpty { Text(row.note).font(.system(size: 9)).foregroundStyle(.tertiary) }
                    }
                    .frame(width: 92, alignment: .leading)
                    SoftSlider(value: Binding(get: { Double(row.value) }, set: { app.setBrightness(row.id, Int($0)) }),
                               range: 0...100, step: 1)
                    Text(verbatim: "\(row.value)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
                .contextMenu {
                    if !row.isBuiltin {
                        Button(row.overlay ? "Use the normal colour filter" : "Colour not changing on this screen? Use overlay") {
                            app.toggleOverlay(row.key)
                        }
                    }
                }
            }
            Text(s.editingEvening
                 ? "Remembered as your evening brightness, per screen."
                 : "Remembered per screen. To set the evening level now, switch to Dark at the top and adjust.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DaytimeCard: View {
    let app: App

    var body: some View {
        let k = Settings.dayKelvin
        Card {
            CardTitle(title: "Daytime colour", trailing: "Blue light \(Colour.bluePercent(k))%")
            HStack(spacing: 6) {
                Chip(title: "Daylight", selected: k == 6500, recommended: true, style: Palette.day) { app.setDayKelvin(6500) }
                Chip(title: "Soft", selected: k == 5500, style: Palette.day) { app.setDayKelvin(5500) }
                Chip(title: "Warm", selected: k == 4500, style: Palette.day) { app.setDayKelvin(4500) }
            }
            Text(k >= 6500
                 ? "Recommended: blue light by day keeps you alert and helps you fall asleep at night."
                 : "A light filter all day. Daylight is better for your sleep rhythm, and HDR video needs it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The big switch: follow the sun, or force bright / dark right now.
struct ModeCard: View {
    let s: Snapshot
    let app: App

    private var caption: String {
        switch s.override {
        case .auto:
            return "Follows the sun. Want it bright or dark right now? Tap Bright or Dark."
        case .bright:
            let until = s.overrideUntil.map { Fmt.at($0, from: s.now) } ?? ""
            return "Bright until sunset (\(until)), then back to Auto. ⌃⌥⌘P switches it too."
        case .dark:
            let until = s.overrideUntil.map { Fmt.at($0, from: s.now) } ?? ""
            return "Dark until sunrise (\(until)), then back to Auto."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ModeButton(title: "Auto", symbol: "circle.lefthalf.filled", selected: s.override == .auto,
                           style: LinearGradient(colors: [Color(red: 0.55, green: 0.80, blue: 1.0), Color(red: 0.96, green: 0.42, blue: 0.24)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing)) { app.setMode(.auto) }
                ModeButton(title: "Bright", symbol: "sun.max.fill", selected: s.override == .bright, style: Palette.day) { app.setMode(.bright) }
                ModeButton(title: "Dark", symbol: "moon.fill", selected: s.override == .dark, style: Palette.warm) { app.setMode(.dark) }
            }
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ModeButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let style: LinearGradient
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AnyShapeStyle(style) : AnyShapeStyle(Color.primary.opacity(0.07))))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A switch with its label: the whole row is clickable.
struct ToggleRow: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? AnyShapeStyle(Palette.warm) : AnyShapeStyle(Color.primary.opacity(0.18)))
                        .frame(width: 30, height: 18)
                    Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                }
                .animation(.easeOut(duration: 0.15), value: isOn)
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct OptionsCard: View {
    let app: App

    var body: some View {
        Card {
            ToggleRow(title: "Normal colours in photo and video apps", isOn: Settings.pauseInCreativeApps) { app.toggleCreativePause() }
            ToggleRow(title: "Start at login", isOn: app.startsAtLogin) { app.setStartAtLogin(!app.startsAtLogin) }
        }
    }
}

struct FooterView: View {
    let app: App

    var body: some View {
        HStack(spacing: 7) {
            Spacer()
            Button("Report a problem") { app.report(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
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
