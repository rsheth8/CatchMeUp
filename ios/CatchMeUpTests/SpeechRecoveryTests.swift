import XCTest
@testable import CatchMeUp

final class SpeechRecoveryTests: XCTestCase {
    func testTimeoutThenSuccessRecoversExactlyOnce() async throws {
        var attempts: [Int] = []
        var recoveries = 0
        let value = try await SpeechRecovery.run(delay: .zero, recovering: { recoveries += 1 }) { attempt in
            attempts.append(attempt)
            if attempt == 1 { throw SpeechDeadline.transcription }
            return "transcript"
        }
        XCTAssertEqual(value, "transcript")
        XCTAssertEqual(attempts, [1, 2])
        XCTAssertEqual(recoveries, 1)
    }

    func testRepeatedTimeoutStopsAfterTwoAttempts() async {
        var attempts = 0
        do {
            let _: Int = try await SpeechRecovery.run(delay: .zero, recovering: {}) { _ in
                attempts += 1
                throw SpeechDeadline.startup
            }
            XCTFail("Must stop")
        } catch SpeechDeadline.startup {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(attempts, 2)
    }

    func testPermanentErrorsAndDownloadsAreNotRetried() async {
        for error: Error in [TranscriptionError.notAuthorized, TranscriptionError.recognizerUnavailable,
                             TranscriptionError.failed("Bad audio"), SpeechDeadline.model] {
            var attempts = 0
            do {
                let _: Int = try await SpeechRecovery.run(delay: .zero, recovering: { XCTFail("Must not retry") }) { _ in
                    attempts += 1
                    throw error
                }
                XCTFail("Must throw")
            } catch { }
            XCTAssertEqual(attempts, 1)
        }
    }

    func testCancellationDuringRecoveryDoesNotStartAnotherAttempt() async {
        let recovering = expectation(description: "Recovery began")
        let task = Task {
            let _: Int = try await SpeechRecovery.run(delay: .seconds(30), recovering: { recovering.fulfill() }) { attempt in
                XCTAssertEqual(attempt, 1)
                throw SpeechDeadline.transcription
            }
        }
        await fulfillment(of: [recovering], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Must cancel") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testPrecancelledRecoveryDoesNoWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SpeechRecovery.run(delay: .zero, recovering: { XCTFail("Must not recover") }) { _ in
                XCTFail("Must not start")
                return 1
            }
        }
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOldAttemptCallbacksCannotUpdateRetry() {
        let old = SpeechCallbacks()
        let current = SpeechCallbacks()
        var states: [String] = []
        old.send { states.append("starting") }
        old.close()
        current.send { states.append("recovering") }
        old.send { states.append("stale failure") }
        current.send { states.append("transcribing") }
        current.close()
        current.send { states.append("late progress") }
        XCTAssertEqual(states, ["starting", "recovering", "transcribing"])
    }

    func testVolatileResultsAdvanceProgressButAreNeverSaved() {
        var buffer = SpeechResultBuffer()
        XCTAssertEqual(buffer.receive(text: "Wrong guess", start: 0, end: 10, isFinal: false, total: 100), 0.1)
        XCTAssertTrue(buffer.segments.isEmpty)
        XCTAssertEqual(buffer.receive(text: "Correct sentence.", start: 0, end: 8, isFinal: true, total: 100), 0.1)
        XCTAssertEqual(buffer.segments.map(\.text), ["Correct sentence."])
        XCTAssertEqual(buffer.receive(text: "Next sentence.", start: 8, end: 100, isFinal: true, total: 100), 0.99)
        XCTAssertEqual(buffer.segments.count, 2)
    }

    func testInvalidResultTimesDoNotInventProgress() {
        var buffer = SpeechResultBuffer()
        XCTAssertNil(buffer.receive(text: "Text.", start: .nan, end: .infinity, isFinal: true, total: 100))
        XCTAssertEqual(buffer.segments.first?.start, 0)
        XCTAssertNil(buffer.receive(text: "", start: 0, end: 10, isFinal: false, total: 0))
    }

    func testSpeechFailureDoesNotPretendTranscriptCompleted() {
        var job = ProcessingQueue.Job(id: UUID(), title: "Lecture", mode: .lecture,
                                      phase: .preparing(.starting), audioSeconds: 554, transcriptCharacters: 8000)
        job.interrupt(with: .failed("Deadline"))
        XCTAssertEqual(job.step, 0)
        XCTAssertFalse(job.showsProgress)
        XCTAssertEqual(job.displayLabel, "Transcription needs another try")
        XCTAssertEqual(job.overallProgress(ProcessingRates(transcribe: 0.25, write: 2, samples: 5)), 0)
    }

    func testFailureAndPausePreserveTheActualStageAndProgress() {
        let rates = ProcessingRates(transcribe: 0.25, write: 2, samples: 5)
        for phase: ProcessingQueue.Phase in [.transcribing(0.14), .writing(0.4)] {
            for interrupted: ProcessingQueue.Phase in [.paused, .failed("Error")] {
                var job = ProcessingQueue.Job(id: UUID(), title: "Lecture", mode: .lecture,
                                              phase: phase, audioSeconds: 554, transcriptCharacters: 8000)
                let before = job.overallProgress(rates)
                job.interrupt(with: interrupted)
                XCTAssertEqual(job.step, phase.step)
                XCTAssertEqual(job.overallProgress(rates), before)
            }
        }
    }

    func testRecoveryIsActiveWithoutInventedProgress() {
        let job = ProcessingQueue.Job(id: UUID(), title: "Lecture", mode: .lecture, phase: .preparing(.recovering))
        XCTAssertTrue(job.phase.isActive)
        XCTAssertFalse(job.phase.isFinished)
        XCTAssertFalse(job.showsProgress)
        XCTAssertEqual(job.step, 0)
        XCTAssertEqual(job.displayLabel, "Restarting Apple Speech")
    }
}
