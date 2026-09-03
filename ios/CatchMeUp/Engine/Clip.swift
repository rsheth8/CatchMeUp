import Foundation

/// Ranked jump-backs from a query against recap bookmarks and terms.
/// Same job as `./catchup clip`: "mutex" → the 25 seconds where it was said.
struct ClipHit: Identifiable, Hashable {
    var id = UUID()
    var recordingID: UUID
    var title: String
    var heading: String
    var insight: String
    var timestamp: String
    var start: Double
    var score: Double
    var hasAudio: Bool
}

enum ClipSearch {
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
    }

    static func find(query: String, in recordings: [Recording]) -> ClipHit? {
        list(query: query, in: recordings).first
    }

    static func list(query: String, in recordings: [Recording], limit: Int = 12) -> [ClipHit] {
        let needles = tokens(query)
        guard !needles.isEmpty else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hits: [ClipHit] = []

        for rec in recordings where rec.recap != nil {
            let recap = rec.recap!
            let title = rec.displayTitle
            var candidates: [(blob: String, heading: String, insight: String, ts: String)] = []

            for bm in recap.bookmarks ?? [] {
                candidates.append((
                    "\(bm.heading) \(bm.insight) \(title)",
                    bm.heading, bm.insight, bm.timestamp
                ))
            }
            for term in recap.terms ?? [] {
                var ts = ""
                let needle = term.term.lowercased()
                if let match = (recap.bookmarks ?? []).first(where: {
                    "\($0.heading) \($0.insight)".lowercased().contains(needle)
                }) {
                    ts = match.timestamp
                }
                candidates.append((
                    "\(term.term) \(term.definition) \(title)",
                    term.term, term.definition, ts
                ))
            }

            for c in candidates {
                let words = Set(tokens(c.blob))
                let overlap = needles.filter { words.contains($0) }.count
                guard overlap > 0 else { continue }
                var score = Double(overlap)
                let heading = c.heading.lowercased()
                if heading == q || heading.hasPrefix(q + " ") || heading.hasSuffix(" " + q) {
                    score += 8
                } else if !q.isEmpty, heading.contains(q) {
                    score += 4
                }
                if !c.ts.isEmpty { score += 0.3 }
                let start = Bookmark(timestamp: c.ts).seconds ?? 0
                hits.append(ClipHit(
                    recordingID: rec.id,
                    title: title,
                    heading: c.heading,
                    insight: c.insight,
                    timestamp: c.ts.isEmpty ? "00:00:00" : c.ts,
                    start: start,
                    score: score,
                    hasAudio: rec.hasAudio
                ))
            }
        }

        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.start < rhs.start
        }
        var seen = Set<String>()
        var unique: [ClipHit] = []
        for hit in hits {
            let key = "\(hit.recordingID.uuidString)|\(hit.timestamp)|\(hit.heading.lowercased())"
            if seen.insert(key).inserted { unique.append(hit) }
            if unique.count >= limit { break }
        }
        return unique
    }
}
