import Foundation

/// Intermediate hypotheses prove the recognizer is alive and can advance the
/// audio cursor, but only finalized text belongs in the saved transcript.
struct SpeechResultBuffer {
    private var pieces: [(start: Double, end: Double, text: String)] = []
    private var furthestEnd: Double = 0

    mutating func receive(text: String, start: Double, end: Double, isFinal: Bool, total: Double) -> Double? {
        if isFinal {
            pieces.append((start: start.isFinite ? start : 0, end: end.isFinite ? end : 0, text: text))
        }
        guard end.isFinite, total.isFinite, total > 0 else { return nil }
        furthestEnd = max(furthestEnd, end)
        return min(0.99, max(0, furthestEnd / total))
    }

    var segments: [Segment] { Transcription.assemble(pieces) }
}
