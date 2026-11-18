import Foundation

/// Whether this build can actually start a Google sign-in.
///
/// `GIDSignIn` raises an Objective-C exception, which Swift can't catch, if the
/// client ID is missing or its reversed form isn't a registered URL scheme. The
/// repo ships placeholders for both, so the button has to be offered only once
/// real values are in `Info.plist`.
enum GoogleSignInConfig {
    private static let clientIDSuffix = ".apps.googleusercontent.com"
    private static let schemePrefix = "com.googleusercontent.apps."
    private static let placeholderPrefix = "REPLACE_WITH_"

    static var isAvailable: Bool { isAvailable(info: Bundle.main.infoDictionary ?? [:]) }

    static func isAvailable(info: [String: Any]) -> Bool {
        guard let clientID = info["GIDClientID"] as? String,
              !clientID.hasPrefix(placeholderPrefix),
              clientID.hasSuffix(clientIDSuffix)
        else { return false }

        let appID = clientID.dropLast(clientIDSuffix.count)
        guard !appID.isEmpty else { return false }
        let expected = (schemePrefix + appID).lowercased()

        let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return urlTypes
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .contains { $0.lowercased() == expected }
    }
}
