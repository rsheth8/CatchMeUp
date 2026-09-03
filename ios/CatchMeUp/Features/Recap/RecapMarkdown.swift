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

        list(RecapLayout.gistTitle(for: rec.mode), r.tldr)

        if rec.mode == .meeting {
            if let workspace = rec.meeting {
                list("Follow-ups", workspace.followUps.map {
                    "[\($0.status == .done ? "x" : " ")] \($0.title) — \($0.owner.isEmpty ? "Owner not specified" : $0.owner)\($0.deadlineText.isEmpty ? "" : " · \($0.deadlineText)")\($0.dueDate.map { " · Due " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")\($0.needsReview ? " (needs review)" : "")"
                })
                for kind in MeetingOutcomeKind.allCases {
                    list(kind.title, workspace.outcomes.filter { $0.kind == kind }.map {
                        "\($0.text)\($0.reviewed ? "" : " (unreviewed)")\($0.resolved ? " (resolved/superseded)" : "")"
                    })
                }
            } else { list("Action items", r.actionItems) }
        }

        if let marks = r.bookmarks, !marks.isEmpty {
            out += "## \(RecapLayout.bookmarksTitle(for: rec.mode))\n\n"
            for m in marks { out += "- **\(m.timestamp) — \(m.heading)**: \(m.insight)\n" }
            out += "\n"
        }

        if let notes = r.detailedNotes, !notes.isEmpty {
            out += "## \(RecapLayout.notesTitle(for: rec.mode))\n\n"
            for n in notes { out += "### \(n.heading)\n\n\(n.content)\n\n" }
        }

        if rec.mode == .lecture {
            if let terms = r.terms, !terms.isEmpty {
                out += "## Terms\n\n"
                for t in terms { out += "- **\(t.term)** — \(t.definition)\n" }
                out += "\n"
            }
            list("Study checklist", r.study)
            list("Action items", r.actionItems)
        } else {
            if let terms = r.terms, !terms.isEmpty {
                out += "## Terms\n\n"
                for t in terms { out += "- **\(t.term)** — \(t.definition)\n" }
                out += "\n"
            }
            list("Study checklist", r.study)
        }

        if let sp = r.speakers, !sp.isEmpty {
            out += "## Who was there\n\n"
            for s in sp { out += "- **\([s.label, s.name].filter { !$0.isEmpty }.joined(separator: " · "))** — \(s.said)\n" }
            out += "\n"
        }

        out += "---\n_Made with CatchMeUp_\n"
        return out
    }
}
