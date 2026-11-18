import Foundation

/// Where the hosted recap service lives. The address comes from Info.plist
/// (`HostedAPIBaseURL`), and it is empty until a backend has been deployed, so a
/// build without one simply does not offer CatchMeUp Cloud.
enum HostedConfig {
    static var baseURL: URL? {
        #if DEBUG
        // For pointing a debug build at `wrangler dev`, without touching the plist:
        //   xcrun simctl spawn booted defaults write com.catchmeup.app hostedBaseURL http://localhost:8787
        if let override = UserDefaults.standard.string(forKey: "hostedBaseURL"),
           let url = URL(string: override), url.scheme != nil {
            return url
        }
        #endif
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "HostedAPIBaseURL") as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty,
              let url = URL(string: raw), url.scheme != nil
        else { return nil }
        return url
    }

    static var isConfigured: Bool { baseURL != nil }
}
