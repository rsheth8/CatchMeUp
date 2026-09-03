import SwiftUI

// MARK: - SessionSummaryView
//
// What just happened, and the one useful thing to do next. The calibration
// line is the point: a student who scored 60% while feeling 90% sure has
// learned something more valuable than the six answers they got right.

struct SessionSummaryView: View {
    let summary: SessionSummary
    let brainID: UUID?
    let onDone: () -> Void

    @Environment(StudyStore.self) private var study
    @State private var drilling = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                scoreRing
                headline
                stats
                calibrationLine
                if !summary.missedItemIDs.isEmpty { missedList }
                actions
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
        .fullScreenCover(isPresented: $drilling) {
            ReviewSessionView(mode: .drill, brainID: brainID, limit: 10)
        }
    }

    // MARK: Score

    private var scoreRing: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 14)
            Circle()
                .trim(from: 0, to: summary.accuracy)
                .stroke(ringTint.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(summary.accuracyText)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("\(summary.correct) of \(summary.answered)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 156, height: 156)
        .padding(.top, 6)
    }

    private var ringTint: Color {
        switch summary.accuracy {
        case 0.8...:    return .brand
        case 0.55..<0.8: return .amber
        default:        return .orange
        }
    }

    private var headline: some View {
        VStack(spacing: 5) {
            Text(headlineText).font(.title3.weight(.semibold))
            Text(subheadText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
    }

    private var headlineText: String {
        switch summary.accuracy {
        case 0.9...:     return "Sharp."
        case 0.7..<0.9:  return "Solid session."
        case 0.4..<0.7:  return "Useful session."
        default:         return "That was the hard stuff."
        }
    }

    /// Deliberately reframes a low score. Missing things during practice is the
    /// mechanism, not the failure — a student who quits because the number
    /// looked bad loses the whole effect.
    private var subheadText: String {
        if summary.accuracy < 0.55 {
            return "Struggling to recall is what builds the memory. These come back sooner."
        }
        if summary.mode == .practiceExam {
            return "Practice run — your review schedule is untouched."
        }
        return "Each of these is now scheduled for the day you'd otherwise start forgetting it."
    }

    // MARK: Stats

    private var stats: some View {
        HStack(spacing: 10) {
            statTile(value: "\(summary.answered)", label: "answered", symbol: "checkmark.circle")
            statTile(value: minutesText, label: "spent", symbol: "clock")
            statTile(value: "\(study.streak)", label: "day streak", symbol: "flame")
        }
    }

    private var minutesText: String {
        let minutes = Int((summary.seconds / 60).rounded())
        return minutes < 1 ? "<1m" : "\(minutes)m"
    }

    private func statTile(value: String, label: String, symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.bold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cardBG)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.hairline)
                }
        }
    }

    // MARK: Calibration

    @ViewBuilder
    private var calibrationLine: some View {
        if let error = summary.calibrationError {
            Card(tint: error > 0.35 ? .orange : .brand) {
                VStack(alignment: .leading, spacing: 7) {
                    Label(error > 0.35 ? "Your confidence was off" : "You read yourself well",
                          systemImage: "gauge.with.needle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(error > 0.35 ? Color.orange : Color.brand)
                    Text(error > 0.35
                         ? "You felt sure about things you couldn't recall. That gap is normal — it's why quizzing beats rereading, which only ever feels productive."
                         : "Your sense of what you knew matched what you could actually recall. That judgement is worth as much as the facts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Missed

    private var missedList: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader("Worth another look", symbol: "target")
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    let items = summary.missedItemIDs.compactMap { study.item($0) }.prefix(5)
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.concept.isEmpty ? item.prompt : item.concept)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(item.sourceTitle)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 8)
                        if idx < items.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 10) {
            if !summary.missedItemIDs.isEmpty {
                Button {
                    Haptics.tap()
                    drilling = true
                } label: {
                    Label("Drill what you missed", systemImage: "target")
                }
                .buttonStyle(.prominent(.amber))
            }
            Button("Done", action: onDone)
                .buttonStyle(.soft())
        }
        .padding(.top, 4)
    }
}
