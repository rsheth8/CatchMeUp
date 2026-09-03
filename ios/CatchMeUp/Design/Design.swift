import SwiftUI

// Shared building blocks. Everything visual in the app is assembled from
// these so spacing, radii and depth stay consistent screen to screen.

// MARK: - Card

struct Card<Content: View>: View {
    var padding: CGFloat = Metric.gutter
    var radius: CGFloat = Metric.card
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.cardBG)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(tint?.opacity(0.25) ?? Color.hairline, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
            }
    }
}

// MARK: - Section header

struct SectionHeader<Accessory: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.caption2.weight(.bold))
            }
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.7)
            Spacer(minLength: 8)
            accessory
        }
        .foregroundStyle(.secondary)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String, symbol: String? = nil) {
        self.init(title: title, symbol: symbol) { EmptyView() }
    }
}

// MARK: - Chip

struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = .brand
    var filled = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2.weight(.bold)) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
        .background {
            Capsule().fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)))
        }
    }
}

// MARK: - Filter chip

struct FilterChip: View {
    let title: String
    var symbol: String?
    let isOn: Bool
    var tint: Color = .brand
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            withAnimation(.quick) { action() }
        } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.caption.weight(.semibold)) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .foregroundStyle(isOn ? .white : Color.primary.opacity(0.8))
            .background {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.cardBG))
                    .overlay { Capsule().strokeBorder(isOn ? .clear : Color.hairline) }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Icon tile

struct IconTile: View {
    let symbol: String
    var tint: Color = .brand
    var size: CGFloat = 42
    var filled = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.14)))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            }
    }
}

// MARK: - Buttons

struct ProminentButtonStyle: ButtonStyle {
    var tint: Color = .brand
    var shape: AnyShape = AnyShape(Capsule())

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(tint.gradient, in: shape)
            .shadow(color: tint.opacity(0.30), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.quick, value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .brand

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.cardBG, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.hairline) }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ProminentButtonStyle {
    static func prominent(_ tint: Color = .brand) -> ProminentButtonStyle {
        ProminentButtonStyle(tint: tint)
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static func soft(_ tint: Color = .brand) -> SoftButtonStyle { SoftButtonStyle(tint: tint) }
}

// MARK: - Empty state

struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .brand
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 62)
            VStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 28)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String, tint: Color = .brand) {
        self.init(symbol: symbol, title: title, message: message, tint: tint) { EmptyView() }
    }
}

// MARK: - Waveform

/// Live level meter / idle waveform. Pass a rolling buffer of 0…1 levels.
struct WaveBars: View {
    var levels: [Double]
    var tint: Color = .brand
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3
    var minHeight: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(tint.opacity(0.35 + 0.65 * level))
                        .frame(width: barWidth,
                               height: max(minHeight, h * CGFloat(0.12 + 0.88 * level)))
                }
            }
            .frame(width: geo.size.width, height: h, alignment: .center)
        }
    }
}

/// The five-bar mark from the app icon, optionally breathing.
struct WaveMark: View {
    var tint: Color = .brand
    var animated = false
    @State private var phase = false

    private let base: [CGFloat] = [0.34, 0.62, 1.0, 0.55, 0.40]
    private let alt: [CGFloat]  = [0.52, 0.34, 0.72, 1.0, 0.46]

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let barW = w * 0.108
            HStack(spacing: (w - barW * 5) / 4) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(tint)
                        .frame(width: barW, height: h * (phase ? alt[i] : base[i]))
                }
            }
            .frame(width: w, height: h)
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
        }
    }
}

// MARK: - Brand mark
//
// The "Constellation C" from the app icon, redrawn in SwiftUI so onboarding
// and empty states can carry the same identity as the home-screen tile.

struct BrandMark: View {
    var size: CGFloat = 108
    var animated = false

    @State private var appeared = false

    private let degs: [Double] = [56, 118, 180, 242, 304]
    private let lit = 2

    var body: some View {
        Canvas { ctx, canvas in
            let s = min(canvas.width, canvas.height)
            let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let r = 0.325 * s
            let pts = degs.map { d in
                CGPoint(x: c.x + r * cos(d * .pi / 180), y: c.y - r * sin(d * .pi / 180))
            }
            let dorm = 0.165 * s
            let litSize = 0.275 * s
            let inset = dorm / 2 + 0.018 * s

            // connectors
            var line = Path()
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                var dx = b.x - a.x, dy = b.y - a.y
                let n = max(0.0001, (dx * dx + dy * dy).squareRoot())
                dx /= n; dy /= n
                line.move(to: CGPoint(x: a.x + dx * inset, y: a.y + dy * inset))
                line.addLine(to: CGPoint(x: b.x - dx * inset, y: b.y - dy * inset))
            }
            ctx.stroke(line, with: .color(.primary.opacity(0.22)), lineWidth: 0.014 * s)

            // dormant nodes, fading toward the tips — neutral so they read on
            // either ground, the way the off-white nodes do on the icon
            for (i, p) in pts.enumerated() where i != lit {
                let alpha = abs(i - lit) == 1 ? 0.34 : 0.18
                let rect = CGRect(x: p.x - dorm / 2, y: p.y - dorm / 2, width: dorm, height: dorm)
                ctx.fill(Path(roundedRect: rect, cornerRadius: dorm * 0.28),
                         with: .color(.primary.opacity(alpha)))
            }

            // the lit node
            let rect = CGRect(x: pts[lit].x - litSize / 2, y: pts[lit].y - litSize / 2,
                              width: litSize, height: litSize)
            ctx.fill(Path(roundedRect: rect, cornerRadius: litSize * 0.28),
                     with: .linearGradient(Gradient(colors: [.brandLight, .brand]),
                                           startPoint: CGPoint(x: rect.minX, y: rect.minY),
                                           endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))

            // five-bar waveform inside it
            let heights: [Double] = [0.34, 0.62, 1.0, 0.55, 0.40]
            let barW = litSize * 0.108, step = litSize * 0.188
            var x = pts[lit].x - step * 2
            for hh in heights {
                let bh = litSize * 0.52 * hh
                let bar = CGRect(x: x - barW / 2, y: pts[lit].y - bh / 2, width: barW, height: bh)
                ctx.fill(Path(roundedRect: bar, cornerRadius: barW / 2), with: .color(.white))
                x += step
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(appeared ? 1 : 0.86)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            guard animated else { appeared = true; return }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) { appeared = true }
        }
    }
}

// MARK: - Shimmer (used while notes are being written)

struct ShimmerLine: View {
    var width: CGFloat?
    @State private var move = false

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.07))
            .frame(width: width, height: 11)
            .overlay {
                GeometryReader { geo in
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, Color.primary.opacity(0.09), .clear],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: move ? geo.size.width : -geo.size.width * 0.5)
                }
            }
            .clipShape(Capsule())
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { move = true }
            }
    }
}
