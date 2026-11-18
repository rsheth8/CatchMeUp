import Foundation

/// Everything that can go wrong talking to CatchMeUp Cloud, in words a student
/// can act on. The server's own messages are never shown, so a change there
/// cannot leak wording the app did not choose.
enum HostedError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    /// A 401 from a call that had a token. The session retries once, then turns
    /// this into `notSignedIn`.
    case unauthorized
    case quotaExceeded(plan: String, resetsAt: Date?)
    case jobLimit
    /// Too many questions and other non-recap requests this month.
    case otherLimit
    case rateLimited
    case inFlight
    case busy
    case tooLong
    case refused
    case offline
    /// A recap or meeting call with no recording id. A bug in the app, not something to retry.
    case missingJob
    case server(status: Int, code: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "CatchMeUp Cloud isn't available in this build."
        case .notSignedIn, .unauthorized:
            return "Sign in to use CatchMeUp Cloud."
        case .quotaExceeded(let plan, let resetsAt):
            let when = resetsAt.map { " They reset on \($0.formatted(.dateTime.month(.wide).day()))." } ?? ""
            return plan == "plus"
                ? "You've reached this month's Plus limit.\(when)"
                : "You've used your free recaps for this month.\(when)"
        case .jobLimit:
            return "This recording has used its processing allowance for the month."
        case .otherLimit:
            return "You've reached this month's limit on questions and other requests."
        case .rateLimited:
            return "Too many requests at once. Wait a minute and try again."
        case .inFlight:
            return "Another recap is still being written. Try again in a moment."
        case .busy:
            return "CatchMeUp Cloud is busy right now. Try again shortly, or switch to on-device."
        case .tooLong:
            return "This recording is too long to send in one piece."
        case .refused:
            return "The model declined to write notes for this recording."
        case .offline:
            return "Couldn't reach CatchMeUp Cloud. Check your connection and try again."
        case .missingJob:
            return "Something went wrong preparing this recap. Please try again."
        case .server:
            return "CatchMeUp Cloud couldn't finish this request. Try again."
        case .badResponse:
            return "CatchMeUp Cloud sent something unreadable. Try again."
        }
    }

    /// Reads the server's `{"error": {"code", ...}}` body.
    static func from(status: Int, body: [String: Any]?) -> HostedError {
        let error = body?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? ""
        switch (status, code) {
        case (401, _):
            return .unauthorized
        case (402, "quota_exceeded"):
            return .quotaExceeded(plan: error?["plan"] as? String ?? "free",
                                  resetsAt: HostedDates.parse(error?["resetsAt"] as? String))
        case (413, _):
            return .tooLong
        case (422, "refused"):
            return .refused
        case (429, "rate_limited"):
            return .rateLimited
        case (429, "request_in_flight"):
            return .inFlight
        case (429, "job_limit"):
            return .jobLimit
        case (429, "other_limit"):
            return .otherLimit
        case (503, _):
            return .busy
        default:
            return .server(status: status, code: code)
        }
    }
}

enum HostedDates {
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
