import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
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
    }

    @ViewBuilder
    private var appleTabs: some View {
        if #available(iOS 18.0, *) {
            tabs.tabViewStyle(.sidebarAdaptable)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        @Bindable var router = router

        return TabView(selection: $router.selectedTab) {
            LibraryView()
                .tabItem { Label("Recaps", systemImage: "waveform") }
                .tag(AppTab.library)

            BrainsView()
                .tabItem { Label("Brains", systemImage: "brain") }
                .tag(AppTab.brains)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
