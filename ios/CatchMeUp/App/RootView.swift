import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(StudyStore.self) private var study
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Work waiting today, counted the same way the Study tab counts it. Zero
    /// renders no badge, which is the point — an always-on number stops meaning
    /// anything.
    private var dueBadge: Int { study.todayCount(newLimit: settings.dailyNewLimit) }

    var body: some View {
        @Bindable var router = router
        @Bindable var settings = settings

        appleTabs
            .onChange(of: router.selectedTab) { _, _ in Haptics.tap(.soft) }
            .onOpenURL { router.open($0) }
            .onContinueUserActivity(CatchMeUpLink.recapActivityType) { router.continueActivity($0) }
            .onReceive(NotificationCenter.default.publisher(for: .catchMeUpRouteRequested)) { _ in
                router.consumePendingRoute()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { router.consumePendingRoute() }
            }
            .task { router.consumePendingRoute() }
            .sheet(isPresented: Binding(
                get: { !settings.hasOnboarded },
                set: { if !$0 { settings.hasOnboarded = true } }
            )) {
                OnboardingView()
                    .interactiveDismissDisabled()
            }
            .fullScreenCover(isPresented: Binding(
                get: { router.recorderMode != nil },
                set: { if !$0 { router.recorderMode = nil; router.recorderBrainID = nil; router.recorderRecordingID = nil } }
            )) {
                if let mode = router.recorderMode {
                    RecordView(initialMode: mode, brainID: router.recorderBrainID,
                               recordingID: router.recorderRecordingID) { newID in
                        let brainID = router.recorderBrainID
                        router.recorderMode = nil
                        router.recorderBrainID = nil
                        router.recorderRecordingID = nil
                        if let brainID {
                            router.selectedTab = .brains
                            router.brainPath = [brainID, newID]
                        } else {
                            router.selectedTab = .library
                            router.libraryPath.append(newID)
                        }
                    }
                }
            }
    }

    /// iPhone gets the floating pill; iPad keeps the system sidebar, which is
    /// genuinely better there than anything a custom bar would do.
    @ViewBuilder
    private var appleTabs: some View {
        if #available(iOS 18.0, *), sizeClass != .compact {
            tabs.tabViewStyle(.sidebarAdaptable)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: Bindable(router).selectedTab) {
            LibraryView()
                .tabItem { Label("Recaps", systemImage: "waveform") }
                .tag(AppTab.library)

            StudyView()
                .tabItem { Label("Study", systemImage: "graduationcap") }
                .tag(AppTab.study)
                .badge(dueBadge)

            BrainsView()
                .tabItem { Label("Brains", systemImage: "brain") }
                .tag(AppTab.brains)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
