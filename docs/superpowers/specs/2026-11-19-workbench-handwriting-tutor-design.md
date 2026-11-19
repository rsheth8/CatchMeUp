# Workbench: handwritten problem solving for advanced classes - design

Status: draft for review. Date: 2026-11-19. Working name: **Workbench** (product name still open).

## 1. Problem

CatchMeUp's study loop is built for things you remember: terms, cloze, multiple
choice, short explanations. It schedules each `StudyItem` as a fixed
prompt/answer pair with FSRS-5 and grades a typed answer by keyword overlap plus
an optional model pass.

That fails students in advanced, problem-solving classes (calculus, linear
algebra, differential equations, physics, chemistry, proofs):

1. **Fixed cards train answer memorization.** Seeing the same integral again in
   six days tests whether you remember its answer, not whether you can integrate.
2. **Only final answers are graded.** A sign error in step 3 looks the same as
   not knowing the method at all, so feedback cannot point at the actual mistake.
3. **There is no way to enter work.** Typing math on a phone is miserable, and
   the recap prompt explicitly forbids LaTeX (`ios/CatchMeUp/Engine/Prompts.swift:84`).
4. **The real problems are missing.** Professors work examples on a whiteboard
   the audio cannot see; the practice that matters lives in homework sets and
   past exams.

Workbench adds an iPad canvas where students write solutions with Apple Pencil.
A tutor reads each step as it is written, marks the first wrong step, asks a
question about it instead of giving the answer, and links the lecture moment
where that step was taught. Spaced review schedules **skills**, each served with
a fresh problem.

## 2. Decisions already made (user, 2026-11-18)

| Topic | Decision |
|---|---|
| Audience | Advanced, harder classes. Scope as broadly as possible, phased. |
| Platform | iPad with Apple Pencil as the primary surface. |
| Check timing | User picks in settings. Default: live check on each pencil pause. Alternative: check at end. |
| Wrong step | Socratic question first, plus the lecture moment. The fix is revealed only on request. |
| Problem sources | The student's uploads (homework, past exams) first. Generated variants only when two independent solves agree. |
| Scheduling | Spaced review schedules skills, with a fresh problem each review. |
| Inspiration | Goblins (goblins.com), a K-12 live-handwriting math tutor. Our edge: we know the student's own lectures, notation, problem sets and exam date. |

Standing constraints from earlier decisions: users bring their own API key, there
is no backend, sign-in stays, and App Review gets no test API key.

## 3. Goals and non-goals

**Goals**

- Step-level feedback on handwritten work that is right far more often than it is wrong, and that never silently "fixes" the student's work.
- Skills, not problems, as the unit of spaced review, with problem pools drawn from the student's own material.
- Works offline in a reduced form (self-check against reference steps) and fully with any vision-capable BYO model.
- One shared pipeline for live, check-at-end, and iPhone photo modes.
- Measured quality: an evaluation harness with ship gates, not prompt vibes.

**Non-goals for this spec**

- A full iPad redesign of the whole app (NavigationSplitView everywhere). Only the Workbench screen gets a purpose-built iPad layout. The app-wide iPad pass should be its own project.
- Teacher dashboards, classes, or sharing.
- Voice think-aloud (Goblins does this). Listed under Phase 2 options.
- A server. Everything runs on device plus the user's chosen model provider.

## 4. What exists today

Grounded in the code on `main` at `af6d320`. Paths are relative to `ios/`.

### Study core

- `CatchMeUp/Study/StudyModels.swift:11` `StudyItemKind`: `term, moment, concept, cloze, choice, application`. `StudyItem` (`:51`) carries provenance (`recordingID` required, `materialID?`, `brainID?`, `timestamp?`), the question (`prompt`, `answer`, `keys`, `choices`), `concept` (normalised dedupe key), `memory: FSRS.Memory`, sync fields (`updatedAt`, `deleted`).
- `CatchMeUp/Study/FSRS.swift`: pure FSRS-5. `schedule(_:grade:now:params:)` (`:181`), `preview` (`:243`), `Grade.suggested(fromVerdict:)`.
- `CatchMeUp/Study/StudyStore.swift`: three JSON files (`study-items.json`, `study-log.json`, `exam-plans.json`) in Application Support or the iCloud Drive container. `queue(mode:...)` (`:178`) builds review, flashcard, exam and drill queues and `interleave` (`:251`) round-robins by brain and avoids the same concept twice in a row. `record(...)` (`:406`) schedules and logs. `parameters(for:)` (`:428`) raises retention before an exam. `add(_:)` (`:452`) dedupes by `brainID|concept`.
- `CatchMeUp/Study/Grading.swift`: offline keyword grading (`:105`) plus `model(_:typed:config:)` (`:189`). `firstJSONObject(in:)` (`:310`).
- `CatchMeUp/Study/QuestionMint.swift`: deterministic offline minting from recaps; `enrich` (`:259`) adds model-written `.application` items.
- `CatchMeUp/Features/Study/ReviewSessionView.swift`: phases `asking` / `revealed`; kind-specific branches all key on `.choice` (`:151, 360, 364, 459, 470`). `playMoment` (`:531`) plays the lecture at `timestamp - 4s`.

### Models, materials, shell

- `CatchMeUp/Engine/LLMClient.swift`: `complete(system:user:maxTokens:)` (`:12`). Anthropic and OpenAI-compatible. **Text only, single user turn, no streaming, no retries, 300 s timeout.**
- `CatchMeUp/Settings/Settings.swift`: `Provider` list (Anthropic, OpenAI, Gemini, Groq, OpenRouter, DeepSeek, Mistral, Together, xAI, Ollama, custom), `ProviderConfig`, `EngineKind { demo, onDevice, apiKey }`, API key in Keychain. On-device engine is Apple Foundation Models, text only.
- `CatchMeUp/Materials/`: PDF and PPTX only. PDFs are rendered once at 760x980 for thumbnails, with Vision OCR as a fallback when a page has no text layer. VisionKit document scanner produces PDFs. No photo import. Materials are stored locally and do not sync.
- `CatchMeUp/App/RootView.swift`: `TabView` with `.sidebarAdaptable` on regular width (iOS 18+). No `NavigationSplitView`, no PencilKit anywhere. `BETA.md:89`: "iPad runs the iPhone layout."
- `CatchMeUp/Design/Markdown.swift`: Markdown via `AttributedString`. No math rendering.
- Build: XcodeGen (`project.yml`, directory-globbed sources, so new files need only `xcodegen generate`), iOS 17 deployment target, Swift 5 language mode, SPM deps ZIPFoundation and GoogleSignIn. XCTest only. **No iOS CI** (the only workflow is the Python CLI).

### Hazards found while mapping (must fix before adding anything)

1. **Unknown enum values wipe the study bank.** `StudyStore.load()` (`StudyStore.swift:635`) decodes the whole array with `try?`. `StudyItem.init(from:)` throws on an unknown `kind` raw value. So if a newer build writes one `.skill` item to iCloud Drive and an older build on another device reads the file, decoding fails, `items` stays empty, and the next save overwrites the file with nothing. The same applies to logs and plans. Found by reading the code; Stream 0a must reproduce it in a test before fixing.
2. **Study files only merge at launch.** `StudyStore.mergeFromDisk()` (`:674`) is called only from app housekeeping, not from the `NSMetadataQuery` that `LibraryStore` uses, and `unionMetadata` does not cover study files when the iCloud toggle flips.

If the App Store build ships before hazard 1 is fixed, every shipped build carries it forever. **Stream 0a should land before the 1.0 release.**

## 5. Research that shapes the design

Summarised from a research pass on 2026-11-19. Sources are in section 24. Items marked (verify) come from very recent sources and should be re-checked by the stream that depends on them.

- **Transcription, not judgment, is the dominant failure.** In a 2026 study of vision-LLM grading of handwritten university STEM work, 87% of the best model's errors were transcription failures. Large VLMs get symbols right and fail on 2D structure (fractions, matrices, integrals). Zero-shot expression rates on CROHME sit around 46 to 60% for GPT-4o, Gemini 2.5 Flash and Qwen2.5-VL; no published numbers exist yet for the newest Claude, GPT or Gemini models.
- **VLMs over-correct.** A transcriber that has seen the right answer tends to transcribe what the student *should* have written. That is fatal for a tutor.
- **Reasoning models judge steps much better.** On ProcessBench (find the first wrong step), reasoning models reach about 88 F1 against about 62 for GPT-4o. Feeding text instead of handwriting images to the judge gives the largest gain (FERMAT).
- **Deterministic checks are cheap and strong.** WeBWorK's production method, random-point numeric equivalence, settles most "is step n equivalent to step n-1" questions in milliseconds. No mature pure-Swift CAS exists; SymPy via Pyodide is proven on the App Store but costs a ~300 MB heap and seconds of cold start.
- **Apple does not expose math recognition.** Math Notes is not available to developers. `PKStrokeRecognizer` (iPadOS 27) is text only and flattens 2D structure (verify). Vision `RecognizeTextRequest` is unsuitable for math.
- **Rendering:** SwiftMath (native, MIT) handles most math mode; KaTeX in a shared `WKWebView` covers the rest, including `mhchem` chemistry.
- **Chemistry:** no recognizer ships for iOS. Image-to-SMILES models score below 42% on real-world images. The practical path is letting the vision LLM judge mechanism drawings directly, with RDKit.js for exact product comparison when a SMILES answer exists.
- **Answer keys:** self-consistency plus a program or numeric check is the standard verification; no study measures two-solve agreement directly, so we add a deterministic check on top.

Design consequences, applied throughout:

1. Split the pipeline into **transcribe, then judge, then verify**. The transcriber never sees the reference solution.
2. The judge reads **confirmed LaTeX text**, never images, and uses the strongest reasoning model the user has.
3. A **deterministic verifier** backs every algebraic verdict. The tutor only flags a step when the evidence agrees; otherwise it asks a neutral "walk me through this step".
4. **Show the transcription** next to every line so misreads are visible and correctable.

## 6. Architecture overview

```
iPad Workbench screen                                   WorkbenchCore (local Swift package, pure, macOS-testable)
+---------------------------+                           +-----------------------------------------------+
| Problem pane | Canvas     |   pause / Check / photo   |  StepSegmenter  -> [StepSlice]                |
| statement    | lanes      | ------------------------> |  StepTranscriber (vision model, no answer key) |
| hints        | margin     |                           |  StepJudge (reasoning model, text only)        |
| source link  | marks +    | <------------------------ |  MathVerifier (LaTeX parser + numeric checks)  |
|              | LaTeX chips|   StepFeedback            |  DecisionTable -> verdict shown to student     |
+---------------------------+                           |  HintLadder, GradeMapper, ServingPolicy        |
        |                                               |  ProblemExtractor, VariantGenerator            |
        v                                               |  ModelTransport (protocol)                     |
StudyStore (+ problems.json, attempts.json)             +-----------------------------------------------+
FSRS schedules StudyItem(kind: .skill)                          ^                     ^
MaterialStore (problem sets, exams, solutions)                  | LiveTransport       | ReplayTransport
                                                                | (LLMClient v2)      | (fixtures: tests,
                                                                                        showcase, App Review)
```

**Why a local Swift package.** The pipeline (models, parser, verifier, decision
table, prompts, serving policy) has no UIKit dependency. Putting it in
`ios/Packages/WorkbenchCore` lets it build and test with `swift test` on macOS in
seconds, lets the eval harness link the exact production code, and gives
parallel streams a hard module boundary. XcodeGen supports local packages. The
app target keeps PencilKit, SwiftUI and persistence.

## 7. Data model

All new records follow the existing sync pattern: `Codable`, `id`, `updatedAt`,
`deleted` tombstone, tolerant `init(from:)`.

### 7.1 Skills are study items

A skill ("integration by parts", "Le Chatelier shifts", "proof by induction") is a
`StudyItem` with a new kind `.skill`.

- `prompt` = skill name, `answer` = one-paragraph method summary, `concept` = normalised skill key, `timestamp` / `recordingID` = the lecture moment where it was taught when known.
- **Why reuse `StudyItem`:** queues, interleaving, exam-date retention, weakness scores, calibration, streaks, review logs and sync all work unchanged. A parallel scheduled entity would duplicate all of that.
- `.skill` items are excluded from text modes (review, flashcards, practice exam, drill) and served by a new `StudyMode.problems`. They count toward due totals and the exam planner.
- `recordingID` is non-optional today; skills from uploads use the material id, matching what `MaterialQuestionMint` already does.

### 7.2 New types (in WorkbenchCore)

```swift
enum SubjectProfileID: String, Codable {
    case calculus, linearAlgebra, differentialEquations, physics, statistics,
         generalChemistry, organicChemistry, proofs, csTheory, writtenResponse
}

struct Problem: Codable, Identifiable, Hashable {
    var id: UUID
    var skillItemID: UUID            // StudyItem(kind: .skill)
    var brainID: UUID?
    var subject: SubjectProfileID
    var origin: ProblemOrigin
    var statement: String            // Markdown with $...$ / $$...$$ math
    var figureFilename: String?      // cropped from the source page, local only
    var parts: [ProblemPart]         // (a), (b), ...; single-part problems have one
    var difficulty: Int?             // 1...5
    var servedCount: Int
    var lastServedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var deleted: Bool
}

enum ProblemOrigin: Codable, Hashable {
    case uploaded(materialID: UUID, page: Int, region: NormalizedRect)
    case lecture(recordingID: UUID, seconds: Double)
    case variant(parentID: UUID, generatorVersion: Int)
    case userEntered
}

struct ProblemPart: Codable, Hashable, Identifiable {
    var id: UUID
    var label: String                // "a", "b", or ""
    var prompt: String
    var reference: ReferenceSolution?
    var answer: AnswerSpec?
}

struct ReferenceSolution: Codable, Hashable {
    var steps: [ReferenceStep]       // LaTeX + short justification
    var source: KeySource
}

enum KeySource: Codable, Hashable {
    case uploadedKey(materialID: UUID, page: Int)
    case dualSolve(agreedAt: Date, models: [String], deterministicCheck: Bool)
    case userProvided
    case unverified                  // never served as a graded problem
}

enum AnswerSpec: Codable, Hashable {
    case expression(latex: String, variables: [VariableDomain])
    case numeric(value: Double, relativeTolerance: Double, unit: String?)
    case equationSet([String])
    case matrix(rows: [[String]])
    case proof(rubric: [RubricPoint])
    case structure(smiles: String)
    case freeResponse(rubric: [RubricPoint])
}

struct Attempt: Codable, Identifiable, Hashable {
    var id: UUID
    var problemID: UUID
    var partID: UUID
    var skillItemID: UUID
    var brainID: UUID?
    var sessionID: UUID
    var startedAt: Date
    var finishedAt: Date?
    var timing: CheckTiming          // .live, .atEnd, .photo, .selfCheck
    var steps: [StepRecord]
    var maxHint: HintLevel
    var outcome: AttemptOutcome
    var disputes: Int
    var usage: ModelUsage            // tokens and calls, for the cost display
    var drawingFilename: String?     // local only
    var updatedAt: Date
    var deleted: Bool
}

struct StepRecord: Codable, Hashable {
    var index: Int
    var transcription: String        // LaTeX as read
    var transcriptionConfidence: Double
    var userEdited: Bool
    var verdict: StepVerdict         // .pending, .ok, .flagged, .unclear, .final(correct:)
    var errorKind: ErrorKind?
    var feedback: String?
    var verifier: VerifierOutcome?
    var disputed: Bool
    var checkedAt: Date?
}

enum HintLevel: Int, Codable { case none, question, nudge, workedStep, fullSolution }
enum AttemptOutcome: Codable, Hashable { case clean, recovered, neededHint, revealed, abandoned, selfGraded(Int) }
```

### 7.3 Persistence and sync

| Data | File | Sync | Merge |
|---|---|---|---|
| Skills | `study-items.json` (existing) | iCloud Drive | newest `updatedAt` wins |
| Problems | `problems.json` | iCloud Drive | newest wins |
| Attempts | `attempts.json` | iCloud Drive | union by id (events, like review logs) |
| Drawings | `Workbench/Drawings/<attemptID>.drawing` | local | n/a |
| Figures | `Materials/<materialID>/figure-<problemID>.png` | local | n/a |

Every decoder is per element and tolerant (Stream 0a), so an older build keeps
records it does not understand instead of dropping the file.

### 7.4 Materials

Add an optional `purpose: MaterialPurpose?` (`notes`, `problemSet`, `exam`,
`solutions`) and `pairedMaterialID: UUID?` (a solutions PDF paired with its
problem set) to `SupplementalMaterial`. Missing values decode as `notes`, so
existing materials are unchanged. Page rendering for problem extraction uses a
long edge of about 1600 px, not the 760x980 thumbnail, and is done on demand.

## 8. Problem sources and skill extraction

### 8.1 Uploads (primary)

Entry points: "Add problem set / exam" in the Brain knowledge card and in the
Study tab's Problems section. Accepts PDF, scans (existing VisionKit scanner),
and photos (new `PhotosPicker`; needs `NSPhotoLibraryUsageDescription`).

Pipeline (`ProblemExtractor`):

1. Render each page at about 1600 px. Send the image plus the page's text layer (when present) to the vision model.
2. Model returns problems with: number, parts, statement in Markdown + LaTeX, figure bounding box, proposed skill names, and whether a worked answer appears on the page.
3. Answer keys: if a `solutions` material is paired, or the same document contains answers, match by problem number and part, and store as `KeySource.uploadedKey`. Run the verifier on the key's final answer against the statement where possible (substitution checks for equations and ODEs).
4. **Skill mapping:** the model receives the brain's current skill list and must reuse an existing skill when one fits. Granularity rule: a skill is a method a student would name on a study guide ("u-substitution"), never "Problem 3".
5. **Confirm screen:** the student sees extracted problems grouped by skill, can merge, rename, or drop, then adds them. Default on, skippable (open decision 2).

Problems without any key are stored as `unverified`. They can be attempted in
self-check mode but never generate graded feedback until a key is produced by
the variant verifier (section 13) or the student provides one.

### 8.2 Lectures (secondary)

For brains with Workbench enabled, a separate pass over each recap proposes
skills and attaches lecture moments ("worked example of related rates at 34:12").
This is what powers "hear how your professor did this step". It is a new pass,
not a change to the recap prompt, so the recap pipeline is untouched.

### 8.3 Student-entered

"New problem" lets a student type or photograph a single problem (for example
from a textbook). It goes through the same extraction and key logic.

## 9. Canvas and step segmentation

### 9.1 Canvas

- `PKCanvasView` wrapped in `UIViewRepresentable`, `PKToolPicker` with pen, eraser, lasso. `drawingPolicy` defaults to Pencil only, with a setting to allow finger drawing for iPads without a Pencil.
- **Ruled lanes** (default 72 pt tall). One lane is one step. A lane grows when strokes extend past it (tall fractions, matrices, integrals). A "join with previous" control merges lanes for a multi-line step. Lanes make segmentation deterministic and give the transcriber a clean, single-step crop. (Open decision 1: lanes versus a free canvas with automatic line detection.)
- Right gutter per lane: status mark (spinner, check, amber question mark for unclear, orange ring for flagged) and the rendered transcription chip.

### 9.2 Segmentation (`StepSegmenter`, pure)

Input: stroke records `(id, renderBounds, startTime, endTime)` extracted from
`PKDrawing.strokes` (`path.creationDate` plus the last point's `timeOffset`),
plus the lane layout. Output: `[StepSlice]` with stroke ids, union bounds, and a
content hash.

- Assign each stroke to the lane containing its `renderBounds.midY`; strokes spanning lanes extend the lane they started in.
- A lane is **dirty** when its content hash differs from the last checked hash.
- Pure geometry over value types, so it is fully unit tested without PencilKit.

### 9.3 Pause detection and crops

- Debounce `canvasViewDrawingDidChange`. After `pauseDelay` (default 1.5 s, setting range 0.8 to 4 s) with no new strokes, check every dirty lane, oldest first.
- A new stroke in a lane cancels that lane's in-flight check. At most one transcription and one judge call in flight.
- Crop: build a sub-drawing of the lane's strokes and render `PKDrawing.image(from:scale:)` over the union bounds plus padding, on white, grayscale, long edge at most 1024 px. Cache by content hash so an unchanged lane is never re-sent.

## 10. Check pipeline

```
dirty lane -> crop -> Transcriber -> transcription chip shown
                                  -> Judge(prior confirmed steps as LaTeX, reference, new step)
                                  -> Verifier(relation-aware)
                                  -> DecisionTable -> mark + feedback card
```

### 10.1 Transcriber

- Inputs: the crop, the problem statement, and prior steps' transcriptions (for notation only). **Never** the reference solution or any verdict.
- Prompt rules: transcribe verbatim, keep every mistake, never simplify, mark illegible symbols as `\text{?}`, return per-symbol low-confidence spans.
- Output JSON: `{ "latex": "...", "confidence": 0.0, "uncertain": ["..."], "is_blank_or_scribble": false }`.
- Model: the user's fast vision model.
- Low confidence (below 0.6) or any `\text{?}`: the chip turns amber and asks the student to confirm or fix it before judging. That is cheaper than a wrong verdict.

### 10.2 Judge

- Inputs: problem, part, reference solution, all prior steps as confirmed LaTeX, the new step's LaTeX, subject profile instructions, and the student's hint history. Text only.
- Model: the strongest reasoning model the user has configured ("tutor model", see section 15).
- Output JSON:

```json
{
  "verdict": "ok | flagged | unclear | final_correct | final_incorrect",
  "confidence": 0.0,
  "relation": "equivalent | derivative | antiderivative | substitution | new_equation | restatement | conclusion",
  "error_kind": "arithmetic | sign | algebra | calculus_rule | concept | notation | units | logic_gap | incomplete | none",
  "error_span": "sub-expression of the new step that is wrong",
  "question": "Socratic question, at most 25 words, never states the fix",
  "nudge": "stronger hint, still no answer",
  "worked_step": "LaTeX of a correct version of this step",
  "different_valid_method": false
}
```

- "Different valid method" matters in advanced classes: a correct path that differs from the reference must be accepted. The judge is told the reference is one valid solution, not the only one.

### 10.3 Verifier (`MathVerifier`, deterministic)

The judge's `relation` tells the verifier what to check between the previous
step and the new one:

| Relation | Check |
|---|---|
| `equivalent` | both sides evaluate equal at random points (both expressions, or `lhs - rhs` of both equations up to a nonzero factor) |
| `derivative` | numeric derivative of the previous expression (central differences) matches the new one |
| `antiderivative` | numeric derivative of the new expression matches the integrand, ignoring the constant |
| `substitution` | plugging the claimed solution into the original equation gives zero |
| other | `unknown` |

It also checks final answers against `AnswerSpec`: expression equivalence,
numeric value with tolerance and units, matrix entries. Domain handling follows
WeBWorK: sample inside declared variable domains, skip points where both sides
are undefined, require at least 5 agreeing points.

### 10.4 Decision table

What the student sees is decided by evidence, not by the judge alone:

| Judge | Verifier | Shown |
|---|---|---|
| ok | equivalent or unknown | ok (quiet check mark) |
| ok | not equivalent | **unclear**: neutral "walk me through this step"; logged as a disagreement for the eval set |
| flagged | not equivalent | **flagged**, with the question |
| flagged | equivalent | unclear, unless `error_kind` is `units`, `notation`, `concept` or `logic_gap` (things the verifier cannot see), then flagged |
| flagged | unknown | flagged when confidence is at least 0.8, else unclear |
| final_correct / final_incorrect | answer check | the verifier wins when it can decide; otherwise the judge, with confidence of at least 0.8 required to say "incorrect" |

The worst outcome is telling a student who is right that they are wrong. Every
ambiguous cell falls to "unclear", which costs the student a moment of
explanation, not trust.

### 10.5 Hint ladder

Per the decision in section 2. On a flagged step:

1. **Question** (automatic): the judge's `question`, plus "Hear how your professor did this" when the skill has a lecture moment.
2. **Nudge** (tap): a stronger hint, still without the answer.
3. **Worked step** (tap): the correct version of this one step, rendered.
4. **Full solution** (tap, with a confirm): the reference solution, step by step.

The student answers a question by writing a corrected step, which is checked
like any other. "I think I'm right" accepts the step, records a dispute,
excludes the step from the grade penalty, and adds the case to the local
disagreement log that feeds the eval set (local only; exporting it is an
explicit developer action).

### 10.6 Grade mapping (`GradeMapper`)

Suggested FSRS grade for the skill, pre-selected on the existing grade buttons:

| Outcome | Suggested grade |
|---|---|
| Clean solve, no flags | good (student may pick easy) |
| Recovered after the question only | hard |
| Needed the nudge | hard |
| Needed the worked step or full solution | again |
| Abandoned | again |
| Self-check mode | student's own grade |

Disputed steps the student upheld are ignored.

### 10.7 Check at end

Same pipeline, triggered by a Check button: all dirty lanes are transcribed in
one batched request (multi-image), then judged sequentially so each step sees
confirmed prior steps. Feedback appears down the margin at once; the first
flagged step is scrolled into view.

## 11. Math engine (in WorkbenchCore)

- **LaTeX parser** to an AST: numbers, variables, implicit multiplication, `\frac`, `^`, `_`, `\sqrt`, trig and inverse trig, `\ln`, `\log`, `\exp`, `\left( \right)`, absolute value, `\cdot`, `\times`, `\pi`, `e`, factorial, matrices (`pmatrix`, `bmatrix`), equations and inequalities. Unknown constructs return `unsupported`, which makes the verifier answer `unknown`, never a wrong verdict.
- **Evaluator**: complex-safe double evaluation, matrix arithmetic, domain sampling, central differences.
- **Units** (physics, chemistry): a small dimensional-analysis table for SI base units and common derived units, used to check that a step's units are consistent.
- **Renderer**: SwiftMath `MathView` for chips, statements and feedback. When SwiftMath cannot parse an expression, or it contains `\ce{}`, fall back to KaTeX in one shared offscreen `WKWebView` that renders to an image and caches by string.
- `Markdown.swift` learns `$...$` and `$$...$$`. Once rendering ships, `Prompts.answerFormat` stops forbidding LaTeX for math content (Ask answers benefit too).
- Later, if symbolic needs appear (integrals with constants of integration across forms, matrix identities), add SymPy via Pyodide in a background `WKWebView`, bundled locally (never downloaded at runtime, to stay inside App Review guideline 2.5.2).

## 12. Scheduling and serving

- `StudyMode.problems` builds a queue of due `.skill` items for the brain, through the existing `interleave`, so a session mixes skills. Interleaving is itself the evidence-backed choice for problem-solving practice.
- Each skill review is one problem attempt. The attempt's suggested grade feeds `StudyStore.record(...)` exactly like a text review, so exam-plan retention, weakness scores and calibration keep working.
- **Serving policy** (`ServingPolicy`, pure) picks the problem for a due skill:
  1. an unserved uploaded problem with a key,
  2. an unserved verified variant,
  3. the least recently served uploaded problem not served in the last 14 days,
  4. a variant generated on demand (online, key set),
  5. otherwise the least recently served problem, with a "you've seen this one" label.
- New skills enter through a short **worked-example ladder** before their first graded review: a fully worked problem to study, then the same type with the last step blank, then two blank, then a full attempt. This follows the worked-example and fading research and avoids dropping beginners straight into hard problems. The ladder is skipped for skills the student marks as already known.

## 13. Variant generation and verification

Per the decision in section 2: variants exist only when independent solves agree.

1. Background job keeps at least three unserved, verified problems per due-soon skill. It runs only when a key is set, on Wi-Fi, and within the daily budget.
2. Generator: given a source problem and its solution, write an isomorph (same method, new numbers or context) with a full worked solution and an `AnswerSpec`.
3. Independent solver: a second call (different model if the user has two configured, otherwise a fresh context at a different temperature) solves the new problem **without** seeing the generator's solution.
4. Verifier compares the two final answers. Where the problem allows, it also runs a substitution check (plug the solution into the original equation or ODE).
5. Agree and checks pass: stored as `KeySource.dualSolve(deterministicCheck: true/false)`. Disagree: discarded; at most two regenerations per slot.
6. In the UI, variants carry a "practice variant" badge; uploaded problems say "from your homework".

## 14. Modes

| Mode | Device | Input | Checking |
|---|---|---|---|
| Live | iPad | Pencil (or finger) | each pause |
| Check at end | iPad | Pencil (or finger) | on Check |
| Photo | iPhone or iPad | camera or photo of paper work | one batched check; the transcriber also returns line boxes so marks can be drawn on the photo |
| Self-check | any, no key | canvas or paper | reveal reference steps one at a time; student grades; the verifier still checks a typed final answer offline |
| Showcase / App Review | any | prerecorded drawing | `ReplayTransport` with recorded responses, no key needed |

The showcase mode is how App Review sees Workbench without a test API key,
consistent with how the existing showcase account works.

## 15. Settings, cost and privacy

New "Workbench" settings group:

- Check timing: Live (default) or Check at end. Pause delay.
- Tutor model: separate from the recap model. A fast vision model for transcription and a reasoning model for judging; defaults to the recap model when only one is configured. Stream A picks per-provider defaults from current model lists (for Anthropic, verified with the claude-api skill) and records which providers accept images.
- Daily check budget (soft cap with a warning, not a hard stop mid-problem) and a "checks used today, about N tokens" line.
- Allow finger drawing.
- Show transcriptions (on by default; turning it off hides chips but keeps amber prompts).

Cost shape per live step: one small image (a 1024x250 crop is roughly 300 to 400
image tokens on Anthropic's formula) plus about 1.5k text tokens in and 300 out
for the judge. The eval harness reports measured cost per check per model.

Providers without vision (the capability table from Stream A) disable Live and
Photo modes with a clear explanation and leave Self-check available.

Privacy: handwriting images and problem text go only to the user's chosen
provider, like recap text today. **The privacy policy and App Privacy answers
must mention images of handwritten work before Workbench ships** (site pages
live on the `gh-pages` branch).

## 16. iPad layout (Workbench screen only)

- **Landscape:** problem pane on the left (about 38%): statement, figure, part tabs, feedback history, source link. Canvas on the right with lanes and the transcription gutter. Toolbar: tool picker, undo, Check (end mode), hint, finish.
- **Portrait:** collapsible statement header on top, canvas below.
- Feedback cards anchor beside the flagged lane, never covering the student's ink.
- Supports Stage Manager and split view resizing; below about 700 pt of width it switches to the portrait layout.
- iPhone shows the problem plus Photo mode and Self-check, no canvas.

## 17. Subject profiles and phases

A `SubjectProfile` supplies transcriber hints, judge instructions, answer kinds,
verifier relations and input tools. Profiles are data plus prompt fragments, so
adding a subject is mostly content work.

| Phase | Profiles | Notes |
|---|---|---|
| 1 | Calculus, linear algebra, differential equations, statistics, physics (equations + units), general chemistry calculations | Verifier covers most steps. Highest reliability. |
| 1 | Written response (history, bio, psych) | Section 18; reuses existing grading. |
| 2 | Proofs (discrete math, real analysis, abstract algebra), CS theory | Judge only; no verifier. Feedback copy is softer ("this step may need justification"). Confidence threshold raised. |
| 2 | Diagrams: free body diagrams, circuits, supply and demand, sketched distributions | Vision judge on the lane image; a structured rubric per diagram type. |
| 2 | Label-the-diagram drills from slides | Image occlusion over material pages; cheap and offline-gradable. |
| 2 (option) | Voice think-aloud | Speak reasoning while writing; transcript goes to the judge. |
| 3 | Organic chemistry and biochemistry: structures and arrow-pushing | Vision LLM judges drawings directly; `\ce{}` for equations; RDKit.js (bundled WASM) compares canonical SMILES when a product answer exists. Labeled lower reliability in the UI. A tap-to-build structure editor is the alternative (open decision 8). |
| 3 | Language character writing (stroke order) | Small, fits the canvas. |

## 18. Written-response track

Independent of the canvas and can ship in parallel:

- **Rubric grading:** `concept` and `application` items get rubric points (from `keys`, or model-written at mint time). The model grader scores each point; the reveal shows "3 of 4: missing the mechanism".
- **Brain dump:** "Write everything you remember about X" (typed or handwritten via the canvas plus transcription). Graded as coverage of the concept's points.
- **Outline drill:** 60-second outline for a likely essay prompt, graded for thesis, evidence and structure.
- Handwritten prose can use `PKStrokeRecognizer` on iPadOS 27 (text only, on device) behind an availability check, falling back to the vision transcriber.

## 19. Evaluation harness and ship gates

Quality is measured before anything is shown to students.

- **Location:** `ios/TutorEval`, a macOS command-line target that links `WorkbenchCore`. Run: `swift run tutor-eval --subject calculus --transcriber <model> --judge <model>`. Keys come from the environment via direnv (`export ANTHROPIC_API_KEY="$(secret get ANTHROPIC_API_KEY)"`), never from files.
- **Golden set:** `ios/TutorEval/Golden/<subject>/<case>/` holding `case.json` (problem, reference, per-step gold transcription, gold verdict, gold first error) and either `drawing.data` (PKDrawing) or `step-N.png`.
  - Hand-written cases: a developer-build-only "Export case" button in Workbench writes the drawing and the student's labels. Target: at least 40 solutions per Phase 1 profile, half with seeded errors (sign, algebra, chain rule, units, dropped term).
  - Public data for the transcriber in isolation: MathWriting and CROHME (non-commercial licenses: internal evaluation only, never shipped).
  - Text-only step judging in isolation: ProcessBench-style cases.
  - Synthetic handwriting renders for large regression runs only, never for gates.
- **Modes:** `--record` stores responses as fixtures; `--replay` runs deterministically for CI and tests.
- **Metrics:** transcription exact match and character error rate; over-correction rate (transcriber silently fixes a seeded error); false-flag rate on correct steps; error detection recall; first-error localization accuracy; unclear rate; p50/p95 latency; cost per check.
- **Ship gates for Phase 1 (proposed):**

| Metric | Gate |
|---|---|
| False flag on correct steps | at most 3% |
| Over-correction | at most 2% |
| Error detection recall | at least 80% |
| First-error localization | at least 75% |
| Unclear rate | at most 15% |
| Live check p95 latency | at most 6 s |

A profile ships only when it meets its gates with at least one widely available
provider. The harness prints a per-model table so the settings screen can
recommend models honestly.

## 20. Testing and evidence

- **WorkbenchCore:** `swift test` on macOS covering the parser, evaluator, relation checks, units, segmentation geometry, decision table, grade mapping, serving policy, and Codable back-compat for every new type.
- **Pipeline integration:** full transcribe, judge, verify, decide runs against `ReplayTransport` fixtures recorded from real models.
- **App unit tests (XCTest):** StudyStore back-compat (unknown kinds and fields survive a round trip through an "old" decoder), sync merges for problems and attempts, material purpose decoding, extraction against PDFs in `SampleMaterials` (add a sample problem set and solutions PDF).
- **UI tests on an iPad Pro 13-inch simulator:** launch arguments `-workbenchFixture calc-001` load a recorded drawing and replay transport; assert margin marks, the feedback card, hint escalation, transcription edit and rejudge, dispute, and grade commit. One smoke test draws strokes with XCUITest coordinate drags.
- **End to end before each gate:** real model, real Pencil input on the simulator or a device, recorded as a screen capture.
- **PR evidence:** every PR includes screenshots or recordings and command output captured with `tesseract` in its Evidence section, per the pr-evidence workflow.
- **iOS CI (new):** GitHub Actions macOS job: `xcodegen generate`, build, XCTest unit tests, `swift test` for WorkbenchCore, harness in replay mode. Real-model eval runs stay manual (open decision 5).

## 21. Build plan with subagents

### 21.1 Operating model

- **Lead session** (Opus): owns this spec, the contracts, shared files, merge order, eval gates, and the user check-ins. It does not write stream code except Wave 0 and integration.
- **Worker sessions**: one per stream, each in its own pod worktree (`pod new ws-<stream>` after the contracts PR merges, so every pod starts from a `main` that has them). One stream, one branch (`pod/ws-<stream>`), one PR into `main`.
- **Subagents inside each worker:** `Explore` to locate code before editing; `/code-review high` on the diff before opening the PR; a verification pass that runs the app on the iPad simulator and captures evidence.
- **Model per stream:** Opus for design-heavy or judgment-heavy streams (canvas UX, check pipeline, prompts, extraction); Sonnet for well-specified mechanical work (data safety, CI, transport plumbing, renderer integration).
- **Lead-owned shared files:** `project.yml`, `Info.plist`, entitlements, and `ReviewSessionView.swift`. Streams that need a change there file a contract change request.
- **File ownership is exclusive.** A worker edits only the files its stream owns (table in 21.3). Anything else is a "contract change request" in the PR description, which the lead lands on `main`; workers then rebase. This is what makes parallel work merge cleanly.
- **Fixtures first.** The contracts PR ships `ReplayTransport` and a handful of recorded fixtures, so UI and integration streams never wait on real model work.
- **Concurrency:** at most four workers at once. Review and merge capacity, not typing speed, is the bottleneck, and four keeps each PR reviewed properly.

### 21.2 Waves and critical path

```
Wave 0 (lead, serial)     0a data safety  ->  0b contracts + WorkbenchCore skeleton
Wave 1 (parallel)         batch 1: A transport, B canvas, C math engine, E eval harness
                          batch 2: D problem import, F Workbench UI shell, G written response, H iOS CI
Wave 2 (parallel)         I check pipeline (A, C, E) | J variants + serving (A, C, D) | K scheduling + sync (0b, D)
Wave 3 (lead + workers)   L integration + e2e (B, F, I, K) | M photo mode (I, L) | beta checklist
Phase 2 / 3               proofs, diagrams, image occlusion, voice, orgo, characters (each its own stream)

Critical path: 0a -> 0b -> {A, C, E} -> I -> L
```

**Gates:**

- After Wave 1: the lead demos the Workbench shell, the canvas and rendering to the user (screenshots and a recording). The user signs off on layout and interaction before the pipeline is wired in.
- After Wave 2: Phase 1 eval gates (section 19) must pass for calculus and one other profile.
- After Wave 3: TestFlight build with the feature flag on for testers only.

### 21.3 Streams

| Stream | Goal | Owns (exclusive) | Depends on | Model |
|---|---|---|---|---|
| **0a Data safety** | Reproduce the wipe in a test, then make every study decoder per element and lossless for unknown records (preserved as raw JSON and written back untouched); hook `StudyStore.mergeFromDisk` to the metadata query; cover study files in `unionMetadata`. | `Study/StudyStore.swift` (decode and merge paths), `Study/StudyModels.swift` (decoders), `Persistence/LibraryStore.swift` (`unionMetadata`), new tests | none | Sonnet |
| **0b Contracts** | Create `Packages/WorkbenchCore` with every type and protocol in sections 7 and 10, `ReplayTransport`, fixtures, `StudyItemKind.skill`, `StudyMode.problems`, `MaterialPurpose`, the `workbenchEnabled` flag; wire the package into `project.yml`. | `Packages/WorkbenchCore/**` (skeleton), `project.yml`, `StudyModels.swift` (kind, mode), `MaterialModels.swift` | 0a | Opus (lead) |
| **A Transport** | `LLMClient` v2: content parts (text and image) for Anthropic and OpenAI-compatible APIs, JSON mode where supported, retries with backoff on 429 and 5xx, per-purpose timeouts (20 s for checks), cancellation, usage reporting, a provider vision capability table, tutor model settings. `LiveTransport` conforms to `ModelTransport`. | `Engine/LLMClient.swift`, new `Engine/LiveTransport.swift`, `Settings/Settings.swift` (tutor model fields only), `Features/Settings/*` (Workbench group) | 0b | Sonnet |
| **B Canvas** | PencilKit canvas, lanes, gutter, pause detector, stroke-record extraction, `StepSegmenter` implementation, crop rendering, drawing persistence, finger-drawing option. | `Features/Workbench/Canvas/**`, `WorkbenchCore/Segmentation/**` | 0b | Opus |
| **C Math engine** | LaTeX parser, evaluator, relation checks, units, `MathVerifier`; SwiftMath plus KaTeX fallback renderer; `$` math in `Markdown.swift`. | `WorkbenchCore/Math/**`, `Design/MathView.swift`, `Design/Markdown.swift`, SwiftMath package entry (via lead) | 0b | Opus |
| **D Problem import** | `ProblemExtractor`, material purpose and pairing, high-resolution page rendering, photo import, answer-key matching, skill mapping, the confirm screen, a sample problem set and solutions PDF for tests. The `NSPhotoLibraryUsageDescription` key goes through the lead. | `WorkbenchCore/Extraction/**`, `Materials/ProblemImport*.swift`, `Features/Materials/ProblemImport*.swift`, `SampleMaterials/problem-set-*` | 0b (uses A's transport via protocol and fixtures) | Opus |
| **E Eval harness** | `TutorEval` CLI, golden-set format and loader, record and replay, metrics and report, the developer-only "Export case" hook; seed 10 hand-labeled calculus cases. | `TutorEval/**`, `Features/Workbench/Debug/**` | 0b | Sonnet |
| **F Workbench UI shell** | The Workbench screen (section 16) with problem pane, feedback cards, hint ladder UI, grade bar, all driven by a mock pipeline and a placeholder canvas from the contract. | `Features/Workbench/*.swift` (not `Canvas/` or `Debug/`) | 0b | Opus |
| **G Written response** | Rubric grading, brain dump, outline drill (section 18). | `Study/Grading.swift`, new `Features/Study/BrainDump*.swift`, `Features/Study/Outline*.swift` | 0a | Sonnet |
| **H iOS CI** | GitHub Actions macOS workflow (section 20). | `.github/workflows/ios.yml` | 0b | Sonnet |
| **I Check pipeline** | Transcriber and judge prompts per Phase 1 profile, `DecisionTable`, `HintLadder`, `GradeMapper`, cost tracking, live and end orchestration; tuned until the eval gates pass. | `WorkbenchCore/Pipeline/**`, `WorkbenchCore/Profiles/**`, `WorkbenchCore/Prompts/**` | A, C, E | Opus |
| **J Variants and serving** | `VariantGenerator`, independent solve, verification, background top-up job, `ServingPolicy`, worked-example ladder content. | `WorkbenchCore/Variants/**`, `WorkbenchCore/Serving/**`, `Study/VariantJob.swift` | A, C, D | Opus |
| **K Scheduling and sync** | `problems.json` and `attempts.json` in `StudyStore`, `StudyMode.problems` queue, attempt-to-review recording, StudyView "Problems due" tile, exam planner and weakness integration. | `Study/StudyStore.swift` (new sections), `Features/Study/StudyView.swift` | 0b, D | Sonnet |
| **L Integration** | Wire F, B, I and K into one flow from the Study tab and Brain detail; showcase fixtures for App Review; UI tests; end-to-end recording. | `Features/Workbench/WorkbenchSession*.swift`, `Sample/*` (Workbench fixtures), `CatchMeUpUITests/Workbench*` | B, F, I, K | Opus (lead) |
| **M Photo mode** | Photo capture flow on iPhone and iPad, line boxes, marks drawn on the photo. | `Features/Workbench/Photo/**` | I, L | Sonnet |

### 21.4 Worker brief template

Every worker session starts with this brief, filled in from its table row:

```
You are implementing stream <X> of docs/superpowers/specs/2026-11-19-workbench-handwriting-tutor-design.md.
Read sections <list> first. Work only in this pod.

Goal: <one paragraph>
You own (edit only these): <paths>
Contracts you implement or consume: <types and protocols in WorkbenchCore>
Do not change contracts. If one is wrong, stop and write a contract change request in the PR description.

Required tests: <list>. Run `xcodegen generate` after adding files.
Commands: swift test (in ios/Packages/WorkbenchCore);
xcodebuild -project ios/CatchMeUp.xcodeproj -scheme CatchMeUp -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test
Evidence: screenshots or recordings plus tesseract-captured command output in the PR's Evidence section.
Before opening the PR: run /code-review high on your diff and fix what it finds.
Definition of done: <stream-specific>, all tests green, no new warnings, PR opened against main.
Writing rules: no em dashes; plain, specific commit messages.
```

### 21.5 Definition of done (every stream)

- Owned files only; any contract change went through the lead.
- Unit tests for every pure function; integration tests through `ReplayTransport` where a model is involved.
- No API keys in code, logs, fixtures or test output. Fixtures are scrubbed of headers.
- Evidence in the PR. `/code-review high` run and addressed.
- The feature stays behind `workbenchEnabled` until Wave 3 signs off.

### 21.6 How the lead runs a wave

1. Merge the wave's prerequisites to `main`.
2. Start up to four workers, each via `pod new ws-<stream>` plus its brief (or as linked sessions from the lead).
3. Answer contract change requests within the wave; land them on `main` and tell workers to rebase.
4. Review each PR (diff, evidence, tests), then merge in dependency order.
5. Run the wave gate (demo or eval) and record the result in this spec's changelog section before starting the next wave.

## 22. Risks

| Risk | Mitigation |
|---|---|
| Transcription of complex 2D math is wrong | Lanes give clean single-step crops; visible chips; amber confirm on low confidence; Mathpix strokes API as an optional higher-accuracy transcriber if the harness shows a gap |
| Over-correction hides student errors | Transcriber never sees the answer; over-correction is a gated metric |
| Wrong "you're wrong" verdicts erode trust | Decision table defaults ambiguity to unclear; false-flag rate gated at 3%; dispute button |
| Wrong answer keys on generated variants | Dual solve plus deterministic check; unverified problems never graded |
| Cost to users on BYO keys | Only dirty lanes are sent; content-hash cache; text-only judge; budget display; check-at-end option |
| Latency makes live mode feel slow | Fast transcriber, chip appears before the verdict, judge runs async, p95 gate |
| App Review cannot test without a key | Showcase mode with replay fixtures |
| Data loss across app versions | Stream 0a before anything else, ideally before 1.0 |
| Scope sprawl across subjects | Profiles ship only when they pass gates; Phase 2 and 3 are separate streams |
| iOS 17 target versus newer APIs | Newer APIs (iPadOS 27 `PKStrokeRecognizer`) behind availability checks with fallbacks |

## 23. Open decisions for the user

1. **Lanes or free canvas.** Recommend ruled lanes (deterministic steps, cleaner crops). A free canvas feels more like paper but makes step detection a guessing game.
2. **Confirm screen after import.** Recommend on by default with a skip option; a 20-second review prevents a bad skill taxonomy.
3. **Separate Problems mode or mixed queue.** Recommend a separate Problems mode (canvas sessions need a different posture than flashcards), with problems counted in "due today".
4. **Tutor model defaults and the cost display.** Which models to recommend per provider is settled by the eval harness; the question is whether to show estimated cost per session.
5. **iOS CI on GitHub Actions macOS runners.** Free for public repos, billed at a premium multiplier for private ones.
6. **Pricing posture.** BYO key means no per-problem cost to you; decide whether Workbench is part of the base app or a paid tier.
7. **Voice think-aloud** (Phase 2 option): worth it?
8. **Organic chemistry input** (Phase 3): freehand drawing judged by the vision model, or a tap-to-build structure editor that grades exactly.

## 24. Sources

- PencilKit `PKStroke`, `PKStrokePoint`: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct.md, https://developer.apple.com/documentation/pencilkit/pkstrokepoint-swift.struct.md
- PKToolPicker custom items: https://developer.apple.com/documentation/pencilkit/pktoolpickercustomitem.md
- WWDC26 session 203, PencilKit stroke recognition (verify): https://developer.apple.com/videos/play/wwdc2026/203/
- Apple Developer Forums on math recognition limits (verify): https://developer.apple.com/forums/thread/856608
- Mathpix API pricing and strokes: https://mathpix.com/pricing/api, https://docs.mathpix.com/reference/post-v3-strokes
- MyScript iink math features: https://developer.myscript.com/doc/interactive-ink/4.5/overview/math-features/
- MathWriting dataset: https://arxiv.org/abs/2404.10690
- Uni-MuMER (CROHME zero-shot results): https://arxiv.org/html/2505.23566v4
- HMER-Bench (verify): https://proceedings.mlr.press/v306/jiang26bg.html
- VLM over-correction (verify): https://aclanthology.org/2026.emnlp-main.476.pdf
- SwiftMath: https://github.com/mgriebling/SwiftMath
- LaTeXSwiftUI: https://github.com/colinc86/LaTeXSwiftUI
- KaTeX: https://katex.org/versions
- Pyodide SymPy on iOS (verify): https://blog.thecoatlessprofessor.com/posts/python-in-your-pocket-with-pyodios/
- WeBWorK formula test points: https://webwork.maa.org/wiki/FormulaTestPoints
- DECIMER hand-drawn structures: https://jcheminf.biomedcentral.com/counter/pdf/10.1186/s13321-024-00872-7.pdf
- RDKit.js: https://cdn.jsdelivr.net/npm/@rdkit/rdkit@2025.3.4-1.0.0/README.md
- ProcessBench: https://arxiv.org/html/2412.06559
- FERMAT: https://arxiv.org/abs/2501.07244
- ErrorRadar: https://arxiv.org/abs/2410.04509v2
- Vision-LLM grading of handwritten STEM work (verify): https://arxiv.org/abs/2605.19043
- ETH calculus exam AI grading: https://arxiv.org/pdf/2510.05162
- Self-consistency: https://arxiv.org/pdf/2203.11171
- PROVE (program verification of answers): https://arxiv.org/pdf/2410.12608
- Goblins: https://goblins.com/explore/why-personalized-math-tutoring, https://www.the74million.org/article/new-ai-math-tutoring-app-goblins-clones-your-teachers-looks-and-voice/
- MathGPT.ai step grader: https://www.mathgpt.ai/company/news

## Changelog

- 2026-11-19: first draft from codebase mapping and a research pass.
