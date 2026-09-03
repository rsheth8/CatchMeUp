import SwiftUI

@main
struct CatchMeUpApp: App {
    @State private var store = LibraryStore()
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(settings)
                .fontDesign(.rounded)
                .tint(.brand)
        }
    }
}
