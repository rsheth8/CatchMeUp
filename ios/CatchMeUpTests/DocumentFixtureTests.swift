import XCTest
@testable import CatchMeUp

/// Extraction against real documents rather than ones built in the test.
///
/// `MaterialKnowledgeTests` draws its PDF with `UIGraphicsPDFRenderer`, which
/// produces a far tidier file than anything a student actually imports. These
/// fixtures are a real PowerPoint package and two real PDFs — one with a text
/// layer, one that is nothing but a scanned image — so the three paths through
/// `DocumentProcessor` are each exercised by the kind of file that reaches them
/// in practice. The slide path in particular had no coverage at all.
final class DocumentFixtureTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: DocumentFixtureTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext),
                                "Fixture \(name).\(ext) is missing from the test bundle")
        return url
    }

    // MARK: - Slides

    func testSlideDeckKeepsOrderTitlesAndSpeakerNotes() throws {
        let url = try fixture("Week 3 Slides - Environment Diagrams", "pptx")
        let pages = try DocumentProcessor.extract(url: url, kind: .slides)

        XCTAssertEqual(pages.count, 5)
        // Slides are ordered by number, not by the order the zip happens to list
        // its entries — slide10 must never sort between slide1 and slide2.
        XCTAssertEqual(pages.map(\.number), [1, 2, 3, 4, 5])

        XCTAssertEqual(pages[0].title, "Environment Diagrams")
        XCTAssertTrue(pages[3].text.contains("make_adder"),
                      "Slide 4 body should carry the worked example verbatim")

        // Notes live in a separate part of the package and are the half a
        // reader cannot see on the slide, so losing them is silent.
        XCTAssertTrue(pages.allSatisfy { !$0.speakerNotes.isEmpty },
                      "Every slide in this deck has notes")
        XCTAssertTrue(pages[2].speakerNotes.localizedCaseInsensitiveContains("midterm"))

        XCTAssertTrue(pages.allSatisfy { $0.thumbnail != nil })
    }

    func testSlideTextAndNotesAreBothSearchable() throws {
        let url = try fixture("Week 3 Slides - Environment Diagrams", "pptx")
        let pages = try DocumentProcessor.extract(url: url, kind: .slides)

        let material = SupplementalMaterial(
            name: "Week 3 slides", kind: .slides, brainID: UUID(),
            originalFilename: "Week 3 Slides - Environment Diagrams.pptx", state: .ready,
            pages: pages.map {
                MaterialPage(number: $0.number, title: $0.title,
                             text: $0.text, speakerNotes: $0.speakerNotes)
            }
        )

        let result = MaterialRetriever.context(
            for: "Why does the parent come from the def frame?",
            materials: [material], budget: 4_000
        )
        XCTAssertEqual(result.materials.map(\.id), [material.id])
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("def frame"))

        let items = QuestionMint.items(for: material)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.materialID == material.id })
    }

    // MARK: - PDF with a text layer

    func testTextPDFKeepsEveryPageAndItsProse() throws {
        let url = try fixture("Week 3 Reading - Higher-Order Functions", "pdf")
        let pages = try DocumentProcessor.extract(url: url, kind: .pdf)

        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.map(\.number), [1, 2, 3])
        XCTAssertTrue(pages[0].text.localizedCaseInsensitiveContains("environment"))
        XCTAssertTrue(pages[1].text.localizedCaseInsensitiveContains("closure"))
        XCTAssertTrue(pages.allSatisfy { $0.thumbnail != nil })
        XCTAssertTrue(pages.allSatisfy { $0.text.count > 200 },
                      "A text-layer PDF should never fall through to OCR")
    }

    // MARK: - Scanned PDF, no text layer

    func testScannedPDFFallsBackToVisionOCR() throws {
        let url = try fixture("Discussion 3 Worksheet", "pdf")
        let pages = try DocumentProcessor.extract(url: url, kind: .pdf)

        XCTAssertEqual(pages.count, 1)
        // The page carries no text layer at all, so everything here came out of
        // Vision. OCR output is never exact, so assert on substance, not on a
        // transcript: enough characters to be a page, and the words that repeat.
        XCTAssertGreaterThan(pages[0].text.count, 80,
                             "OCR produced too little to be the scanned worksheet")
        XCTAssertTrue(pages[0].text.localizedCaseInsensitiveContains("question"))
        XCTAssertFalse(pages[0].title.isEmpty)
    }
}
