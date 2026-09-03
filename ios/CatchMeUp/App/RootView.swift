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

    /// The system bar stays in the layout and is only made invisible, with the
    /// pill drawn over it.
    ///
    /// Hiding it outright and re-inseting the pill was the obvious approach and
    /// it doesn't work: every screen that already floats something above the tab
    /// bar — Recaps' record button, the grade buttons in a review — measures its
    /// own bottom inset against the tab bar, so removing it drops those controls
    /// behind the pill. Keeping the bar means none of that layout has to change.
    private var tabs: some View {
        TabView(selection: Bindable(router).selectedTab) {
            room(LibraryView())
                .tabItem { Label("Recaps", systemImage: "waveform") }
                .tag(AppTab.library)

            room(StudyView())
                .tabItem { Label("Study", systemImage: "graduationcap") }
                .tag(AppTab.study)
                .badge(dueBadge)

            room(BrainsView())
                .tabItem { Label("Brains", systemImage: "brain") }
                .tag(AppTab.brains)

            room(SettingsView())
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .overlay(alignment: .bottom) {
            if sizeClass == .compact {
                FloatingTabBar(selection: Bindable(router).selectedTab,
                               studyBadge: dueBadge)
            }
        }
        .onAppear { if sizeClass == .compact { UITabBar.makeInvisible() } }
    }

    /// Gives a screen back the room a transparent tab bar stops reserving, so
    /// the last row of a list isn't left sitting under the pill.
    @ViewBuilder
    private func room(_ content: some View) -> some View {
        if sizeClass == .compact {
            content.safeAreaPadding(.bottom, FloatingTabBar.reservedHeight)
        } else {
            content
        }
    }
}

// MARK: - Hiding the system bar without removing it

private extension UITabBar {
    /// Clears the bar's background and paints its items in clear, so it still
    /// occupies its space — and still supplies every screen's bottom safe area —
    /// while the pill above it is the only thing anyone sees.
    @MainActor
    static func makeInvisible() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear

        for item in [appearance.stackedLayoutAppearance,
                     appearance.inlineLayoutAppearance,
                     appearance.compactInlineLayoutAppearance] {
            for state in [item.normal, item.selected] {
                state.iconColor = .clear
                state.titleTextAttributes = [.foregroundColor: UIColor.clear]
                // The badge would otherwise float over the pill on its own.
                state.badgeBackgroundColor = .clear
                state.badgeTextAttributes = [.foregroundColor: UIColor.clear]
            }
        }

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        // Appearance proxies only take on bars created afterwards; existing ones
        // need it applied directly.
        for window in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            window.allTabBars.forEach {
                $0.standardAppearance = appearance
                $0.scrollEdgeAppearance = appearance
            }
        }
    }
}

private extension UIView {
    var allTabBars: [UITabBar] {
        (self as? UITabBar).map { [$0] } ?? subviews.flatMap(\.allTabBars)
    }
}
