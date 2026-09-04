import Foundation
import UIKit

enum ShowcaseCatalog {
    struct Entry: Decodable {
        let key: Int
        let brain: String
        let title: String
        let daysAgo: Int
        let notes: [[String]]
        let starts: [Double]
        let duration: Double
        var mode: Mode { brain == "cs" || brain == "stats" ? .lecture : .meeting }
        var id: UUID { UUID(uuidString: String(format: "DE000000-0000-4000-A000-%012d", key))! }
        var brainID: UUID { ShowcaseCatalog.brainID(brain) }
        var audioURL: URL? { Bundle.main.url(forResource: "showcase-\(key)", withExtension: "m4a") }
        var segments: [Segment] {
            zip(notes, starts).map { Segment(start: $0.1, text: $0.0[1], speaker: nil) }
        }
        var recap: Recap {
            Recap(title: title, tldr: notes.map { $0[1] }, actionItems: mode == .meeting ? notes.map { $0[1] }.filter { $0.contains(" will ") } : nil,
                  speakers: nil,
                  bookmarks: zip(notes, starts).map { Bookmark(timestamp: ShowcaseCatalog.stamp($0.1), heading: $0.0[0], insight: $0.0[1]) },
                  detailedNotes: notes.map { DetailNote(heading: $0[0], content: $0[1]) },
                  terms: notes.map { Term(term: $0[0], definition: $0[1]) },
                  study: mode == .lecture ? notes.map { "Explain \($0[0].lowercased()) and give an example." } : nil)
        }
        func recording(now: Date = .now) -> Recording {
            var record = Recording(title: title, mode: mode)
            record.id = id
            record.brainID = brainID
            record.createdAt = now.addingTimeInterval(-Double(daysAgo) * 86400 - Double(key) * 90)
            record.duration = duration
            record.segments = segments
            record.recap = recap
            if mode == .meeting {
                var workspace = MeetingWorkspace()
                workspace.agenda = notes.map { $0[0] }.joined(separator: "\n")
                workspace.merge(DemoResponses.meeting(transcript: segments.timestampedText),
                                transcript: segments.timestampedText, materials: [])
                workspace.analyzedAt = record.createdAt
                // A mix of reviewed work and suggestions ready to review.
                for i in workspace.followUps.indices {
                    workspace.followUps[i].needsReview = i % 2 == 0
                    workspace.followUps[i].status = i % 2 == 0 ? .inProgress : .open
                }
                record.meeting = workspace
            }
            return record
        }
    }

    static func entries() throws -> [Entry] {
        guard let url = Bundle.main.url(forResource: "showcase-catalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    }

    static func brainID(_ key: String) -> UUID {
        let number = ["cs": 1, "stats": 2, "payments": 3, "product": 4][key] ?? 1
        return UUID(uuidString: String(format: "DE000000-0001-4000-A000-%012d", number))!
    }

    static let brainNames = [("cs", "Computer Science", Mode.lecture), ("stats", "Statistics", .lecture),
                             ("payments", "Payments", .meeting), ("product", "Product Studio", .meeting)]

    static func stamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    @MainActor
    static func prepare(store: LibraryStore, study: StudyStore, materials: MaterialStore) async {
        guard store.isShowcase, study.isShowcase else { return }
        let session = ShowcaseSession.shared
        session.isPreparing = true
        session.error = nil
        defer { session.isPreparing = false }
        do {
            let entries = try entries()
            for (key, name, mode) in brainNames where !store.brains.contains(where: { $0.id == brainID(key) }) {
                store.upsert(Brain(id: brainID(key), name: name,
                                  persona: "Answer from this showcase's source material and distinguish facts from open questions.",
                                  mode: mode, createdAt: Date().addingTimeInterval(-86400 * 21)))
            }
            for entry in entries where !store.recordings.contains(where: { $0.id == entry.id }) {
                try Task.checkCancellation()
                var recording = entry.recording()
                guard let url = entry.audioURL, let imported = await store.audio.importFile(from: url) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                recording.audioFilename = imported.filename
                if let facts = imported.facts { recording.apply(facts) }
                store.upsert(recording)
            }
            study.mintOffline(for: store.sortedRecordings)
            study.seedShowcaseHistory()
            if study.examPlans.isEmpty {
                study.upsert(ExamPlan(brainID: brainID("cs"), title: "Computer Science midterm",
                                     date: .now.addingTimeInterval(86400 * 7)))
                study.upsert(ExamPlan(brainID: brainID("stats"), title: "Statistics practice exam",
                                     date: .now.addingTimeInterval(86400 * 12)))
            }
            if materials.materials.isEmpty {
                materials.importFiles(SampleData.bundledMaterialURLs, into: brainID("cs"), attachingTo: entries[0].id)
                // A genuine work document goes through the normal PDF extractor.
                let work = entries.first { $0.brain == "payments" }!
                let url = ShowcaseSession.root.appendingPathComponent("Billing launch brief.pdf")
                try meetingBrief(work).write(to: url, options: .atomic)
                materials.importFiles([url], into: work.brainID, attachingTo: work.id)
            }
            materials.resumePending()
        } catch {
            session.error = "Some showcase content couldn't be prepared: \(error.localizedDescription). Exit and reopen the showcase to retry."
        }
    }

    @MainActor private static func meetingBrief(_ entry: Entry) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            let title = "Payments · Launch brief\nFictional showcase material"
            (title as NSString).draw(in: CGRect(x: 48, y: 48, width: 516, height: 85),
                                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 23), .foregroundColor: UIColor.black])
            let body = "Purpose: prepare the team for the billing migration. This document is background, not proof of a spoken decision.\n\n"
                + entry.notes.map { "\($0[0])\n\($0[1])" }.joined(separator: "\n\n")
                + "\n\nReview checklist\nVerify proration tests, invoice reconciliation, support readiness, and the rollback rehearsal before expanding customer traffic."
            (body as NSString).draw(in: CGRect(x: 48, y: 152, width: 516, height: 590),
                                   withAttributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.black])
        }
    }
}
