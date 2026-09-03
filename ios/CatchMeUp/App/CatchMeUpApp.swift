import SwiftUI

@main
struct CatchMeUpApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LibraryStore()
    @State private var settings = AppSettings()
    @State private var router = AppRouter()
    /// App-scoped so a conversion survives navigating away from Storage, and so
    /// the import path and the dashboard share one queue.
    @State private var optimizer = AudioOptimizer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(settings)
                .environment(router)
                .environment(optimizer)
                .fontDesign(.rounded)
                .tint(.brand)
                .task { await houseKeeping() }
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
        await store.reconcileCloudAudio()
        await optimizer.scanLibrary(store: store)
        if settings.audioRetention.isAutomatic {
            store.applyRetention(settings.audioRetention,
                                 allowLocalDeletion: settings.allowLocalAudioDeletion)
        }
        if store.syncEnabled, settings.optimizeCloudStorage {
            store.freeSpaceForOlderCloudAudio()
        }
    }
}
