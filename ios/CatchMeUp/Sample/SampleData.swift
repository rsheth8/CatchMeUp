import Foundation

/// The library someone sees when they tap "Load two sample recaps" before they
/// have anything of their own.
///
/// It is deliberately a *week of work* rather than a pair of orphan recaps: two
/// brains, four recordings that reference each other, a meeting with its
/// workspace already filled in, and a lecture with real documents attached. The
/// features this app has that others don't — brains, supplemental material,
/// prequestions, meeting follow-ups — are invisible in a library of two
/// unconnected notes, and invisible features do not get tried.
///
/// The identifiers are fixed rather than fresh so the pieces can point at each
/// other: materials attach to a specific lecture, recordings belong to a
/// specific brain.
enum SampleData {

    // MARK: - Identity

    static let cs61aBrainID = UUID(uuidString: "5A17C0DE-0000-4000-A000-00000000C61A")!
    static let paymentsBrainID = UUID(uuidString: "5A17C0DE-0000-4000-A000-0000000B1115")!
    static let week3ID = UUID(uuidString: "5A17C0DE-0001-4000-A000-000000000003")!
    static let week4ID = UUID(uuidString: "5A17C0DE-0001-4000-A000-000000000004")!
    static let teamSyncID = UUID(uuidString: "5A17C0DE-0002-4000-A000-000000000001")!
    static let vendorPrepID = UUID(uuidString: "5A17C0DE-0002-4000-A000-000000000002")!

    // MARK: - Brains

    static var brains: [Brain] {
        [
            Brain(id: cs61aBrainID,
                  name: "CS 61A",
                  persona: "You are a CS 61A teaching assistant. Prefer SICP vocabulary, and when a "
                         + "question has a diagram answer, describe the diagram rather than "
                         + "paraphrasing around it.",
                  mode: .lecture,
                  createdAt: Date().addingTimeInterval(-86_400 * 21)),
            Brain(id: paymentsBrainID,
                  name: "Payments",
                  persona: "You are the memory of the payments team. Answer with what was actually "
                         + "decided and who owns it, and say plainly when something was left open.",
                  mode: .meeting,
                  createdAt: Date().addingTimeInterval(-86_400 * 30)),
        ]
    }

    // MARK: - Recaps

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

    /// A second lecture in the same brain, so the concept graph has something to
    /// connect and the study scheduler has more than one day of material.
    static let lectureRecapWeek4 = Recap(
        title: "CS 61A — Week 4: Recursion & tree recursion",
        tldr: [
            "A recursive function calls itself on a smaller instance of the same problem.",
            "Every recursive definition needs a base case, or it never stops.",
            "Tree recursion makes more than one recursive call, so the work branches.",
            "Trust the recursive leap: assume the smaller call is correct, then combine.",
        ],
        actionItems: nil,
        speakers: nil,
        bookmarks: [
            Bookmark(timestamp: "00:03:05", heading: "The recursive leap of faith", insight: "Assume the smaller call already works. Verify the base case and the combination step only."),
            Bookmark(timestamp: "00:11:40", heading: "Base cases are not optional", insight: "Missing base case is not a wrong answer, it's a stack overflow."),
            Bookmark(timestamp: "00:22:15", heading: "Fibonacci branches twice", insight: "Two recursive calls per frame is what makes naive fib exponential."),
            Bookmark(timestamp: "00:34:50", heading: "This will be on the exam", insight: "Count the calls in a tree-recursive trace. Draw the call tree, not the environment diagram."),
        ],
        detailedNotes: [
            DetailNote(heading: "What makes a function recursive",
                       content: "A recursive function is one whose body calls the function itself. The call is not circular because each call is on a smaller input, and because at least one input is handled without recursing at all. That case is the base case."),
            DetailNote(heading: "Linear vs. tree recursion",
                       content: "Factorial makes one recursive call per frame, so the frames form a line and the work is linear. Fibonacci makes two, so the frames form a tree and the number of calls grows exponentially. The shape of the recursion is what determines the cost, not the size of each frame."),
            DetailNote(heading: "Why memoization helps",
                       content: "Naive fib recomputes the same subproblems over and over — fib(30) computes fib(5) hundreds of times. Caching a result the first time it is computed collapses the tree back down to a line, which is why the same function goes from unusable to instant."),
        ],
        terms: [
            Term(term: "Base case", definition: "The input a recursive function answers directly, without calling itself."),
            Term(term: "Recursive case", definition: "The branch that reduces the problem and calls the function on the smaller input."),
            Term(term: "Tree recursion", definition: "Recursion that makes more than one recursive call per frame, so the calls branch."),
            Term(term: "Memoization", definition: "Caching a computed result so a repeated subproblem is answered rather than recomputed."),
        ],
        study: [
            "Write factorial recursively, then say which line is the base case and which is the recursive case.",
            "Draw the call tree for fib(5). Count the frames — why is it not 5?",
            "Add memoization to fib and explain, in terms of the call tree, why the cost changes.",
            "Give an input for which a missing base case fails loudly, and one where it fails silently.",
        ]
    )

    // MARK: - Transcripts

    static let meetingSegments: [Segment] = [
        Segment(start: 5, text: "Okay, let's start with the billing migration. The plan is to ship behind a flag on the twelfth.", speaker: "Speaker 1"),
        Segment(start: 135, text: "So nothing changes for customers until we do the full cutover on the twenty-sixth.", speaker: "Speaker 1"),
        Segment(start: 580, text: "My worry is proration. If someone changes plans mid-cycle during the window, the numbers can drift.", speaker: "Speaker 2"),
        Segment(start: 1085, text: "We'll freeze the legacy invoices read-only on the twenty-fifth so nothing gets written twice.", speaker: "Speaker 3"),
        Segment(start: 1470, text: "If cutover fails we flip the flag back and the freeze lifts automatically.", speaker: "Speaker 3"),
    ]

    static let lectureSegments: [Segment] = [
        Segment(start: 250, text: "A frame is a table of bindings, and it has a link to its parent frame.", speaker: nil),
        Segment(start: 922, text: "The parent of a call frame is the frame where the function was defined, not where it was called.", speaker: nil),
        Segment(start: 1668, text: "make_adder returns adder, and adder still remembers n, because its parent is the make_adder frame.", speaker: nil),
        Segment(start: 2160, text: "This will be on the exam. Given code, draw every frame and every arrow.", speaker: nil),
    ]

    static let lectureSegmentsWeek4: [Segment] = [
        Segment(start: 185, text: "Take the recursive leap of faith. Assume the smaller call already gives you the right answer.", speaker: nil),
        Segment(start: 700, text: "Without a base case this doesn't return a wrong answer, it runs until the stack gives out.", speaker: nil),
        Segment(start: 1335, text: "Fibonacci makes two recursive calls, so the frames branch into a tree instead of a line.", speaker: nil),
        Segment(start: 2090, text: "This will be on the exam. Draw the call tree and count the calls.", speaker: nil),
    ]

    // MARK: - Meeting workspace

    /// The meeting side of the app after the notes have been read once: owners
    /// assigned, one follow-up already done, and the outcomes separated from the
    /// tasks so a decision isn't buried in a checklist.
    static var teamSyncWorkspace: MeetingWorkspace {
        var workspace = MeetingWorkspace()
        workspace.agenda = "Billing migration: timeline, proration risk, and what support needs before cutover."
        workspace.analyzedAt = Date().addingTimeInterval(-86_400 * 3 + 3_600)

        var tests = MeetingFollowUp(title: "Finish the proration edge-case tests")
        tests.owner = "Priya"
        tests.deadlineText = "Thursday"
        tests.status = .inProgress
        tests.timestamp = "00:09:40"
        tests.evidence = "My worry is proration."
        tests.needsReview = false

        var onePager = MeetingFollowUp(title: "Write the support one-pager")
        onePager.owner = "Marcus"
        onePager.deadlineText = "Review with Priya Friday"
        onePager.status = .open
        onePager.timestamp = "00:18:05"
        onePager.needsReview = false

        var freeze = MeetingFollowUp(title: "Schedule the read-only freeze on legacy invoices")
        freeze.owner = "Dana"
        freeze.deadlineText = "The 25th"
        freeze.status = .done
        freeze.timestamp = "00:18:05"
        freeze.evidence = "We'll freeze the legacy invoices read-only on the twenty-fifth"
        freeze.needsReview = false
        freeze.editedByUser = true

        workspace.followUps = [tests, onePager, freeze]
        workspace.outcomes = [
            MeetingOutcome(kind: .decision,
                           text: "Ship behind a flag on the 12th, full cutover on the 26th.",
                           timestamp: "00:02:15",
                           evidence: "The plan is to ship behind a flag on the twelfth.",
                           reviewed: true),
            MeetingOutcome(kind: .decision,
                           text: "Legacy invoices stay read-only for one quarter so finance can reconcile.",
                           timestamp: "00:18:05",
                           reviewed: true),
            MeetingOutcome(kind: .blocker,
                           text: "Proration during the cutover window is untested.",
                           timestamp: "00:09:40",
                           evidence: "the numbers can drift"),
            MeetingOutcome(kind: .question,
                           text: "Who signs off that the rollback actually restores write access?",
                           timestamp: "00:24:30"),
        ]
        return workspace
    }

    /// A meeting that hasn't happened yet — agenda written, nothing recorded.
    /// This is the one shape of recording that has no audio at all, and it is
    /// easy to forget the app supports it.
    static var vendorPrepWorkspace: MeetingWorkspace {
        var workspace = MeetingWorkspace()
        workspace.agenda = """
        Vendor review — Thursday 10:00

        1. Q3 invoice discrepancies (bring the reconciliation sheet)
        2. Renewal terms — we want quarterly, they proposed annual
        3. Support SLA: what actually happens at the 4-hour mark
        """
        var carried = MeetingFollowUp(title: "Ask why the September invoice was reissued")
        carried.owner = "Marcus"
        carried.needsReview = false
        var terms = MeetingFollowUp(title: "Get the renewal terms in writing before the call")
        terms.owner = "Dana"
        terms.deadlineText = "Wednesday"
        terms.needsReview = false
        workspace.followUps = [carried, terms]
        return workspace
    }

    // MARK: - Recordings

    static var meetingRecording: Recording {
        var r = Recording(title: "Team sync", mode: .meeting)
        r.id = teamSyncID
        r.createdAt = Date().addingTimeInterval(-86_400 * 3)
        r.duration = 1680
        r.segments = meetingSegments
        r.recap = meetingRecap
        r.brainID = paymentsBrainID
        r.completedActions = [2]
        r.meeting = teamSyncWorkspace
        r.pretestedAt = r.createdAt
        return r
    }

    static var lectureRecording: Recording {
        var r = Recording(title: "cs61a-week3.m4a", mode: .lecture)
        r.id = week3ID
        r.createdAt = Date().addingTimeInterval(-86_400 * 9)
        r.duration = 2760
        r.segments = lectureSegments
        r.recap = lectureRecap
        r.brainID = cs61aBrainID
        r.pretestedAt = r.createdAt
        r.pretestAsked = 3
        r.pretestCorrect = 1
        return r
    }

    /// Left without a prequestion result on purpose: opening this one for the
    /// first time is what shows the pre-reading questions, and the offer only
    /// exists once.
    static var lectureRecordingWeek4: Recording {
        var r = Recording(title: "cs61a-week4.m4a", mode: .lecture)
        r.id = week4ID
        r.createdAt = Date().addingTimeInterval(-86_400 * 2)
        r.duration = 2490
        r.segments = lectureSegmentsWeek4
        r.recap = lectureRecapWeek4
        r.brainID = cs61aBrainID
        return r
    }

    static var meetingPreparation: Recording {
        var r = Recording(title: "Vendor review", mode: .meeting)
        r.id = vendorPrepID
        r.createdAt = Date().addingTimeInterval(-3_600 * 5)
        r.brainID = paymentsBrainID
        r.meeting = vendorPrepWorkspace
        return r
    }

    static var recordings: [Recording] {
        [meetingRecording, lectureRecording, lectureRecordingWeek4, meetingPreparation]
    }

    // MARK: - Documents

    /// Real files in the app bundle, imported through the ordinary path so the
    /// demo shows genuine extraction — page text, slide notes, OCR on the scan —
    /// rather than a hand-written list of pages that was never in a document.
    static let bundledMaterials: [(name: String, ext: String)] = [
        ("Week 3 Slides - Environment Diagrams", "pptx"),
        ("Week 3 Reading - Higher-Order Functions", "pdf"),
        ("Discussion 3 Worksheet", "pdf"),
    ]

    static var bundledMaterialURLs: [URL] {
        bundledMaterials.compactMap { Bundle.main.url(forResource: $0.name, withExtension: $0.ext) }
    }
}
