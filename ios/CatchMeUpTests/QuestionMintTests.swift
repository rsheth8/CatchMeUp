import XCTest
@testable import CatchMeUp

/// Every question in the app comes out of here, so its output is the product's
/// surface: a clumsy prompt reads as a broken app even when the schedule behind
/// it is perfect.
final class QuestionMintTests: XCTestCase {

    private func lecture(terms: [Term] = [], bookmarks: [Bookmark] = [],
                         notes: [DetailNote] = [], study: [String] = []) -> Recording {
        Recording(
            title: "MIT 6.0002: Clustering",
            mode: .lecture,
            recap: Recap(title: "MIT 6.0002: Clustering",
                         bookmarks: bookmarks.isEmpty ? nil : bookmarks,
                         detailedNotes: notes.isEmpty ? nil : notes,
                         terms: terms.isEmpty ? nil : terms,
                         study: study.isEmpty ? nil : study)
        )
    }

    private func term(_ name: String, _ definition: String) -> Term {
        Term(term: name, definition: definition)
    }

    // MARK: Articles
    //
    // "What is a clustering?" was shipping in front of real lecture material.
    // Half of what a technical course names is an activity rather than a thing
    // you can have two of.

    func testGerundsTakeNoArticle() {
        for word in ["clustering", "overfitting", "hashing", "scaling", "indexing"] {
            XCTAssertEqual(QuestionMint.withArticle(word), word)
        }
    }

    func testAbstractNounsTakeNoArticle() {
        for word in ["complexity", "correctness", "determinism", "recursion", "classification"] {
            XCTAssertEqual(QuestionMint.withArticle(word), word)
        }
    }

    /// The rule has to stay narrow: "What is function?" reads worse than the
    /// article it removed.
    func testCountableNounsKeepTheirArticle() {
        XCTAssertEqual(QuestionMint.withArticle("function"), "a function")
        XCTAssertEqual(QuestionMint.withArticle("mutex"), "a mutex")
        XCTAssertEqual(QuestionMint.withArticle("string"), "a string")
        XCTAssertEqual(QuestionMint.withArticle("entity"), "an entity")
        XCTAssertEqual(QuestionMint.withArticle("exception"), "an exception")
    }

    func testVowelsGetAn() {
        XCTAssertEqual(QuestionMint.withArticle("array"), "an array")
        XCTAssertEqual(QuestionMint.withArticle("edge"), "an edge")
    }

    /// Acronyms are left exactly as the lecture wrote them. Ordinary title-case
    /// terms are lowered, because recaps capitalise headings — which does mean
    /// a bare surname comes out lowercase, a name being indistinguishable from
    /// a capitalised noun without more context than a term list carries.
    func testAcronymsAreLeftAlone() {
        XCTAssertEqual(QuestionMint.withArticle("HTTP"), "HTTP")
    }

    /// Found on real material: a GraphQL lecture asked "What is a graphql?".
    /// A capital past the first letter is a name — nothing reaches that shape
    /// by being title-cased — so these keep the spelling the lecture used and
    /// take no article.
    func testMixedCaseNamesKeepTheirCapitals() {
        for name in ["GraphQL", "JavaScript", "PostgreSQL", "NumPy", "iOS"] {
            XCTAssertEqual(QuestionMint.withArticle(name), name)
        }
    }

    /// The interior capital has to be what spares a term, not merely having one
    /// somewhere: an ordinary title-cased phrase is still lowered.
    func testTitleCasePhrasesAreStillLowered() {
        XCTAssertEqual(QuestionMint.withArticle("Environment Diagram"), "an environment diagram")
        XCTAssertEqual(QuestionMint.withArticle("Query"), "a query")
    }

    // MARK: Plurals

    func testPluralTermsAreRecognised() {
        for word in ["diagrams", "environment diagrams", "pointers", "invariants"] {
            XCTAssertTrue(QuestionMint.isPlural(word), "\(word) is plural")
        }
    }

    /// The s-endings that aren't plurals. Getting these wrong produces "what
    /// are a class", which is worse than the problem being solved.
    func testSingularWordsEndingInSAreNotPlurals() {
        for word in ["class", "bus", "basis", "analysis", "physics", "recursion"] {
            XCTAssertFalse(QuestionMint.isPlural(word), "\(word) is singular")
        }
    }

    func testAPluralTermIsAskedWithAre() {
        let items = QuestionMint.items(for: lecture(terms: [
            term("Environment Diagrams", "Drawings of the frames and bindings that exist while a program runs."),
        ]))
        guard let asked = items.first(where: { $0.kind == .term }) else {
            return XCTFail("a usable term should mint")
        }
        XCTAssertTrue(asked.prompt.hasPrefix("What are environment diagrams?"), asked.prompt)
    }

    // MARK: What gets minted

    func testATermBecomesAQuestionAndAnAnswer() {
        let items = QuestionMint.items(for: lecture(terms: [
            term("mutex", "A lock that only one thread can hold at a time while the others wait."),
        ]))
        let asked = items.filter { $0.kind == .term }
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].prompt.contains("a mutex"))
        XCTAssertFalse(asked[0].answer.isEmpty)
        XCTAssertGreaterThanOrEqual(asked[0].keys.count, 2, "offline grading needs something to match on")
    }

    func testEveryMintedItemStartsUnscheduled() {
        let items = QuestionMint.items(for: lecture(terms: [
            term("dendrogram", "A tree diagram showing the order in which clusters were merged together."),
        ]))
        XCTAssertFalse(items.isEmpty)
        for item in items {
            XCTAssertTrue(item.isNew, "a fresh question must not arrive with a history")
            XCTAssertEqual(item.memory.reps, 0)
        }
    }

    /// Words that appear in every lecture of a subject make questions worth
    /// nobody's time.
    func testGenericTermsAreDroppedEntirely() {
        let items = QuestionMint.items(for: lecture(terms: [
            term("variable", "A name bound to a value in the current environment."),
            term("example", "Something shown to illustrate a point being made."),
        ]))
        XCTAssertTrue(items.isEmpty)
    }

    func testAThinDefinitionIsNotWorthAQuestion() {
        let items = QuestionMint.items(for: lecture(terms: [term("mutex", "A lock.")]))
        XCTAssertTrue(items.isEmpty, "there's nothing to grade an answer against")
    }

    func testAnUnprocessedRecordingMintsNothing() {
        XCTAssertTrue(QuestionMint.items(for: Recording(title: "Untitled", mode: .lecture)).isEmpty)
    }

    func testCodeTermsAreAskedAsCode() {
        let items = QuestionMint.items(for: lecture(terms: [
            term("dict.get()", "Returns the value for a key, or a default you supply when the key is missing."),
        ]))
        guard let asked = items.first(where: { $0.kind == .term }) else {
            return XCTFail("a code term should still be worth asking about")
        }
        XCTAssertTrue(asked.prompt.contains("`dict.get()`"), "code belongs in backticks, not behind an article")
        XCTAssertFalse(asked.prompt.contains("a dict.get()"))
    }

    /// The same term shouldn't produce two identical cards, but a cloze on the
    /// same definition is a different retrieval route and is allowed to stay.
    func testOneTermGivesOneDefinitionQuestion() {
        let items = QuestionMint.items(for: lecture(terms: [
            term("centroid", "The mean position of all the points in a cluster, recomputed on every iteration."),
            term("centroid", "The mean position of all the points in a cluster, recomputed on every iteration."),
        ]))
        XCTAssertEqual(items.filter { $0.kind == .term }.count, 1)
    }
}
