import Foundation

extension QuestionMint {
    static func items(for material: SupplementalMaterial) -> [StudyItem] {
        guard material.state.isReady, material.usageMode != .meeting else { return [] }
        var output: [StudyItem] = []
        let provenanceID = material.recordingIDs.first ?? material.id

        for concept in material.concepts.prefix(12) {
            guard let pageNumber = concept.pageNumbers.first,
                  let page = material.pages.first(where: { $0.number == pageNumber }) else { continue }
            let answer = usefulAnswer(for: concept.name, on: page)
            guard answer.count >= 24 else { continue }
            let location = material.kind == .slides ? "slide" : "page"
            output.append(StudyItem(
                recordingID: provenanceID,
                materialID: material.id,
                brainID: material.brainID,
                sourceTitle: "\(material.name) · \(location.capitalized) \(pageNumber)",
                kind: .concept,
                prompt: "Explain \(concept.name) in your own words.",
                answer: answer,
                keys: conceptKeys(concept.name, answer),
                concept: concept.name
            ))
        }

        for page in material.pages.prefix(8) where !page.title.isEmpty && page.text.count >= 80 {
            let concept = StudyItem.normalize(page.title)
            guard !concept.isEmpty, !output.contains(where: { $0.concept == concept }) else { continue }
            output.append(StudyItem(
                recordingID: provenanceID,
                materialID: material.id,
                brainID: material.brainID,
                sourceTitle: "\(material.name) · \(material.kind == .slides ? "Slide" : "Page") \(page.number)",
                kind: .application,
                prompt: "What is the main idea of “\(page.title)”?",
                answer: String(page.text.prefix(520)),
                keys: conceptKeys(page.title, page.text),
                concept: page.title
            ))
        }
        return Array(output.prefix(18))
    }

    private static func usefulAnswer(for concept: String, on page: MaterialPage) -> String {
        let sentences = page.text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let matching = sentences.first { $0.localizedCaseInsensitiveContains(concept) }
        return String((matching ?? sentences.first ?? page.text).prefix(520))
    }

    private static func conceptKeys(_ concept: String, _ answer: String) -> [String] {
        let noise: Set<String> = ["this", "that", "with", "from", "which", "about", "there", "their",
                                  "the", "and", "for", "are", "was", "were", "into"]
        let words = (concept + " " + answer).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 && !noise.contains($0) }
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }.prefix(8).map { $0 }
    }
}
