import XCTest
@testable import CatchMeUp

final class SpeechOperationTests: XCTestCase {
    private enum Failure: Error { case deadline, original }

    func testReturnsResult() async throws {
        let value = try await SpeechOperation<Int>.run(timeout: .seconds(2), timeoutError: Failure.deadline) { _ in 42 }
        XCTAssertEqual(value, 42)
    }

    func testPreservesFailure() async {
        do {
            _ = try await SpeechOperation<Int>.run(timeout: .seconds(2), timeoutError: Failure.deadline) { _ in
                throw Failure.original
            }
            XCTFail("Should throw")
        } catch Failure.original { } catch { XCTFail("Wrong error: \(error)") }
    }

    func testTimeoutDoesNotWaitForUncooperativeSystemCallback() async {
        let lateCallback = expectation(description: "Late callback safely ignored")
        do {
            _ = try await SpeechOperation<Int>.run(timeout: .milliseconds(30), timeoutError: Failure.deadline) { _ in
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                        continuation.resume(returning: 7)
                        lateCallback.fulfill()
                    }
                }
            }
            XCTFail("Should time out")
        } catch Failure.deadline { } catch { XCTFail("Wrong error: \(error)") }
        await fulfillment(of: [lateCallback], timeout: 2)
    }

    func testTimeoutCancelsUnderlyingWork() async {
        let cancelled = expectation(description: "Underlying work cancelled")
        do {
            _ = try await SpeechOperation<Int>.run(timeout: .milliseconds(30), timeoutError: Failure.deadline) { _ in
                do { try await Task.sleep(for: .seconds(20)); return 1 }
                catch { cancelled.fulfill(); throw error }
            }
            XCTFail("Should time out")
        } catch Failure.deadline { } catch { XCTFail("Wrong error: \(error)") }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testCallerCancellation() async {
        let began = expectation(description: "Started")
        let task = Task {
            try await SpeechOperation<Int>.run(timeout: .seconds(20), timeoutError: Failure.deadline) { _ in
                began.fulfill()
                try await Task.sleep(for: .seconds(20))
                return 1
            }
        }
        await fulfillment(of: [began], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Should cancel") }
        catch is CancellationError { } catch { XCTFail("Wrong error: \(error)") }
    }

    func testCancellationBeforeStartDoesNotRunWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SpeechOperation<Int>.run(timeout: .seconds(2), timeoutError: Failure.deadline) { _ in
                XCTFail("Cancelled work must not run")
                return 1
            }
        }
        do { _ = try await task.value; XCTFail("Should cancel") }
        catch is CancellationError { } catch { XCTFail("Wrong error: \(error)") }
    }

    func testProgressExtendsInactivityDeadline() async throws {
        let value = try await SpeechOperation<Int>.run(timeout: .milliseconds(250), timeoutError: Failure.deadline) { gate in
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(70))
                gate.heartbeat()
            }
            return 9
        }
        XCTAssertEqual(value, 9)
    }

    func testOnlyFirstCompletionWins() async throws {
        let value = try await SpeechOperation<Int>.run(timeout: .seconds(2), timeoutError: Failure.deadline) { gate in
            gate.finish(.success(4))
            gate.finish(.success(8))
            return 12
        }
        XCTAssertEqual(value, 4)
    }

    func testPreparationHasNoInventedPercentageAndIsActive() {
        for stage in [SpeechPreparation.audio, .permission, .model, .starting] {
            let phase = ProcessingQueue.Phase.preparing(stage)
            XCTAssertTrue(phase.isActive)
            XCTAssertTrue(phase.isTranscription)
            XCTAssertTrue(phase.isIndeterminate)
            XCTAssertFalse(phase.isFinished)
            XCTAssertEqual(phase.step, 0)
            XCTAssertEqual(phase.label, stage.label)
            let job = ProcessingQueue.Job(id: UUID(), title: "Meeting", mode: .meeting, phase: phase)
            XCTAssertEqual(job.overallProgress(ProcessingRates(transcribe: 0.25, write: 2, samples: 5)), 0)
        }
        XCTAssertTrue(ProcessingQueue.Phase.transcribing(0).isIndeterminate)
        XCTAssertFalse(ProcessingQueue.Phase.transcribing(0.1).isIndeterminate)
    }

    func testModernRoutingDoesNotRequireAppleIntelligenceOrNewSpeechHardware() {
        XCTAssertTrue(Transcription.engine(demo: true) is MockTranscriber)
        if #available(iOS 26.0, *) {
            XCTAssertTrue(Transcription.engine(demo: false) is AnalyzerTranscriber)
        } else {
            XCTAssertTrue(Transcription.engine(demo: false) is RecognizerTranscriber)
        }
    }
}
