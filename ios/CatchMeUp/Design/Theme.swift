import SwiftUI
import UIKit

// MARK: - Palette
//
// Pulled straight off the app icon: a deep teal ground with a seafoam
// "lit node". Lecture material gets a warm amber so the two modes are
// never ambiguous at a glance.

extension Color {
    static let brand      = Color(red: 0.055, green: 0.486, blue: 0.525)
    static let brandDeep  = Color(red: 0.020, green: 0.280, blue: 0.320)
    static let brandLight = Color(red: 0.160, green: 0.690, blue: 0.720)
    /// Seafoam — the lit node in the icon.
    static let mint       = Color(red: 0.380, green: 0.830, blue: 0.750)
    static let amber      = Color(red: 0.760, green: 0.450, blue: 0.120)
    static let amberLight = Color(red: 0.920, green: 0.660, blue: 0.280)

    static var brandSoft: Color { brand.opacity(0.12) }

    static var cardBG:   Color { Color(.secondarySystemGroupedBackground) }
    static var groupBG:  Color { Color(.systemGroupedBackground) }
    /// Hairline that reads on both light and dark surfaces.
    static var hairline: Color { Color.primary.opacity(0.055) }
}

extension Mode {
    var accent: Color { self == .meeting ? .brand : .amber }
    var accentLight: Color { self == .meeting ? .brandLight : .amberLight }

    var gradient: LinearGradient {
        LinearGradient(colors: [accentLight, accent],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Wash used behind icon tiles and chips.
    var wash: Color { accent.opacity(0.14) }

    /// One-word label for dense contexts.
    var shortTitle: String { self == .meeting ? "Meeting" : "Lecture" }
}

// MARK: - Metrics

enum Metric {
    static let card: CGFloat = 20      // card corner radius
    static let tile: CGFloat = 14      // icon tile corner radius
    static let gutter: CGFloat = 16
    static let rowGap: CGFloat = 10
}

// MARK: - Motion

extension Animation {
    static var quick: Animation { .snappy(duration: 0.28, extraBounce: 0.02) }
    static var gentle: Animation { .smooth(duration: 0.45) }
}

// MARK: - Ambient background
//
// Two very soft colour blooms over the system grouped background. Gives
// screens depth without competing with content — it sits behind everything
// and never scrolls.

struct AmbientBackground: View {
    var tint: Color = .brand
    var intensity: Double = 1

    var body: some View {
        ZStack {
            Color.groupBG
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [tint.opacity(0.20 * intensity), .clear],
                                             center: .center, startRadius: 0, endRadius: w * 0.7))
                        .frame(width: w * 1.6, height: w * 1.6)
                        .offset(x: -w * 0.45, y: -w * 0.95)
                    Circle()
                        .fill(RadialGradient(colors: [Color.mint.opacity(0.14 * intensity), .clear],
                                             center: .center, startRadius: 0, endRadius: w * 0.55))
                        .frame(width: w * 1.1, height: w * 1.1)
                        .offset(x: w * 0.5, y: -w * 0.45)
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - Dates

extension Date {
    var relativeShort: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: self, relativeTo: .now)
    }

    /// "Today", "Yesterday", "Tue", or "12 Mar" — for row subtitles.
    var libraryStamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if let week = cal.date(byAdding: .day, value: -6, to: .now), self > week {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Durations

func durationText(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
