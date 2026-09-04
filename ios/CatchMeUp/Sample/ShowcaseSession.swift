import Foundation
import Observation
import SwiftUI

/// A separate local account, never a replacement for the user's library.
/// Always launches into the real account; the showcase is an explicit visit.
@MainActor @Observable
final class ShowcaseSession {
    static let shared = ShowcaseSession()
    var isActive = false
    var isPreparing = false
    var error: String?
    static let defaults = UserDefaults(suiteName: "com.catchmeup.showcase")!
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CatchMeUp-Showcase", isDirectory: true)
    }

    var canSwitch: Bool {
        !isPreparing && ProcessingQueue.shared.activeJobs.isEmpty
            && !MaterialStore.shared.visibleMaterials.contains { $0.state.isWorking }
            && !StudyStore.shared.isMinting && !LibraryStore.shared.migration.isRunning
    }

    func enter() {
        guard canSwitch else { return }
        isActive = true
    }

    func leave() {
        guard canSwitch else { return }
        isActive = false
    }
}

struct ShowcaseView: View {
    @State private var store = LibraryStore.shared
    @State private var settings = AppSettings.shared
    @State private var study = StudyStore.shared
    @State private var materials = MaterialStore.shared
    @State private var router = AppRouter()
    @State private var optimizer = AudioOptimizer()
    @State private var showTour = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
                HStack {
                    Button { showTour = true } label: {
                        Label("Showcase · Take a tour", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("showcase.tour")
                    Spacer()
                    Button("Exit") { ShowcaseSession.shared.leave() }
                        .accessibilityIdentifier("showcase.exit")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .disabled(!ShowcaseSession.shared.canSwitch || optimizer.state.isBusy)
                }
                .padding(.horizontal, 20).padding(.vertical, 4)
                .background(.ultraThinMaterial)
                RootView()
        }
            .environment(store).environment(settings).environment(study)
            .environment(materials).environment(router).environment(optimizer)
            .environment(ProcessingQueue.shared)
            .tint(.brand)
            .interactiveDismissDisabled()
            .task {
                store.studySink = study
                await ShowcaseCatalog.prepare(store: store, study: study, materials: materials)
                await ProcessingQueue.shared.resumeUnfinishedWork()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await ProcessingQueue.shared.resumeUnfinishedWork() }
                }
            }
            .sheet(isPresented: $showTour) {
                NavigationStack {
                    List {
                        Section {
                            Text("A fictional student and work account. Edits stay here, separate from your personal library. Audio is narrated sample content; answers use local source matching, not a live AI model.")
                        }
                        Section("Try it in five minutes") {
                            tour("Play a key moment", "Hear the recording exactly where a recap links to it.", .library)
                            tour("Practice for an exam", "Answer questions, reveal flashcards, and watch the review schedule update.", .study)
                            tour("Explore connected ideas", "Open a brain, explore its neural map, then ask about a concept or project risk.", .brains)
                            tour("Run a meeting", "Open Payments, review decisions, edit owners and deadlines, and complete follow-ups.", .brains)
                        }
                        Section("What's real here") {
                            Text("Search, playback, clip seeking, documents, graphs, study grading, scheduling, task editing, and exports use the normal app. Live transcription and AI generation are simulated in Demo mode. Cloud sync and automatic reminders stay off for this account.")
                        }
                        if let error = ShowcaseSession.shared.error {
                            Section("Setup notice") { Text(error) }
                        }
                    }
                    .navigationTitle("Meet your showcase")
                    .toolbar { Button("Done") { showTour = false } }
                }
            }
    }

    private func tour(_ title: String, _ detail: String, _ tab: AppTab) -> some View {
        Button {
            router.selectedTab = tab
            showTour = false
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }.padding(.vertical, 5)
        }
    }
}
