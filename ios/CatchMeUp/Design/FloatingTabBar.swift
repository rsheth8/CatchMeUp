import SwiftUI

// MARK: - FloatingTabBar
//
// A pill that hovers over the content instead of a full-width bar welded to
// the bottom edge. Same material, hairline and shadow as `FloatingControlShelf`
// so the record button, the grade buttons and the navigation all read as one
// family of floating controls.
//
// Only used in compact width. On iPad the system's sidebar is genuinely better
// than anything a custom bar would do, so that path is left alone.

struct FloatingTabBar: View {
    @Binding var selection: AppTab
    /// Rendered as a dot on Study. Zero shows nothing — a number that's always
    /// there stops meaning anything.
    var studyBadge: Int = 0

    /// Height of the pill itself. A transparent system bar reserves less scroll
    /// inset than an opaque one, so screens add this back to keep their last row
    /// clear of the pill.
    static let reservedHeight: CGFloat = 46

    @Namespace private var pill

    var body: some View {
        ZStack(alignment: .bottom) {
            fade
            bar
        }
    }

    /// The system bar underneath is transparent now, so scrolling content runs
    /// beneath the pill. Dissolving it — the same trick the record button on
    /// Recaps uses — makes that read as depth rather than as clipping.
    private var fade: some View {
        LinearGradient(
            stops: [
                .init(color: Color.groupBG.opacity(0), location: 0),
                .init(color: Color.groupBG.opacity(0.9), location: 0.7),
                .init(color: Color.groupBG.opacity(0.9), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        // Kept to the pill's own footprint. Any taller and it starts dimming
        // the controls that deliberately float above it.
        .frame(height: 74)
        .allowsHitTesting(false)
    }

    private var bar: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.ordered, id: \.self) { tab in
                item(tab)
            }
        }
        .padding(4)
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial,
                    in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous).strokeBorder(Color.hairline)
        }
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        .padding(.horizontal, Metric.gutter)
        // The overlay already starts above the home indicator, so this is only
        // a little air. Keeping the pill inside the footprint of the system bar
        // it covers is what stops it landing on scrolling content.
        .padding(.bottom, 6)
    }

    private func item(_ tab: AppTab) -> some View {
        let isOn = selection == tab

        return Button {
            guard selection != tab else { return }
            Haptics.tap(.soft)
            withAnimation(.quick) { selection = tab }
        } label: {
            HStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: isOn ? tab.symbolFilled : tab.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 22, height: 20)
                    if tab == .study, studyBadge > 0 {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                            .offset(x: 1, y: -1)
                            .transition(.scale)
                    }
                }
                // Only the current tab is named. Four labels at once is what
                // makes a bar tall; one keeps the pill short and still says
                // where you are.
                if isOn {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.55))
            .frame(width: isOn ? nil : 48)
            .padding(.horizontal, isOn ? 15 : 0)
            .padding(.vertical, 9)
            .background {
                if isOn {
                    Capsule(style: .continuous)
                        .fill(Color.brand.gradient)
                        .matchedGeometryEffect(id: "selected", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab == .study && studyBadge > 0 ? "\(studyBadge) due" : "")
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Tab metadata

extension AppTab {
    static let ordered: [AppTab] = [.library, .study, .brains, .settings]

    var title: String {
        switch self {
        case .library:  return "Recaps"
        case .study:    return "Study"
        case .brains:   return "Brains"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .library:  return "waveform"
        case .study:    return "graduationcap"
        case .brains:   return "brain"
        case .settings: return "gearshape"
        }
    }

    /// The filled variant for the selected state. `waveform` and `brain` have
    /// no `.fill` counterpart, so they stay as they are and let the pill carry
    /// the selection.
    var symbolFilled: String {
        switch self {
        case .library:  return "waveform"
        case .study:    return "graduationcap.fill"
        case .brains:   return "brain.head.profile.fill"
        case .settings: return "gearshape.fill"
        }
    }
}
