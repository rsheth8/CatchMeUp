import Foundation

enum RecapMarkdown {
    static func build(_ rec: Recording, _ r: Recap) -> String {
        var out = "# \(r.title ?? rec.displayTitle)\n\n"
        out += "_\(rec.mode.title) · \(rec.createdAt.formatted(date: .long, time: .shortened))_\n\n"

        func list(_ title: String, _ items: [String]?) {
            guard let items, !items.isEmpty else { return }
            out += "## \(title)\n\n"
            for i in items { out += "- \(i)\n" }
            out += "\n"
        }

        if rec.mode == .meeting {
            list("TL;DR", r.tldr)
            list("Action items", r.actionItems)
        } else {
            list("What you missed", r.tldr)
        }

        if let marks = r.bookmarks, !marks.isEmpty {
            out += "## \(rec.mode == .meeting ? "Bookmarks" : "Key moments")\n\n"
            for m in marks { out += "- **\(m.timestamp) — \(m.heading)**: \(m.insight)\n" }
            out += "\n"
        }

        if let notes = r.detailedNotes, !notes.isEmpty {
            out += "## \(rec.mode == .meeting ? "Detailed notes" : "Notes by topic")\n\n"
            for n in notes { out += "### \(n.heading)\n\n\(n.content)\n\n" }
        }

        if let terms = r.terms, !terms.isEmpty {
            out += "## Terms\n\n"
            for t in terms { out += "- **\(t.term)** — \(t.definition)\n" }
            out += "\n"
        }

        list("Study checklist", r.study)

        if let sp = r.speakers, !sp.isEmpty {
            out += "## Who was there\n\n"
            for s in sp { out += "- **\([s.label, s.name].filter { !$0.isEmpty }.joined(separator: " · "))** — \(s.said)\n" }
            out += "\n"
        }

        out += "---\n_Made with CatchMeUp_\n"
        return out
    }
}
