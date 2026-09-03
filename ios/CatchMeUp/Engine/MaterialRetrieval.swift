import Foundation

struct RetrievedMaterialContext {
    let text: String
    let materials: [SupplementalMaterial]
    let searchedCount: Int
    let clipped: Bool

    var isEmpty: Bool { text.isEmpty }
}

enum MaterialRetriever {
    private struct Candidate {
        let material: SupplementalMaterial
        let page: MaterialPage
        let score: Double
        var cost: Int { page.combinedText.count + material.name.count + 48 }
    }

    static func context(for question: String, materials: [SupplementalMaterial],
                        budget: Int) -> RetrievedMaterialContext {
        let searchable = materials.filter { $0.state.isReady && !$0.pages.isEmpty }
        guard !searchable.isEmpty else {
            return RetrievedMaterialContext(text: "", materials: [], searchedCount: 0, clipped: false)
        }
        let terms = BrainRetriever.tokens(in: question)
        var candidates: [Candidate] = []
        for material in searchable {
            let conceptSet = Set(material.concepts.map { $0.name.lowercased() })
            for page in material.pages {
                let blob = page.combinedText.lowercased()
                var matches = 0.0
                for term in terms where blob.contains(term) {
                    matches += page.title.lowercased().contains(term) ? 2.4 : 1
                    if conceptSet.contains(where: { $0.contains(term) }) { matches += 0.35 }
                }
                if terms.isEmpty || matches > 0 {
                    candidates.append(Candidate(material: material, page: page, score: matches))
                }
            }
        }
        candidates.sort {
            if $0.score == $1.score { return $0.page.number < $1.page.number }
            return $0.score > $1.score
        }

        var chosen: [UUID: [MaterialPage]] = [:]
        var spent = 0
        var clipped = false
        for candidate in candidates {
            guard spent + candidate.cost <= budget else { clipped = true; continue }
            chosen[candidate.material.id, default: []].append(candidate.page)
            spent += candidate.cost
        }

        if chosen.isEmpty {
            for material in searchable {
                guard let page = material.pages.first else { continue }
                let cost = page.combinedText.count + material.name.count + 48
                guard spent + cost <= budget else { clipped = true; break }
                chosen[material.id] = [page]
                spent += cost
            }
        }

        let used = searchable.filter { chosen[$0.id] != nil }
        let blocks = used.compactMap { material -> String? in
            guard let pages = chosen[material.id] else { return nil }
            let contents = pages.sorted { $0.number < $1.number }.map { page in
                let location = material.kind == .slides ? "Slide" : "Page"
                let notes = page.speakerNotes.isEmpty ? "" : "\nSpeaker notes: \(page.speakerNotes)"
                return "[\(location) \(page.number)]\n\(page.text)\(notes)"
            }.joined(separator: "\n")
            return "## \(material.name)\n(Provided material, \(material.countLabel))\n\(contents)"
        }
        return RetrievedMaterialContext(text: blocks.joined(separator: "\n\n"), materials: used,
                                        searchedCount: searchable.count, clipped: clipped)
    }
}
