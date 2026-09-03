import SwiftUI

// MARK: - PrequestionView
//
// The warm-up in front of a recap you haven't read yet. See `Prequestions` for
// why it exists and why it's deliberately not scored.
//
// It is intentionally a lighter screen than `ReviewSessionView`: no confidence
// rating (a prediction about material you've never seen measures nothing), no
// audio, no grade buttons, no schedule. Two taps and you're reading.

struct PrequestionView: View {
    let recording: Recording
    let items: [StudyItem]
    /// Handed back so the caller can record the outcome and let the reader
    /// straight through to the notes.
    let onFinish: (_ asked: Int, _ correct: Int) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var typed = ""
    @State private var result: Grading.Result?
    @State private var asked = 0
    @State private var correct = 0
    @State private var finished = false

    @FocusState private var answerFocused: Bool

    private var tint: Color { recording.mode.accent }
    private var current: StudyItem? { items.indices.contains(index) ? items[index] : nil }
    private var isLast: Bool { index >= items.count - 1 }

    var body: some View {
        NavigationStack {
            Group {
                if finished || current == nil {
                    closing
                } else if let item = current {
                    question(item)
                }
            }
            .background(AmbientBackground(tint: tint))
            .navigationTitle("Before you read")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Never a modal trap in front of someone's own notes. Dropped
                // entirely on the closing pane rather than hidden, so no empty
                // button shape is left behind.
                if !finished {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Skip") { close() }
                    }
                }
                // No centre item: the title stays visible instead. This sheet
                // arrives unasked, and "Before you read" is the whole
                // explanation of why it's there. Position lives on the card.
            }
        }
        .interactiveDismissDisabled(false)
    }

    // MARK: One question

    private func question(_ item: StudyItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if index == 0 && result == nil {
                    Text(Prequestions.intro)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }

                promptCard(item)

                if let result {
                    reveal(item, result)
                } else {
                    answerBox
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(.gentle, value: result)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { bottomBar(item) }
    }

    private func promptCard(_ item: StudyItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Chip(text: item.kind.title, symbol: item.kind.symbol, tint: tint)
                Chip(text: "Warm-up", symbol: "sunrise", tint: .mint, filled: true)
                Spacer(minLength: 0)
                if items.count > 1 {
                    ProgressPips(total: items.count, done: index, tint: tint)
                }
            }
            MarkdownText(item.prompt, style: promptStyle)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .fill(Color.cardBG)
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                        .strokeBorder(Color.hairline)
                }
                .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        }
        .padding(.top, 8)
    }

    private var promptStyle: MarkdownStyle {
        var style = MarkdownStyle.note
        style.tint = tint
        return style
    }

    private var answerBox: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader("Your guess", symbol: "pencil")
            ZStack(alignment: .topLeading) {
                if typed.isEmpty {
                    Text("A guess is fine. So is half an answer.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $typed)
                    .font(.subheadline)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 92)
                    .focused($answerFocused)
            }
            .padding(9)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cardBG)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(answerFocused ? tint.opacity(0.5) : Color.hairline)
                    }
            }
        }
    }

    // MARK: The reveal
    //
    // Feedback is what turns a wrong guess into an advantage, so the answer is
    // always shown — but the verdict is worded as a heads-up about the reading
    // ahead, not a mark. "Not quite" before you've been taught something is not
    // information about the reader.

    private func reveal(_ item: StudyItem, _ result: Grading.Result) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: result.verdict.isRecall ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(result.verdict.isRecall ? Color.mint : tint)
                Text(headline(for: result.verdict))
                    .font(.headline)
                    .foregroundStyle(result.verdict.isRecall ? Color.mint : tint)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("From your lecture", symbol: "text.quote")
                MarkdownText(item.revealText, style: promptStyle)
            }

            if !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("You guessed", symbol: "pencil")
                    Text(typed)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .fill(Color.cardBG)
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                        .strokeBorder(Color.hairline)
                }
        }
    }

    private func headline(for verdict: Grading.Verdict) -> String {
        switch verdict {
        case .pass:    return "You had it"
        case .partial: return "Part of it"
        case .miss:    return "Watch for this one"
        case .blank:   return "Here it is"
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private func bottomBar(_ item: StudyItem) -> some View {
        VStack(spacing: 8) {
            if result == nil {
                Button {
                    Haptics.tap()
                    check(item)
                } label: {
                    Text(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "I don't know yet" : "Show me")
                }
                .buttonStyle(.prominent(tint))
            } else {
                Button {
                    Haptics.tap()
                    advance()
                } label: {
                    Text(isLast ? "Read the notes" : "Next question")
                }
                .buttonStyle(.prominent(tint))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: Closing

    private var closing: some View {
        VStack(spacing: 20) {
            Spacer()
            IconTile(symbol: "book", tint: tint, size: 64)
            VStack(spacing: 10) {
                Text(asked > 0 ? "Primed" : "Straight to it")
                    .font(.title2.bold())
                Text(Prequestions.closing(correct: correct, asked: asked))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            Spacer()
            Button("Read the notes") { close() }
                .buttonStyle(.prominent(tint))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    // MARK: Work

    private func check(_ item: StudyItem) {
        answerFocused = false
        let outcome = Grading.offline(item, typed: typed)
        asked += 1
        if outcome.verdict.isRecall { correct += 1 }
        withAnimation(.gentle) { result = outcome }
    }

    private func advance() {
        if isLast {
            withAnimation(.gentle) { finished = true }
        } else {
            index += 1
            typed = ""
            result = nil
        }
    }

    private func close() {
        onFinish(asked, correct)
        dismiss()
    }
}
