import Foundation

/// What the app shows about the month: which plan, and how many recaps are left.
struct HostedQuota: Equatable {
    var plan: String
    var recapsRemaining: Int
    var resetsAt: Date?

    var isPlus: Bool { plan == "plus" }

    init(plan: String, recapsRemaining: Int, resetsAt: Date?) {
        self.plan = plan
        self.recapsRemaining = recapsRemaining
        self.resetsAt = resetsAt
    }

    init?(json: Any?) {
        guard let dict = json as? [String: Any],
              let plan = dict["plan"] as? String,
              let left = dict["recapsRemaining"] as? Int
        else { return nil }
        self.init(plan: plan, recapsRemaining: left, resetsAt: HostedDates.parse(dict["resetsAt"] as? String))
    }
}

enum HostedProvider: String {
    case apple, google
}

/// Plain JSON over HTTPS. It knows nothing about tokens or sessions: callers
/// pass the bearer token in, and `HostedSession` decides when to refresh it.
struct HostedAPI {
    let baseURL: URL
    var session: URLSession = .shared

    func send(
        _ method: String, _ path: String,
        token: String? = nil, body: [String: Any]? = nil, timeout: TimeInterval = 30
    ) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw HostedError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HostedError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw HostedError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            throw HostedError.from(status: http.statusCode, body: json)
        }
        guard let json else { throw HostedError.badResponse }
        return json
    }
}
