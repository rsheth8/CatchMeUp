import XCTest
@testable import CatchMeUp

/// The Mac CLI writes this exact shape into the iCloud Drive folder.
/// If decoding fails, a push looks like it worked and the iPhone shows nothing.
final class LibrarySyncTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    func testDecodesCLIPushedRecording() throws {
        let json = """
        [{
          "id": "A1B2C3D4-E5F6-4789-ABCD-EF0123456789",
          "title": "Week 3: Mutexes",
          "createdAt": "2026-02-10T09:00:00Z",
          "updatedAt": "2026-02-10T18:00:00Z",
          "deleted": false,
          "mode": "lecture",
          "audioFilename": null,
          "duration": 1240.5,
          "segments": [
            {"id": "00000000-0000-4000-8000-000000000001", "start": 12.4, "text": "A mutex is a lock."}
          ],
          "recap": {
            "title": "Week 3: Mutexes",
            "tldr": ["A mutex serializes access."],
            "actionItems": [],
            "speakers": [{"label": "Speaker 1", "name": "", "said": ""}],
            "bookmarks": [{"timestamp": "00:12:40", "heading": "mutex", "insight": "Acquire first."}],
            "detailedNotes": [{"heading": "Mutexes", "content": "Acquire, then release."}],
            "terms": [{"term": "mutex", "definition": "A lock one thread holds."}],
            "study": ["Define mutex."]
          },
          "brainID": "11111111-2222-4333-8444-555555555555",
          "completedActions": []
        }]
        """
        let recordings = try decode(json, as: [Recording].self)
        XCTAssertEqual(recordings.count, 1)
        let rec = recordings[0]
        XCTAssertEqual(rec.title, "Week 3: Mutexes")
        XCTAssertEqual(rec.mode, .lecture)
        XCTAssertEqual(rec.duration, 1240.5, accuracy: 0.01)
        XCTAssertEqual(rec.segments.count, 1)
        XCTAssertEqual(rec.recap?.terms?.first?.term, "mutex")
        XCTAssertNotNil(rec.brainID)
        XCTAssertNil(rec.audioFilename)
    }

    func testDecodesLowercasedSwiftUUIDsAndNullBrain() throws {
        let json = """
        [{
          "id": "a1b2c3d4-e5f6-4789-abcd-ef0123456789",
          "title": "Hallway chat",
          "createdAt": "2026-03-01T09:00:00Z",
          "updatedAt": "2026-03-01T09:00:00Z",
          "deleted": false,
          "mode": "meeting",
          "duration": 0,
          "segments": [],
          "recap": {"title": "Hallway chat", "tldr": ["Quick catch-up."]},
          "brainID": null,
          "completedActions": [0]
        }]
        """
        let recordings = try decode(json, as: [Recording].self)
        XCTAssertEqual(recordings[0].completedActions, [0])
        XCTAssertNil(recordings[0].brainID)
        XCTAssertEqual(recordings[0].mode, .meeting)
    }

    func testDecodesCLIPushedBrain() throws {
        let json = """
        [{
          "id": "11111111-2222-4333-8444-555555555555",
          "name": "cs61a",
          "persona": "You are a CS 61A TA.",
          "mode": "lecture",
          "createdAt": "2026-02-01T00:00:00Z",
          "updatedAt": "2026-02-01T00:00:00Z",
          "deleted": false
        }]
        """
        let brains = try decode(json, as: [Brain].self)
        XCTAssertEqual(brains[0].name, "cs61a")
        XCTAssertEqual(brains[0].mode, .lecture)
        XCTAssertTrue(brains[0].persona.contains("TA"))
    }
}
