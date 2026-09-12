import SpeakerKit
import WhisperKit
import XCTest
@testable import CatchMeUp

/// Covers the parts of the Whisper engine that are ours rather than Argmax's:
/// how speaker-labelled pieces become `Segment`s, how the engine is chosen, and
/// what the progress stages say. Running Whisper itself needs a downloaded
/// model and is exercised on a device, not here.
final class WhisperTranscriberTests: XCTestCase {

    // MARK: Helpers

    private func speakerSegment(_ speaker: Int?, _ start: Float, _ end: Float,
                                _ words: [String]) -> SpeakerSegment {
        let info: SpeakerInfo = speaker.map { .speakerId($0) } ?? .noMatch
        let step = words.isEmpty ? 0 : (end - start) / Float(words.count)
        let timings = words.enumerated().map { index, word in
            SpeakerWordTiming(
                wordTiming: WordTiming(
                    word: index == 0 ? word : " " + word,
                    tokens: [],
                    start: start + Float(index) * step,
                    end: start + Float(index + 1) * step,
                    probability: 1
                ),
                speaker: info
            )
        }
        return SpeakerSegment(speaker: info, startTime: start, endTime: end,
                              frameRate: 100, speakerWords: timings)
    }

    // MARK: Speaker mapping

    func testLabelsAreOneBasedAndHumanReadable() {
        XCTAssertEqual(WhisperTranscriber.label(for: .speakerId(0)), "Speaker 1")
        XCTAssertEqual(WhisperTranscriber.label(for: .speakerId(3)), "Speaker 4")
    }

    /// A stretch diarization could not attribute gets no label rather than a
    /// guessed one — an unlabelled line is honest, a wrong name is not.
    func testUnmatchedSpeechIsLeftUnlabelled() {
        XCTAssertNil(WhisperTranscriber.label(for: .noMatch))
    }

    func testConsecutiveRunsBySameSpeakerAreJoined() {
        let segments = WhisperTranscriber.segments(fromSpeakerSegments: [
            speakerSegment(0, 0, 2, ["We", "should", "ship", "it."]),
            speakerSegment(0, 2, 4, ["Tomorrow", "at", "the", "latest."]),
        ])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speaker, "Speaker 1")
        XCTAssertEqual(segments[0].text, "We should ship it. Tomorrow at the latest.")
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.001)
    }

    /// The one merge that must never happen. Joining across a speaker change
    /// would put one person's words under another's name, which is worse than
    /// any amount of fragmentation.
    func testSpeakerChangeAlwaysStartsANewSegment() {
        let segments = WhisperTranscriber.segments(fromSpeakerSegments: [
            speakerSegment(0, 0, 2, ["Are", "we", "agreed?"]),
            speakerSegment(1, 2, 3, ["Not", "quite."]),
            speakerSegment(0, 3, 4, ["Say", "more."]),
        ])
        XCTAssertEqual(segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
        XCTAssertEqual(segments[1].text, "Not quite.")
    }

    /// A long monologue still breaks up, so a tapped line seeks somewhere near
    /// what the reader is looking at rather than the top of a ten-minute block.
    func testLongSameSpeakerStretchStillBreaks() {
        let pieces = (0..<6).map { i in
            speakerSegment(0, Float(i) * 20, Float(i) * 20 + 20, ["Point", "number", "\(i)."])
        }
        let segments = WhisperTranscriber.segments(fromSpeakerSegments: pieces)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.speaker == "Speaker 1" })
    }

    func testEmptyPiecesAreDropped() {
        let segments = WhisperTranscriber.segments(fromSpeakerSegments: [
            speakerSegment(0, 0, 1, []),
            speakerSegment(0, 1, 2, ["Right."]),
        ])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Right.")
    }

    /// Diarization may hand back segments out of order; the transcript is read
    /// top to bottom, so they get sorted before anything else happens.
    func testOutOfOrderPiecesAreSortedByTime() {
        let segments = WhisperTranscriber.segments(fromSpeakerSegments: [
            speakerSegment(1, 10, 12, ["Second."]),
            speakerSegment(0, 0, 2, ["First."]),
        ])
        XCTAssertEqual(segments.map(\.text), ["First.", "Second."])
    }

    /// The shape the recap prompt and every export read.
    func testTimestampedTextCarriesSpeakerNames() {
        let segments = WhisperTranscriber.segments(fromSpeakerSegments: [
            speakerSegment(0, 0, 2, ["Ship", "it."]),
            speakerSegment(1, 2, 4, ["Agreed."]),
        ])
        let text = segments.timestampedText
        XCTAssertTrue(text.contains("Speaker 1: Ship it."), text)
        XCTAssertTrue(text.contains("Speaker 2: Agreed."), text)
    }

    // MARK: Engine selection

    func testWhisperIsChosenOnlyWhenSelected() {
        XCTAssertTrue(Transcription.engine(demo: false, speech: .whisper) is WhisperTranscriber)
        XCTAssertFalse(Transcription.engine(demo: false, speech: .apple) is WhisperTranscriber)
    }

    /// Demo mode must never start a model download. It is the no-setup path.
    func testDemoBeatsWhisper() {
        XCTAssertTrue(Transcription.engine(demo: true, speech: .whisper) is MockTranscriber)
    }

    func testSelectedVariantAndDiarizationReachTheEngine() throws {
        let engine = Transcription.engine(demo: false, speech: .whisper,
                                          variant: .small, diarize: true)
        let whisper = try XCTUnwrap(engine as? WhisperTranscriber)
        XCTAssertEqual(whisper.variant, .small)
        XCTAssertTrue(whisper.diarize)
    }

    // MARK: Stages

    /// The bug this app already fixed once, in a new place: a percentage shown
    /// before anything has been measured. Zero reads as "nothing is happening".
    func testModelDownloadStageOmitsPercentUntilThereIsOne() {
        XCTAssertEqual(SpeechPreparation.whisperModel(.base, 0).label,
                       "Downloading Whisper Base")
        XCTAssertEqual(SpeechPreparation.whisperModel(.base, 0.42).label,
                       "Downloading Whisper Base — 42%")
    }

    func testEveryStageExplainsItself() {
        let stages: [SpeechPreparation] = [
            .audio, .permission, .model, .starting, .recovering,
            .whisperModel(.turbo, 0.5), .speakers,
        ]
        for stage in stages {
            XCTAssertFalse(stage.label.isEmpty, "\(stage)")
            XCTAssertFalse(stage.detail.isEmpty, "\(stage)")
        }
    }

    func testModelStageNamesItsSizeSoTheDownloadIsNotASurprise() {
        XCTAssertTrue(SpeechPreparation.whisperModel(.turbo, 0.1).detail
            .contains(WhisperVariant.turbo.sizeLabel))
    }

    // MARK: Variants

    /// Whatever the device table says, the picker is never empty and the
    /// preselected rung is one of the offered ones.
    func testRecommendedVariantIsAlwaysOffered() {
        let supported = WhisperVariant.supportedOnThisDevice
        XCTAssertFalse(supported.isEmpty)
        XCTAssertTrue(supported.contains(WhisperVariant.recommended))
    }

    func testVariantIdsAreTheRepoFolderNames() {
        XCTAssertEqual(WhisperVariant.base.rawValue, "openai_whisper-base")
        XCTAssertTrue(WhisperVariant.allCases.allSatisfy { $0.rawValue.hasPrefix("openai_whisper-") })
    }
}

// MARK: - Live download
//
// Off by default: these pull real models from Hugging Face and run Whisper, so
// they are not something a normal `xcodebuild test` should do. Run them
// deliberately with
//
//   TEST_RUNNER_CMU_LIVE_MODEL_DOWNLOAD=1 xcodebuild ... test \
//     -only-testing:CatchMeUpTests/WhisperDownloadTests
//
// The `TEST_RUNNER_` prefix is required and is stripped before the test process
// sees it — without it the variable never arrives, `XCTSkipUnless` skips, and
// the suite reports a pass that checked nothing.
//
// Run them after changing anything about model storage or the transcriber:
// they are the only checks that the download, the recorded path, reloading from
// disk, and Whisper's own output actually agree.

@MainActor
final class WhisperDownloadTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CMU_LIVE_MODEL_DOWNLOAD"] == "1",
                          "Live model test. Re-run with TEST_RUNNER_CMU_LIVE_MODEL_DOWNLOAD=1 "
                          + "in the xcodebuild environment (the TEST_RUNNER_ prefix is required "
                          + "and is stripped before this process sees it).")
    }

    func testDownloadsAndRemembersTheModel() async throws {
        let defaults = UserDefaults(suiteName: "whisper-download-\(UUID().uuidString)")!
        let store = WhisperModelStore(defaults: defaults)
        store.delete(.tiny)

        var sawProgress = false
        let folder = try await store.ensure(.tiny) { fraction in
            if fraction > 0 { sawProgress = true }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(sawProgress, "A download with no progress is the spinner this app avoids.")
        XCTAssertEqual(store.state(.tiny), .ready)

        // A fresh store, as after a relaunch, must find it without re-downloading.
        XCTAssertEqual(WhisperModelStore(defaults: defaults).folder(for: .tiny), folder)

        store.delete(.tiny)
        XCTAssertEqual(store.state(.tiny), .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// Whisper end to end on real audio, in the Simulator — the claim in
    /// `WhisperTranscriber`'s header that this engine runs where Apple's cannot.
    /// `showcase-1.m4a` is narrated English of about 24 seconds, so the text is
    /// checkable without being a transcription-accuracy benchmark.
    func testTranscribesRealAudioInTheSimulator() async throws {
        // Hosted by the app, so the showcase narration is in `Bundle.main`;
        // the test bundle is the fallback if that ever stops being true.
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "showcase-1", withExtension: "m4a")
                ?? Bundle(for: Self.self).url(forResource: "showcase-1", withExtension: "m4a"),
            "showcase-1.m4a is in neither bundle."
        )

        var stages: [SpeechPreparation] = []
        var readings: [Double] = []
        let segments = try await WhisperTranscriber(variant: .tiny, diarize: false)
            .transcribe(url: url, status: { stages.append($0) }, progress: { readings.append($0) })

        XCTAssertFalse(segments.isEmpty, "Whisper produced no segments.")
        let text = segments.map(\.text).joined(separator: " ")
        XCTAssertGreaterThan(text.split(separator: " ").count, 20, text)

        // Timestamps have to be usable: the player seeks to them, and they are
        // what diarization aligns against.
        XCTAssertEqual(segments.first?.start ?? -1, 0, accuracy: 3)
        XCTAssertTrue(segments.map(\.start).sorted() == segments.map(\.start),
                      "Segments must come back in time order.")
        XCTAssertLessThan(try XCTUnwrap(segments.map(\.start).max()), 24)

        // Without diarization nothing may claim to know who spoke.
        XCTAssertTrue(segments.allSatisfy { $0.speaker == nil })

        XCTAssertTrue(stages.contains(.starting), "\(stages)")
        XCTAssertEqual(readings.last, 1, "The bar has to finish.")
        XCTAssertEqual(readings, readings.sorted(), "Progress must never go backwards.")
    }

    /// Diarization end to end. `two-speakers.m4a` is two synthetic voices taking
    /// four alternating turns, which is the smallest audio that can tell working
    /// diarization apart from a pipeline that silently does nothing.
    func testLabelsTwoSpeakersInRealAudio() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "two-speakers", withExtension: "m4a"),
            "two-speakers.m4a is not in the test bundle."
        )

        var stages: [SpeechPreparation] = []
        let segments = try await WhisperTranscriber(variant: .tiny, diarize: true)
            .transcribe(url: url, status: { stages.append($0) }, progress: { _ in })

        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(stages.contains(.speakers), "\(stages)")

        let speakers = Set(segments.compactMap(\.speaker))
        XCTAssertEqual(speakers.count, 2,
                       "Expected two voices, got \(speakers.sorted()) across \(segments.count) segments.")
        XCTAssertEqual(speakers, ["Speaker 1", "Speaker 2"])

        // The two speakers alternate, so the labels must alternate too rather
        // than all the speech landing under one name.
        let labels = segments.compactMap(\.speaker)
        XCTAssertGreaterThan(zip(labels, labels.dropFirst()).filter { $0 != $1 }.count, 1,
                             "Labels never alternate: \(labels)")
    }
}
