import SwiftUI
import UIKit

// How a brain's answer is presented: the question you asked, the answer
// rendered as real prose, and the recaps it came out of.

// MARK: - Answer + its sources

/// Splits a model answer into renderable prose and the recaps it cited.
struct BrainAnswer {
    let prose: String
    let sourceIDs: [UUID]

    init(raw: String, recaps: [Recording]) {
        var lines = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
        var named: [String] = []

        // A trailing "Sources: …" line becomes chips, so drop it from the prose.
        if let index = lines.lastIndex(where: { Self.isSourceLine($0) }),
           index >= lines.count - 2 {
            named = Self.names(in: lines[index])
            lines.removeSubrange(index..<lines.count)
            while let last = lines.last,
                  last.trimmingCharacters(in: .whitespaces).isEmpty
                    || MarkdownParser.isHorizontalRule(last.trimmingCharacters(in: .whitespaces)) {
                lines.removeLast()
            }
        }

        let prose = lines.joined(separator: "\n")
        self.prose = prose

        var ids: [UUID] = []
        for name in named {
            if let id = Self.match(name, in: recaps), !ids.contains(id) { ids.append(id) }
        }
        // No usable list? Fall back to any recap title mentioned in the answer.
        if ids.isEmpty {
            for recap in recaps where prose.localizedCaseInsensitiveContains(recap.displayTitle) {
                ids.append(recap.id)
            }
        }
        self.sourceIDs = ids
    }

    private static func isSourceLine(_ line: String) -> Bool {
        let bare = line
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_- "))
            .lowercased()
        return bare.hasPrefix("sources:") || bare.hasPrefix("source:")
    }

    private static func names(in line: String) -> [String] {
        guard let colon = line.firstIndex(of: ":") else { return [] }
        return line[line.index(after: colon)...]
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " *_`.[]()\"")) }
            .filter { !$0.isEmpty }
    }

    /// Titles get paraphrased, so compare on letters and digits only.
    private static func match(_ name: String, in recaps: [Recording]) -> UUID? {
        let key = normalized(name)
        guard key.count >= 4 else { return nil }
        if let exact = recaps.first(where: { normalized($0.displayTitle) == key }) { return exact.id }
        return recaps.first { recap in
            let title = normalized(recap.displayTitle)
            return title.contains(key) || key.contains(title)
        }?.id
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Question

struct QuestionBubble: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .shadow(color: tint.opacity(0.25), radius: 9, y: 3)
        }
    }
}

// MARK: - Answer

struct BrainAnswerCard: View {
    let raw: String
    let tint: Color
    let recaps: [Recording]
    let onRetry: () -> Void

    @State private var copied = false

    private let answer: BrainAnswer
    private let sources: [Recording]

    init(raw: String, tint: Color, recaps: [Recording], onRetry: @escaping () -> Void) {
        let parsed = BrainAnswer(raw: raw, recaps: recaps)
        self.raw = raw
        self.tint = tint
        self.recaps = recaps
        self.onRetry = onRetry
        self.answer = parsed
        self.sources = parsed.sourceIDs.compactMap { id in recaps.first { $0.id == id } }
    }

    var body: some View {
        Card(tint: tint) {
            VStack(alignment: .leading, spacing: 15) {
                MarkdownText(answer.prose, style: style)

                if !sources.isEmpty {
                    Divider().opacity(0.4)
                    sourceChips
                }

                actions
            }
        }
    }

    private var style: MarkdownStyle {
        var style = MarkdownStyle.answer
        style.tint = tint
        return style
    }

    private var sourceChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From \(sources.count) recap\(sources.count == 1 ? "" : "s")")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(sources) { recap in
                        NavigationLink(value: recap.id) {
                            HStack(spacing: 5) {
                                Image(systemName: recap.mode.symbol)
                                    .font(.caption2.weight(.bold))
                                Text(recap.displayTitle)
                                    .lineLimit(1)
                                    .frame(maxWidth: 190, alignment: .leading)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(tint.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button {
                UIPasteboard.general.string = answer.prose
                Haptics.success()
                withAnimation(.quick) { copied = true }
            } label: {
                AnswerAction(symbol: copied ? "checkmark" : "doc.on.doc",
                             title: copied ? "Copied" : "Copy",
                             tint: copied ? tint : .secondary)
            }
            .buttonStyle(.plain)

            ShareLink(item: answer.prose) {
                AnswerAction(symbol: "square.and.arrow.up", title: "Share", tint: .secondary)
            }
            .buttonStyle(.plain)

            Button {
                Haptics.tap()
                onRetry()
            } label: {
                AnswerAction(symbol: "arrow.clockwise", title: "Again", tint: .secondary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.top, 1)
    }
}

private struct AnswerAction: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .contentTransition(.symbolEffect(.replace))
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Waiting

struct BrainThinkingCard: View {
    let tint: Color
    let recapCount: Int

    @State private var step = 0

    private var stages: [String] {
        ["Reading \(recapCount) recap\(recapCount == 1 ? "" : "s")",
         "Connecting the ideas",
         "Writing your answer"]
    }

    var body: some View {
        Card(tint: tint) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 10) {
                    PulseGlyph(tint: tint)
                    Text(stages[min(step, stages.count - 1)])
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .id(step)
                        .transition(.opacity)
                    TypingDots(tint: tint)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 9) {
                    ShimmerLine()
                    ShimmerLine(width: 236)
                    ShimmerLine(width: 172)
                }
            }
        }
        .task {
            while !Task.isCancelled && step < stages.count - 1 {
                do { try await Task.sleep(nanoseconds: 2_400_000_000) } catch { return }
                withAnimation(.gentle) { step += 1 }
            }
        }
    }
}

private struct PulseGlyph: View {
    let tint: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(pulse ? 0 : 0.45), lineWidth: 1.4)
                .scaleEffect(pulse ? 1.5 : 0.8)
            Image(systemName: "sparkles")
                .font(.footnote.weight(.bold))
                .foregroundStyle(tint)
        }
        .frame(width: 24, height: 24)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

private struct TypingDots: View {
    let tint: Color
    @State private var lit = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint.opacity(lit == index ? 0.9 : 0.28))
                    .frame(width: 5, height: 5)
                    .scaleEffect(lit == index ? 1.25 : 1)
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 280_000_000) } catch { return }
                withAnimation(.easeInOut(duration: 0.26)) { lit = (lit + 1) % 3 }
            }
        }
    }
}

// MARK: - Failure

struct BrainAnswerErrorCard: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        Card(tint: .orange) {
            VStack(alignment: .leading, spacing: 11) {
                Label("Couldn't answer that", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Haptics.tap()
                    onRetry()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.orange.opacity(0.13), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
