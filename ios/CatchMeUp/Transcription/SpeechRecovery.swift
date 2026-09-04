import Foundation

/// These are app deadlines, not assertions that Apple's service crashed.
enum SpeechDeadline: String, Codable, LocalizedError {
    case language, model, startup, transcription

    var errorDescription: String? {
        switch self {
        case .language: return "Apple Speech took too long to check the language. Your audio is saved. Try again with the app open."
        case .model: return "The speech model is still unavailable. Your audio is saved. Check your connection and free storage, then try again."
        case .startup: return "Apple Speech took too long to get ready. Your audio is saved. Try again with the app open."
        case .transcription: return "No new speech results arrived before the time limit. Your audio is saved. Try transcription again with the app open."
        }
    }
}

/// One fresh attempt for our known transient deadlines; never retry permission,
/// unsupported-language, invalid-audio or provider errors automatically.
enum SpeechRecovery {
    static func run<Value>(
        delay: Duration = .seconds(2),
        recovering: () -> Void,
        operation: (Int) async throws -> Value
    ) async throws -> Value {
        for attempt in 1...2 {
            try Task.checkCancellation()
            do {
                let value = try await operation(attempt)
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                guard attempt == 1, let deadline = error as? SpeechDeadline,
                      deadline != .model else { throw error }
                recovering()
                try await Task.sleep(for: delay)
            }
        }
        preconditionFailure("Both attempts return or throw")
    }
}

/// A timed-out system task can still emit callbacks while it winds down. Seal
/// its callbacks before the next attempt; never let them repaint the new run.
final class SpeechCallbacks: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var open = true

    func send(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard open else { return }
        body()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        open = false
    }
}

/// Bounded, device-local diagnostic history. No audio, transcript, titles,
/// recording IDs, API responses or credentials are stored here.
enum SpeechDiagnostics {
    struct Event: Codable {
        var date: Date
        var stage: SpeechDeadline
        var attempt: Int
        var seconds: Double
        var outcome: String
    }
    private static let lock = NSLock()
    private static let key = "speech.recentAttempts"

    static func record(stage: SpeechDeadline, attempt: Int, started: Date, outcome: String) {
        lock.lock(); defer { lock.unlock() }
        let defaults = UserDefaults.standard
        var events = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
        events.append(Event(date: Date(), stage: stage, attempt: attempt,
                            seconds: Date().timeIntervalSince(started), outcome: outcome))
        if let data = try? JSONEncoder().encode(Array(events.suffix(40))) {
            defaults.set(data, forKey: key)
        }
    }
}
