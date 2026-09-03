import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selection: Tab = .home

    enum Tab: Hashable { case home, brains, settings }

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Recaps", systemImage: "waveform") }
                .tag(Tab.home)

            BrainsView()
                .tabItem { Label("Brains", systemImage: "brain") }
                .tag(Tab.brains)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .sheet(isPresented: Binding(
            get: { !settings.hasOnboarded },
            set: { if !$0 { settings.hasOnboarded = true } }
        )) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
    }
}
