import SwiftUI

/// The four stops offered from the showcase sheet, each its own short tour
/// over the same seeded data a user finds afterward in free-explore.
enum GuidedTourSteps {
    // The most recent entry of each type, so the row lands unscrolled at the
    // top of the lazily-rendered library list where the spotlight can find it.
    private static let csRecordingID = UUID(uuidString: "DE000000-0000-4000-A000-000000000004")!
    private static let paymentsRecordingID = UUID(uuidString: "DE000000-0000-4000-A000-000000000009")!
    private static let csBrainID = ShowcaseCatalog.brainID("cs")
    private static let paymentsBrainID = ShowcaseCatalog.brainID("payments")

    static let playAKeyMoment: [TourStep] = [
        TourStep(id: "library.open", anchorID: "library.recap.\(csRecordingID)",
                 caption: "Tap the recording to open it.",
                 setup: { router, _, _ in
                     router.selectedTab = .library
                     router.libraryPath = []
                 },
                 isComplete: { router, _, _, _ in router.libraryPath.first == csRecordingID }),
        TourStep(id: "library.play", anchorID: "recap.playback",
                 caption: "Tap play to hear this moment.",
                 setup: { _, _, _ in },
                 isComplete: { _, _, _, driver in driver.facts["recap.playing"] as? Bool == true }),
    ]

    static let practiceForAnExam: [TourStep] = [
        TourStep(id: "study.open", anchorID: "study.flashcards",
                 caption: "Tap Flashcards to start practicing.",
                 setup: { router, _, _ in
                     router.selectedTab = .study
                     router.studyBrainID = csBrainID
                 },
                 isComplete: { _, _, _, driver in driver.facts["study.flashcardsOpened"] as? Bool == true }),
        TourStep(id: "study.flip", anchorID: "flashcard.card",
                 caption: "Tap the card to flip it.",
                 setup: { _, _, _ in },
                 isComplete: { _, _, _, driver in driver.facts["study.cardFlipped"] as? Bool == true }),
        TourStep(id: "study.grade", anchorID: "flashcards.gotIt",
                 caption: "Tap Got it to grade the card.",
                 setup: { _, _, _ in },
                 isComplete: { _, _, _, driver in driver.facts["study.cardGraded"] as? Bool == true }),
    ]

    static let exploreConnectedIdeas: [TourStep] = [
        TourStep(id: "brains.open", anchorID: "brain.card.\(csBrainID)",
                 caption: "Tap Computer Science to open it.",
                 setup: { router, _, _ in
                     router.selectedTab = .brains
                     router.brainPath = []
                     router.brainGraphID = nil
                 },
                 isComplete: { router, _, _, _ in router.brainPath.first == csBrainID }),
        TourStep(id: "brains.recenter", anchorID: "brain.recenter",
                 caption: "Tap Recenter map to reset the view.",
                 setup: { router, _, _ in router.brainGraphID = csBrainID },
                 isComplete: { _, _, _, driver in driver.facts["brain.recentered"] as? Bool == true }),
    ]

    static let runAMeeting: [TourStep] = [
        TourStep(id: "meeting.open", anchorID: "library.recap.\(paymentsRecordingID)",
                 caption: "Tap the meeting to open it.",
                 setup: { router, _, _ in
                     router.selectedTab = .library
                     router.libraryPath = []
                 },
                 isComplete: { router, _, _, _ in router.libraryPath.first == paymentsRecordingID }),
    ] + ["Findings", "Follow-ups", "Materials", "Summary"].map { name in
        TourStep(id: "meeting.\(name)", anchorID: "meeting.segmented",
                 caption: "Tap \(name).",
                 setup: { _, _, _ in },
                 isComplete: { _, _, _, driver in driver.facts["meeting.section"] as? String == name })
    }
}

/// A single micro-step: real navigation via `setup`, real user interaction
/// detected via `isComplete`. `isComplete` also receives the driver itself so
/// steps can check facts noted by views that don't expose their state through
/// AppRouter/LibraryStore/StudyStore (e.g. a private `@State` flip flag).
struct TourStep {
    let id: String
    let anchorID: String
    let caption: String
    let setup: @MainActor (AppRouter, LibraryStore, StudyStore) -> Void
    let isComplete: @MainActor (AppRouter, LibraryStore, StudyStore, GuidedTourDriver) -> Bool
}

@MainActor @Observable
final class GuidedTourDriver {
    private(set) var steps: [TourStep] = []
    var currentIndex: Int?
    var anchors: [String: CGRect] = [:]
    var facts: [String: AnyHashable] = [:]

    var isActive: Bool { currentIndex != nil }
    var current: TourStep? {
        guard let currentIndex, steps.indices.contains(currentIndex) else { return nil }
        return steps[currentIndex]
    }

    func start(_ steps: [TourStep], router: AppRouter, library: LibraryStore, study: StudyStore) {
        self.steps = steps
        facts = [:]
        currentIndex = steps.isEmpty ? nil : 0
        current?.setup(router, library, study)
    }

    func stop() {
        currentIndex = nil
        steps = []
        facts = [:]
    }

    /// Lets views outside the router/library/study trio report a fact a step
    /// can check — a private flip flag, a segmented selection, and so on.
    func note(_ key: String, _ value: AnyHashable) {
        facts[key] = value
    }

    /// Merges rather than replaces: `.sheet`/`.fullScreenCover` content reports
    /// through its own `tourHost`, in its own hosting tree, so each call only
    /// carries that tree's anchors. Merging keeps every tree's contribution
    /// instead of the last writer wiping the others.
    func updateAnchors(_ new: [String: CGRect]) {
        anchors.merge(new) { _, new in new }
    }

    func checkAdvance(router: AppRouter, library: LibraryStore, study: StudyStore) {
        guard let step = current, step.isComplete(router, library, study, self) else { return }
        let next = (currentIndex ?? 0) + 1
        guard steps.indices.contains(next) else { stop(); return }
        currentIndex = next
        steps[next].setup(router, library, study)
    }
}

private struct GuidedTourKey: EnvironmentKey {
    static let defaultValue: GuidedTourDriver? = nil
}

extension EnvironmentValues {
    var guidedTour: GuidedTourDriver? {
        get { self[GuidedTourKey.self] }
        set { self[GuidedTourKey.self] = newValue }
    }
}

struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this view's frame (in the "tourSpace" coordinate space) so the
    /// tour overlay can cut a spotlight out of the dim layer around it.
    func tourAnchor(_ id: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: TourAnchorKey.self,
                                        value: [id: proxy.frame(in: .named("tourSpace"))])
            }
        }
    }

    /// Establishes a "tourSpace" for `.tourAnchor` and renders the overlay
    /// above this content. Every `.sheet`/`.fullScreenCover` presentation is
    /// its own hosting tree — preferences set inside one don't bubble to an
    /// ancestor outside it — so each presentation that contains a tour anchor
    /// needs its own `tourHost`, not just the screen that owns the driver.
    func tourHost(_ driver: GuidedTourDriver?) -> some View {
        coordinateSpace(name: "tourSpace")
            .overlay {
                if let driver, driver.isActive {
                    TourOverlay(driver: driver)
                }
            }
            .onPreferenceChange(TourAnchorKey.self) { driver?.updateAnchors($0) }
    }
}

/// Dims everything except the current step's anchor, which stays tappable —
/// the tap reaches the real control underneath, not a copy of it.
struct TourOverlay: View {
    let driver: GuidedTourDriver
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(StudyStore.self) private var study

    var body: some View {
        if let step = driver.current {
            GeometryReader { proxy in
                // `.ignoresSafeArea()` below can expand this reader past the
                // "tourSpace" origin (e.g. a sheet's grabber inset), so a
                // stored anchor can't be used as-is — it must be re-based
                // onto this reader's own offset within "tourSpace".
                let origin = proxy.frame(in: .named("tourSpace")).origin
                let rect = driver.anchors[step.anchorID]?.offsetBy(dx: -origin.x, dy: -origin.y)
                ZStack {
                    dimLayer(cutout: rect, size: proxy.size)
                    caption(step, cutout: rect, size: proxy.size)
                    skipButton
                        .frame(width: proxy.size.width, height: proxy.size.height,
                               alignment: .bottomTrailing)
                }
            }
            .ignoresSafeArea()
            .task(id: step.id) { await poll() }
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            driver.checkAdvance(router: router, library: library, study: study)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func dimLayer(cutout: CGRect?, size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            if let cutout {
                let padded = cutout.insetBy(dx: -8, dy: -8)
                path.addRoundedRect(in: padded, cornerSize: CGSize(width: 14, height: 14))
            }
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        // An empty tap gesture claims the shape's own hit area (the dimmed
        // region only, since the cutout is excluded from the path) so taps
        // inside the cutout fall through to the real control beneath.
        .onTapGesture {}
    }

    @ViewBuilder
    private func caption(_ step: TourStep, cutout: CGRect?, size: CGSize) -> some View {
        let bubble = VStack(alignment: .leading, spacing: 4) {
            Text(step.caption)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(14)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 280)

        if let cutout {
            let below = cutout.maxY + 60 < size.height
            bubble
                .position(x: min(max(cutout.midX, 150), size.width - 150),
                          y: below ? cutout.maxY + 44 : max(cutout.minY - 44, 60))
        } else {
            bubble.position(x: size.width / 2, y: size.height / 2)
        }
    }

    private var skipButton: some View {
        Button("Skip tour") { driver.stop() }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.82), in: Capsule())
            .padding(16)
            .accessibilityIdentifier("tour.skip")
    }
}
