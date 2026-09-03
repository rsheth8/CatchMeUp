import XCTest
import UIKit
@testable import CatchMeUp

final class MaterialKnowledgeTests: XCTestCase {
    func testPDFExtractionKeepsPageNumbersAndText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            ("Recursion\nA recursive function solves a smaller instance of the same problem." as NSString)
                .draw(at: CGPoint(x: 40, y: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            context.beginPage()
            ("Base cases\nEvery recursive definition needs a stopping condition." as NSString)
                .draw(at: CGPoint(x: 40, y: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }

        let pages = try DocumentProcessor.extract(url: url, kind: .pdf)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].number, 1)
        XCTAssertTrue(pages[0].text.localizedCaseInsensitiveContains("recursive"))
        XCTAssertTrue(pages[1].text.localizedCaseInsensitiveContains("stopping"))
        XCTAssertNotNil(pages[0].thumbnail)
    }

    func testMaterialRetrievalSelectsRelevantPageAndPreservesLocation() {
        let material = sampleMaterial()
        let result = MaterialRetriever.context(for: "Why does recursion need a base case?",
                                                materials: [material], budget: 4_000)

        XCTAssertEqual(result.materials.map(\.id), [material.id])
        XCTAssertTrue(result.text.contains("[Slide 2]"))
        XCTAssertTrue(result.text.contains("stopping condition"))
    }

    func testMaterialQuestionsKeepDocumentProvenance() {
        let material = sampleMaterial()
        let items = QuestionMint.items(for: material)

        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.materialID == material.id })
        XCTAssertTrue(items.allSatisfy { $0.brainID == material.brainID })
        XCTAssertTrue(items.contains { $0.sourceTitle.contains("Slide") })
    }

    func testNeuralMapCanGrowFromMaterialWithoutRecording() {
        let material = sampleMaterial()
        let graph = BrainGraph.build(from: [], materials: [material])

        XCTAssertTrue(graph.nodes.contains { $0.label.lowercased() == "recursion" })
        XCTAssertTrue(graph.nodes.contains { $0.materialIDs.contains(material.id) })
    }

    func testAnswerCitationKeepsMaterialAndExactSlide() {
        let material = sampleMaterial()
        let answer = BrainAnswer(
            raw: "A base case stops recursion.\n\nSources: Lecture 8 Slides [Slide 2]",
            recaps: [], materials: [material]
        )

        XCTAssertEqual(answer.materialIDs, [material.id])
        XCTAssertEqual(answer.materialPages[material.id], 2)
    }

    private func sampleMaterial() -> SupplementalMaterial {
        let brainID = UUID()
        let pages = [
            MaterialPage(number: 1, title: "Recursive functions",
                         text: "Recursion solves a problem using a smaller instance of the same problem."),
            MaterialPage(number: 2, title: "Base cases",
                         text: "A base case is the stopping condition that prevents infinite recursion."),
        ]
        return SupplementalMaterial(
            name: "Lecture 8 Slides",
            kind: .slides,
            brainID: brainID,
            originalFilename: "lecture-8.pptx",
            state: .ready,
            pages: pages,
            summary: "Recursion and base cases",
            concepts: [
                MaterialConcept(name: "Recursion", pageNumbers: [1, 2]),
                MaterialConcept(name: "Base cases", pageNumbers: [2]),
            ]
        )
    }
}
