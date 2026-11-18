import XCTest
@testable import BenchCore

final class CorpusTests: XCTestCase {

    /// ios/Bench/corpus, found relative to this file so `swift test` works from anywhere.
    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("corpus")
    }

    func testShippedCorpusLoadsAndCoversEveryBucketAndMode() throws {
        let items = try Corpus.load(from: corpusURL)
        XCTAssertGreaterThanOrEqual(items.count, 8)
        XCTAssertEqual(Set(items.map(\.bucket)), Set(LengthBucket.allCases))
        XCTAssertEqual(Set(items.map(\.mode)), Set(Mode.allCases))
    }

    func testEveryTranscriptIsInTheShapeTheAppProduces() throws {
        for item in try Corpus.load(from: corpusURL) {
            let lines = item.transcript.components(separatedBy: "\n")
            for line in lines {
                XCTAssertNotNil(
                    line.range(of: #"^\[\d{2}:\d{2}:\d{2}\] "#, options: .regularExpression),
                    "\(item.id): \(line.prefix(40))"
                )
            }
            let stamps = Transcript.stamps(in: item.transcript)
            XCTAssertEqual(stamps, stamps.sorted(), "\(item.id): timestamps must not go backwards")
        }
    }

    /// A gold fact whose phrases never occur in the transcript could not be
    /// scored fairly: every engine would miss it. At least one phrase has to be
    /// something a faithful note would plausibly repeat.
    func testEveryGoldFactIsAnchoredInItsTranscript() throws {
        for item in try Corpus.load(from: corpusURL) {
            let key = RecapAnalysis.normalize(item.transcript)
            for fact in item.gold.facts {
                let anchored = fact.anyOf.contains { !RecapAnalysis.normalize($0).isEmpty && key.contains(RecapAnalysis.normalize($0)) }
                XCTAssertTrue(anchored, "\(item.id): fact '\(fact.id)' has no phrase found in the transcript")
            }
        }
    }

    func testTrapNamesDoNotAppearInTheirTranscripts() throws {
        for item in try Corpus.load(from: corpusURL) {
            for name in item.gold.forbiddenNames {
                XCTAssertFalse(RecapAnalysis.containsWord(item.transcript, name), "\(item.id) contains trap name \(name)")
            }
            for name in item.gold.speakerNames {
                XCTAssertTrue(item.transcript.contains(name), "\(item.id) never says \(name)")
            }
        }
    }

    func testTheUnlabelledMeetingReallyHasNoNames() throws {
        let item = try XCTUnwrap(Corpus.load(from: corpusURL, only: ["meeting-unlabelled"]).first)
        XCTAssertTrue(item.gold.speakerNames.isEmpty)
        XCTAssertFalse(item.gold.forbiddenNames.isEmpty)
    }

    func testAskingForAnUnknownRecordingIsAnError() {
        XCTAssertThrowsError(try Corpus.load(from: corpusURL, only: ["nope"]))
    }

    // MARK: Import

    func testImportCopiesATranscriptAndRejectsBadInput() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let good = tmp.appendingPathComponent("t.txt")
        try "[00:00:01] hello\n[00:00:09] world\n".write(to: good, atomically: true, encoding: .utf8)
        let corpus = tmp.appendingPathComponent("corpus")

        try Corpus.importTranscript(file: good, id: "mine", mode: .lecture, title: "Mine", into: corpus)
        let loaded = try Corpus.load(from: corpus)
        XCTAssertEqual(loaded.map(\.id), ["mine"])
        XCTAssertTrue(loaded[0].gold.facts.isEmpty)

        XCTAssertThrowsError(try Corpus.importTranscript(file: good, id: "mine", mode: .lecture, title: "", into: corpus),
                             "a second import must not overwrite")
        XCTAssertThrowsError(try Corpus.importTranscript(file: good, id: "../escape", mode: .lecture, title: "", into: corpus))

        let plain = tmp.appendingPathComponent("plain.txt")
        try "no timestamps here".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Corpus.importTranscript(file: plain, id: "plain", mode: .meeting, title: "", into: corpus))
    }
}
