import Foundation

enum SampleData {
    static let meetingRecap = Recap(
        title: "Payments sync — Q3 billing migration",
        tldr: [
            "Billing migration ships behind a flag on the 12th; full cutover targeted for the 26th.",
            "Legacy invoices stay read-only in the old system for one quarter.",
            "Support needs a one-pager before cutover so they can answer proration questions.",
        ],
        actionItems: [
            "Speaker 1 / Priya: finish the proration edge-case tests by Thursday.",
            "Speaker 2 / Marcus: write the support one-pager, review with Priya Friday.",
            "Speaker 3 / Dana: schedule the read-only freeze on legacy invoices for the 25th.",
        ],
        speakers: [
            SpeakerNote(label: "Speaker 1", name: "Priya", said: "Owns the migration and the test plan."),
            SpeakerNote(label: "Speaker 2", name: "Marcus", said: "Support lead, flagged the proration questions."),
            SpeakerNote(label: "Speaker 3", name: "Dana", said: "Infra — owns the freeze and rollback."),
        ],
        bookmarks: [
            Bookmark(timestamp: "00:02:15", heading: "Flag ships the 12th", insight: "Migration goes out dark; no customer impact until cutover."),
            Bookmark(timestamp: "00:09:40", heading: "Proration is the risk", insight: "Mid-cycle plan changes are where numbers can drift — needs explicit tests."),
            Bookmark(timestamp: "00:18:05", heading: "Read-only freeze on the 25th", insight: "Legacy invoices lock a day before cutover so nothing is written twice."),
            Bookmark(timestamp: "00:24:30", heading: "Rollback plan", insight: "If cutover fails, flip the flag back; freeze lifts automatically."),
        ],
        detailedNotes: [
            DetailNote(heading: "Timeline",
                       content: "The migration lands behind a feature flag on the 12th. The team watches metrics for two weeks, then does the full cutover on the 26th. Legacy invoices remain visible but read-only in the old system for one quarter so finance can reconcile."),
            DetailNote(heading: "Proration edge cases",
                       content: "The main worry is customers who change plans mid-cycle during the cutover window. Priya is adding tests for upgrade, downgrade, and cancel-then-resubscribe within the same billing period, plus a check that no invoice is generated twice."),
            DetailNote(heading: "Support readiness",
                       content: "Marcus will produce a one-page guide covering the three questions support expects: why an invoice looks different, how proration is calculated, and where to find the legacy invoice. Priya reviews it Friday."),
        ],
        terms: nil,
        study: nil
    )

    static let lectureRecap = Recap(
        title: "CS 61A — Week 3: Environment diagrams & higher-order functions",
        tldr: [
            "An environment diagram tracks frames, bindings, and parent links as code runs.",
            "Every function remembers the frame it was defined in — that's its parent.",
            "Higher-order functions take or return functions; closures capture their defining frame.",
            "Practice: be able to draw the diagram for a nested-function example by hand.",
        ],
        actionItems: nil,
        speakers: nil,
        bookmarks: [
            Bookmark(timestamp: "00:04:10", heading: "What a frame is", insight: "A frame is a table of bindings plus a link to its parent frame."),
            Bookmark(timestamp: "00:15:22", heading: "Def vs. call frame", insight: "The parent of a call frame is the frame where the function was defined, not where it was called."),
            Bookmark(timestamp: "00:27:48", heading: "Worked example: make_adder", insight: "Classic closure — the returned function keeps a reference to n."),
            Bookmark(timestamp: "00:36:00", heading: "This will be on the exam", insight: "Given code, draw every frame and arrow. Partial credit is per-binding."),
        ],
        detailedNotes: [
            DetailNote(heading: "Frames and environments",
                       content: "When Python calls a function it creates a new frame. The frame holds local bindings and a parent pointer. Name lookup checks the current frame, then its parent, and so on up to the global frame. The chain of frames reachable from the current one is the environment."),
            DetailNote(heading: "Parent frames",
                       content: "A function's parent frame is fixed when the function is defined — it is the frame that was active at def time. This is why a function defined inside another function can still see the outer function's locals after the outer call has returned."),
            DetailNote(heading: "Higher-order functions",
                       content: "A higher-order function either takes a function as an argument (like map or filter) or returns one (like make_adder). Returning a function that refers to a local variable creates a closure: the variable stays alive as long as the returned function does."),
        ],
        terms: [
            Term(term: "Frame", definition: "A table of name→value bindings created for one function call, with a link to its parent frame."),
            Term(term: "Parent frame", definition: "The frame in which a function was defined; where name lookup continues if a name isn't local."),
            Term(term: "Closure", definition: "A function together with the environment it captured at definition time."),
            Term(term: "Higher-order function", definition: "A function that takes a function as an argument or returns one."),
        ],
        study: [
            "Draw the environment diagram for make_adder(3) then adder(4). Label every frame's parent.",
            "Explain in one sentence why the parent of a call frame is the def frame, not the call site.",
            "Write a higher-order function compose(f, g) that returns x → f(g(x)).",
        ]
    )

    static let meetingSegments: [Segment] = [
        Segment(start: 5, text: "Okay, let's start with the billing migration. The plan is to ship behind a flag on the twelfth.", speaker: "Speaker 1"),
        Segment(start: 135, text: "So nothing changes for customers until we do the full cutover on the twenty-sixth.", speaker: "Speaker 1"),
        Segment(start: 580, text: "My worry is proration. If someone changes plans mid-cycle during the window, the numbers can drift.", speaker: "Speaker 2"),
        Segment(start: 1085, text: "We'll freeze the legacy invoices read-only on the twenty-fifth so nothing gets written twice.", speaker: "Speaker 3"),
        Segment(start: 1470, text: "If cutover fails we flip the flag back and the freeze lifts automatically.", speaker: "Speaker 3"),
    ]

    static var meetingRecording: Recording {
        Recording(title: "Team sync", mode: .meeting, audioFilename: nil, duration: 1680,
                  segments: meetingSegments, recap: meetingRecap)
    }

    static var lectureRecording: Recording {
        Recording(title: "cs61a-week3.m4a", createdAt: Date().addingTimeInterval(-86_400 * 2),
                  mode: .lecture, audioFilename: nil, duration: 2760, segments: [], recap: lectureRecap)
    }

    static var recordings: [Recording] { [meetingRecording, lectureRecording] }
}
