import SwiftUI

// MARK: - Palette

extension Color {
    /// Brand teal — "signal captured". Works on both light and dark grounds.
    static let brand = Color(red: 0.055, green: 0.486, blue: 0.525)
    static let brandDeep = Color(red: 0.035, green: 0.360, blue: 0.400)
    static let brandSoft = Color(red: 0.055, green: 0.486, blue: 0.525).opacity(0.12)

    static var cardBG: Color { Color(.secondarySystemGroupedBackground) }
    static var groupBG: Color { Color(.systemGroupedBackground) }
}

extension Mode {
    var accent: Color {
        switch self {
        case .meeting: return .brand
        case .lecture: return Color(red: 0.60, green: 0.36, blue: 0.10) // amber
        }
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Section label

struct SectionLabel: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(text.uppercased())
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .tracking(0.6)
    }
}

// MARK: - Pill

struct Pill: View {
    let text: String
    var symbol: String?
    var tint: Color = .brand

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }
}

// MARK: - Big action button

struct BigActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var filled = true
    var tint: Color = .brand
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(filled ? .white.opacity(0.85) : Color.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).opacity(0.5)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .foregroundStyle(filled ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.cardBG))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.brand.opacity(0.7))
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

// MARK: - Mode switch

struct ModeSwitch: View {
    @Binding var mode: Mode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Mode.allCases) { m in
                Button {
                    withAnimation(.snappy) { mode = m }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: m.symbol).font(.headline)
                        Text(m.title).font(.subheadline.weight(.semibold))
                        Text(m.blurb).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(mode == m ? m.accent.opacity(0.14) : Color.cardBG)
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(mode == m ? m.accent : .clear, lineWidth: 1.5)
                            }
                    }
                    .foregroundStyle(mode == m ? m.accent : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Relative date

extension Date {
    var relativeShort: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: self, relativeTo: .now)
    }
}
