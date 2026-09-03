import SwiftUI

@main
struct CatchMeUpApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LibraryStore()
    @State private var settings = AppSettings()
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(settings)
                .environment(router)
                .fontDesign(.rounded)
                .tint(.brand)
        }
    }
}
