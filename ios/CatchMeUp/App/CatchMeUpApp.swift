import SwiftUI

@main
struct CatchMeUpApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Shared rather than owned, so the background worker and the views are
    /// looking at the same library. See `LibraryStore.shared`.
    @State private var store = LibraryStore.shared
    @State private var settings = AppSettings.shared
    @State private var router = AppRouter()
    /// App-scoped so a conversion survives navigating away from Storage, and so
    /// the import path and the dashboard share one queue.
    @State private var optimizer = AudioOptimizer()
    @State private var queue = ProcessingQueue.shared
    /// The question bank and schedule. Separate from `LibraryStore` because it
    /// outlives any one recap and syncs on its own files.
    @State private var study = StudyStore()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(settings)
                .environment(router)
                .environment(optimizer)
                .environment(queue)
                .environment(study)
                .fontDesign(.rounded)
                .tint(.brand)
                .task { await houseKeeping() }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back to the foreground is the common way a parked
                    // job gets picked up — the scheduled task is the fallback
                    // for when the user doesn't return for a while.
                    if phase == .active {
                        Task { await queue.resumeUnfinishedWork() }
                    }
                }
        }
    }

    /// One pass at startup: learn what the audio library actually contains, then
    /// apply whatever cleanup the user has asked for.
    ///
    /// Nothing here removes the only copy of anything. Retention is off by
    /// default, and even when it's on it needs `allowLocalAudioDeletion` before
    /// it will touch audio that isn't backed up. Leftover-file cleanup is
    /// deliberately left to an explicit tap in Settings ▸ Storage.
    private func houseKeeping() async {
        // Wired before anything else touches the library, so a deletion during
        // startup still takes its questions with it.
        store.studySink = study
        // Before anything slow: a recording left half-processed by a crash or a
        // suspend should be moving again by the time the library draws.
        queue.enqueuePendingFromStore()


        await store.reconcileCloudAudio()
        await optimizer.scanLibrary(store: store)
        // Any recap finished while the app was closed gets its questions now,
        // so the Study tab's badge is right on the first frame the user sees.
        study.mergeFromDisk()
        study.mintOffline(for: store.sortedRecordings)
        if settings.audioRetention.isAutomatic {
            store.applyRetention(settings.audioRetention,
                                 allowLocalDeletion: settings.allowLocalAudioDeletion)
        }
        if store.syncEnabled, settings.optimizeCloudStorage {
            store.freeSpaceForOlderCloudAudio()
        }
    }
}
