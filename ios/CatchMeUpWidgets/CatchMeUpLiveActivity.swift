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
                            Text(context.state.stage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !context.state.isComplete {
                                ProgressView(value: context.state.progress)
                                    .tint(accent(context))
                                    .frame(width: 78)
                            }
                        }
                    }
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
        if context.state.isComplete {
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
}

private struct LockScreenActivityView: View {
    let context: ActivityViewContext<CatchMeUpActivityAttributes>

    private var tint: Color {
        context.attributes.mode == "lecture"
            ? Color(red: 0.92, green: 0.66, blue: 0.28)
            : Color(red: 0.38, green: 0.83, blue: 0.75)
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: context.state.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(context.state.stage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if context.state.isComplete {
                Text("Ready")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
            } else {
                ProgressView(value: context.state.progress)
                    .progressViewStyle(.circular)
                    .tint(tint)
            }
        }
        .padding(16)
    }
}
