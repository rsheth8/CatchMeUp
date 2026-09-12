# Guided showcase tour — design

## Problem

`ShowcaseSession` currently offers a free-explore demo account with a "tour"
sheet (`ShowcaseView` in `ios/CatchMeUp/Sample/ShowcaseSession.swift`) that is
just four buttons switching tabs. It doesn't show anyone anything — it's a
menu, not a tour. We want an actual guided walkthrough: the app drives
navigation to a real screen, spotlights the real control to tap, and only
advances once the user taps it for real.

## Stops (fixed, reusing seeded showcase data)

All four stops reuse the deterministic data `ShowcaseCatalog` already seeds
(`ios/CatchMeUp/Sample/ShowcaseCatalog.swift`), so the tour matches what a
user finds afterward in free-explore:

1. **Play a key moment** — Library → the cs lecture "Environment diagrams and
   closures" (`ShowcaseCatalog` entry key 1). Spotlight playback/seek.
2. **Practice for an exam** — Study tab, flashcards filtered to the Computer
   Science brain (`studyBrainID`). Spotlight `flashcard.card`, then "Got it".
3. **Explore connected ideas** — Brains tab → "Computer Science"
   (`ShowcaseCatalog.brainID("cs")`) → Neural map
   (`CatchMeUpLink.brainGraph`). Spotlight the graph, then "Recenter map".
4. **Run a meeting** — Brains tab → "Payments" → "Billing migration: launch
   readiness" (entry key 7) → `MeetingWorkspaceView`. Spotlight each
   segmented control in turn (Findings, Follow-ups, Materials, Summary).

Each stop decomposes into 2-4 micro `TourStep`s (~10-12 total), one per
tappable control, since the spotlight moves once per real tap.

Navigation to each stop uses `AppRouter`'s existing deep-link state
(`libraryPath`, `brainPath`, `brainGraphID`, `studyBrainID`) — no new router
plumbing needed.

## Architecture

New file: `ios/CatchMeUp/Sample/GuidedTour.swift`.

### `TourStep`

```swift
struct TourStep {
    let id: String
    let anchorID: String
    let caption: String
    let setup: (AppRouter, LibraryStore, StudyStore) -> Void
    let isComplete: (AppRouter, LibraryStore, StudyStore) -> Bool
}
```

`setup` runs once when the step becomes current (drives real navigation).
`isComplete` is polled to detect the user's real tap and auto-advance.

### `GuidedTourDriver` (@Observable)

Holds `steps: [TourStep]`, `currentIndex: Int?`, `anchors: [String: CGRect]`,
`isActive: Bool`. Exposes `start()`, `stop()`, `checkAdvance(router:library:study:)`,
and `updateAnchors(_:)`.

### Anchors

`TourAnchorKey: PreferenceKey` holds `[String: CGRect]`, merged via `reduce`.
A `.tourAnchor(id:)` view modifier (background `GeometryReader` reporting into
the preference) is added to the real controls the tour visits: the meeting
row, the four segmented buttons, `flashcard.card`, "Got it", the brain row,
the graph, "Recenter map". `ShowcaseView` reads the merged preference with
`.onPreferenceChange` (single tree, one read point) and calls
`driver.updateAnchors(_:)`.

### Rendering

`ShowcaseView` wraps `RootView` in a `ZStack` with `TourOverlay` layered on
top when `driver.isActive`. The overlay is a dimming layer
(`Color.black.opacity(0.55)`) with a cutout at the current anchor's `CGRect`
via a `Path` + even-odd `.mask`; the cutout is not hit-testable by the dim
layer, so the tap passes through to the real control underneath. A caption
bubble is pinned near the cutout. "Skip tour" stays visible throughout.

If the anchor for the current step hasn't reported yet (view not yet
rendered), the overlay shows the caption without a cutout rather than
spotlighting nothing.

### Advancing

`TourOverlay` runs a `.task` with a ~200ms polling loop that calls
`driver.checkAdvance(router:library:study:)`, which evaluates the current
step's `isComplete` and moves to the next step (running its `setup`) when
true. Polling avoids wiring a distinct `.onChange` for every property across
four unrelated domains (tab selection, graph presentation, segment
selection, flashcard flip state).

### Starting/stopping

The existing "Take the tour" button in `ShowcaseView`'s sheet
(`tour(_:_:_:)` closures, currently just setting `router.selectedTab`) calls
`driver.start()` instead. "Skip tour" calls `driver.stop()`; since
`setup()` already performed real navigation, there is nothing to unwind —
the user is simply left wherever they are.

## Error handling

- Missing anchor: caption-only fallback (above), no timeout needed since
  navigation for the step already happened synchronously in `setup()`.
- Exiting the showcase entirely mid-tour: unaffected — `ShowcaseSession.leave()`
  already tears down the whole `ShowcaseView`, taking the tour overlay with
  it.

## Testing

- Manual: run with `-showShowcase`, start the tour, step through all 4
  stops, confirm no clipped/missing spotlight.
- Automated: extend `ios/CatchMeUpUITests/BetaNavigationUITests.swift` with a
  test that taps a new `tour.start` accessibility identifier and walks the
  same real elements (`meeting`, segmented buttons, `flashcard.card`,
  `graph`), asserting the spotlight/caption exists at each step. This is the
  regression test that catches the tour pointing at a broken or missing
  element.

## Out of scope

- Persisting tour progress across app restarts.
- A generalized reactive condition DSL — `isComplete` closures are
  hand-written per step since the step list is fixed and small.
- Disabling "Exit showcase" while the tour is active (exiting is safe at any
  point, per Error handling above).
