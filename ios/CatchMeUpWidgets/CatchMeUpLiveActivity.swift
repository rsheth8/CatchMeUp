import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CatchMeUpWidgets: WidgetBundle {
    var body: some Widget {
        CatchMeUpLiveActivity()
    }
}

struct CatchMeUpLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CatchMeUpActivityAttributes.self) { context in
            LockScreenActivityView(context: context)
                .activityBackgroundTint(Color(red: 0.02, green: 0.18, blue: 0.20))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "catchmeup://recap/\(context.attributes.recordingID)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent(context))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    progressLabel(context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(context.attributes.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        HStack {
                            Text(subtitle(context))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            if !context.state.isComplete, !context.state.isPaused,
                               context.state.isIndeterminate != true {
                                ProgressView(value: context.state.progress)
                                    .tint(accent(context))
                                    .frame(width: 78)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(voiceOverLabel(context))
                }
            } compactLeading: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(accent(context))
            } compactTrailing: {
                progressLabel(context)
            } minimal: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(accent(context))
            }
            .widgetURL(URL(string: "catchmeup://recap/\(context.attributes.recordingID)"))
            .keylineTint(accent(context))
        }
    }

    @ViewBuilder
    private func progressLabel(_ context: ActivityViewContext<CatchMeUpActivityAttributes>) -> some View {
        if context.state.isComplete || context.state.isPaused || context.state.isIndeterminate == true {
            Image(systemName: context.state.symbol)
                .foregroundStyle(accent(context))
        } else {
            Text("\(Int(context.state.progress * 100))%")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(accent(context))
        }
    }

    private func accent(_ context: ActivityViewContext<CatchMeUpActivityAttributes>) -> Color {
        context.attributes.mode == "lecture"
            ? Color(red: 0.92, green: 0.66, blue: 0.28)
            : Color(red: 0.38, green: 0.83, blue: 0.75)
    }

    private func subtitle(_ context: ActivityViewContext<CatchMeUpActivityAttributes>) -> String {
        guard let eta = context.state.etaText, !context.state.isComplete else {
            return context.state.stage
        }
        return "\(context.state.stage) · \(eta)"
    }

    private func voiceOverLabel(_ context: ActivityViewContext<CatchMeUpActivityAttributes>) -> String {
        var parts = [context.attributes.title, context.state.stage]
        if !context.state.isComplete, !context.state.isPaused, context.state.isIndeterminate != true {
            parts.append("\(Int(context.state.progress * 100)) percent")
        }
        if let eta = context.state.etaText { parts.append(eta) }
        return parts.joined(separator: ", ")
    }
}

private struct LockScreenActivityView: View {
    let context: ActivityViewContext<CatchMeUpActivityAttributes>

    private var tint: Color {
        context.attributes.mode == "lecture"
            ? Color(red: 0.92, green: 0.66, blue: 0.28)
            : Color(red: 0.38, green: 0.83, blue: 0.75)
    }

    private var showsBar: Bool {
        !context.state.isComplete && !context.state.isPaused && context.state.isIndeterminate != true
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: context.state.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(context.attributes.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(context.state.stage)
                    if let eta = context.state.etaText, showsBar {
                        Text("·")
                        Text(eta).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                // A determinate bar is the honest shape here: the percentage is
                // real, and a spinner would imply we have no idea.
                if showsBar {
                    ProgressView(value: context.state.progress)
                        .tint(tint)
                }
            }

            if context.state.isComplete {
                Text("Ready")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
            } else if showsBar {
                Text("\(Int(context.state.progress * 100))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(context.attributes.title)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts = [context.state.stage]
        if showsBar {
            parts.append("\(Int(context.state.progress * 100)) percent")
            if let eta = context.state.etaText { parts.append(eta) }
        }
        return parts.joined(separator: ", ")
    }
}
