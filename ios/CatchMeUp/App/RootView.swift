import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selection: Tab = .library

    enum Tab: Hashable { case library, brains, settings }

    var body: some View {
        TabView(selection: $selection) {
            LibraryView()
                .tabItem { Label("Recaps", systemImage: "waveform") }
                .tag(Tab.library)

            BrainsView()
                .tabItem { Label("Brains", systemImage: "brain") }
                .tag(Tab.brains)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: selection) { _, _ in Haptics.tap(.soft) }
        .sheet(isPresented: Binding(
            get: { !settings.hasOnboarded },
            set: { if !$0 { settings.hasOnboarded = true } }
        )) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
    }
}
