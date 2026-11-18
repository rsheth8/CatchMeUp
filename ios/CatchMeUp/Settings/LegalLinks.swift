import Foundation

/// Public pages the App Store requires. Their source is in `site/` at the top
/// of the repository, and they must be live before the app is submitted. The
/// same two addresses go into App Store Connect.
enum LegalLinks {
    private static let base = "https://rsheth8.github.io/CatchMeUp"

    static let privacyPolicy = URL(string: "\(base)/privacy/")!
    static let support = URL(string: "\(base)/support/")!
}
