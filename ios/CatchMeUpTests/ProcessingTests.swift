import XCTest
@testable import CatchMeUp

final class ProcessingEstimateTests: XCTestCase {

    private let rates = ProcessingRates(transcribe: 0.25, write: 2, samples: 5)

    private func job(phase: ProcessingQueue.Phase, rewriteOnly: Bool = false) -> ProcessingQueue.Job {
        var job = ProcessingQueue.Job(id: UUID(), title: "Lecture", mode: .lecture, rewriteOnly: rewriteOnly)
        job.phase = phase
        job.audioSeconds = 3_600          // an hour of audio
        job.transcriptCharacters = 54_000 // ~15 characters a second
        return job
    }

    /// A flat "step 1 of 2" bar jumps to 50% in the first second and sits
    /// there. Weighting by measured cost keeps the bar honest: transcribing an
    /// hour takes ~900s and writing it ~108s, so finishing the transcript is
    /// most of the job, not half of it.
    func testProgressIsWeightedByRealCost() {
        let transcriptDone = job(phase: .writing(0)).overallProgress(rates)
        XCTAssertGreaterThan(transcriptDone, 0.85)
        XCTAssertLessThan(transcriptDone, 1)
    }

    func testProgressIsMonotonicAcrossPhases() {
        let points = [
            job(phase: .queued).overallProgress(rates),
            job(phase: .transcribing(0.25)).overallProgress(rates),
            job(phase: .transcribing(0.9)).overallProgress(rates),
            job(phase: .writing(0.5)).overallProgress(rates),
            job(phase: .done).overallProgress(rates),
        ]
        XCTAssertEqual(points, points.sorted())
        XCTAssertEqual(points.first, 0)
        XCTAssertEqual(points.last, 1)
    }

    /// Re-running only the notes skips transcription entirely, so its progress
    /// must not start at 90%.
    func testRewriteOnlyIgnoresTranscriptionCost() {
        let halfway = job(phase: .writing(0.5), rewriteOnly: true).overallProgress(rates)
        XCTAssertEqual(halfway, 0.5, accuracy: 0.001)
    }

    func testEstimateAddsBothSteps() {
        // 3,600s of audio at 0.25x plus 54 thousand-character units at 2s each.
        let total = rates.estimate(audioSeconds: 3_600, transcriptCharacters: 54_000)
        XCTAssertEqual(total, 900 + 108, accuracy: 0.001)
    }

    /// Before a transcript exists the length has to be guessed from the audio,
    /// or the writing step contributes nothing to the first estimate.
    func testCharacterCountIsEstimatedFromAudioLength() {
        let guessed = ProcessingRates.expectedCharacters(forAudioSeconds: 3_600)
        XCTAssertGreaterThan(guessed, 30_000)
        XCTAssertLessThan(guessed, 90_000)
    }
}

final class ETAPhrasingTests: XCTestCase {

    /// Deliberately vague. A countdown that claims to know the second looks
    /// broken the moment it stalls.
    func testPhrasingRoundsToSomethingBelievable() {
        XCTAssertEqual(etaText(4), "under 10 sec")
        XCTAssertEqual(etaText(38), "about 40 sec")
        XCTAssertEqual(etaText(150), "about 3 min")
        XCTAssertEqual(etaText(0), "almost done")
    }

    func testNonsenseInputDoesNotProduceNonsenseText() {
        XCTAssertEqual(etaText(-10), "almost done")
        XCTAssertEqual(etaText(.infinity), "almost done")
        XCTAssertEqual(etaText(.nan), "almost done")
    }
}

@MainActor
final class ProcessingPhaseTests: XCTestCase {

    /// Parking is not failing. The distinction is the whole reason a swipe away
    /// no longer leaves an error on a recording the user never touched.
    func testPausedIsNeitherActiveNorFinished() {
        XCTAssertFalse(ProcessingQueue.Phase.paused.isActive)
        XCTAssertFalse(ProcessingQueue.Phase.paused.isFinished)
        XCTAssertTrue(ProcessingQueue.Phase.transcribing(0.5).isActive)
        XCTAssertTrue(ProcessingQueue.Phase.done.isFinished)
        XCTAssertTrue(ProcessingQueue.Phase.failed("nope").isFinished)
    }

    func testQueuedIsNotYetRunning() {
        XCTAssertFalse(ProcessingQueue.Phase.queued.isActive)
        XCTAssertFalse(ProcessingQueue.Phase.queued.isFinished)
    }

    /// A recording that already failed must not be picked back up
    /// automatically — the user has been shown the error and asked to retry.
    func testNeedsProcessingIgnoresFinishedAndFailedRecordings() {
        var pending = Recording(title: "Pending", mode: .meeting, audioFilename: "a.m4a")
        XCTAssertTrue(ProcessingQueue.needsProcessing(pending))

        pending.processingError = "network died"
        XCTAssertFalse(ProcessingQueue.needsProcessing(pending))

        var finished = Recording(title: "Finished", mode: .meeting, audioFilename: "a.m4a")
        finished.recap = Recap(title: "Finished")
        XCTAssertFalse(ProcessingQueue.needsProcessing(finished))
    }

    /// Notes can still be written from a transcript after the audio is deleted.
    func testTranscriptWithoutAudioStillNeedsProcessing() {
        let rec = Recording(title: "Notes only", mode: .lecture,
                            segments: [Segment(start: 0, text: "Something was said.")])
        XCTAssertTrue(ProcessingQueue.needsProcessing(rec))
    }

    func testRecordingWithNothingToWorkFromIsSkipped() {
        let empty = Recording(title: "Empty", mode: .lecture)
        XCTAssertFalse(ProcessingQueue.needsProcessing(empty))
    }
}
