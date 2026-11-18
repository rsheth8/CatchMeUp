import Foundation

// MARK: - Errors

enum BenchError: LocalizedError {
    case missingKey
    case budgetExceeded(spent: Double, limit: Double)
    case refused(String)
    case truncated
    case appleUnavailable(String)
    case badJudgeReply(String)
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "ANTHROPIC_API_KEY is not set. Run through direnv, or: ANTHROPIC_API_KEY=\"$(secret get ANTHROPIC_API_KEY)\" swift run bench ..."
        case .budgetExceeded(let spent, let limit):
            return String(format: "Spend limit reached ($%.2f of $%.2f). Raise --max-cost to continue.", spent, limit)
        case .refused(let why): return "The model declined the request (\(why))."
        case .truncated: return "The reply hit max_tokens before it finished."
        case .appleUnavailable(let why): return why
        case .badJudgeReply(let why): return "Could not read the judge's reply: \(why)"
        case .usage(let message): return message
        }
    }
}

// MARK: - Pricing

/// Per-million-token list prices, matched by model-id prefix (longest first),
/// so a dated id such as `claude-haiku-4-5-20251001` resolves to its family.
/// Update when prices change; an unknown model reports no cost rather than a guess.
enum Pricing {
    struct Rate { let input: Double; let output: Double }

    private static let table: [(prefix: String, rate: Rate)] = [
        ("claude-fable-5-2", Rate(input: 8, output: 40)),
        ("claude-fable-5-1", Rate(input: 10, output: 50)),
        ("claude-fable-5", Rate(input: 10, output: 50)),
        ("claude-opus-5-5", Rate(input: 4, output: 20)),
        ("claude-opus-5", Rate(input: 5, output: 25)),
        ("claude-opus-4", Rate(input: 5, output: 25)),
        ("claude-sonnet-5-5", Rate(input: 2, output: 10)),
        ("claude-sonnet-5", Rate(input: 2, output: 10)),
        ("claude-sonnet-4-6", Rate(input: 3, output: 15)),
        ("claude-haiku-5-5", Rate(input: 0.10, output: 0.50)),
        ("claude-haiku-4-5", Rate(input: 1, output: 5)),
    ].sorted { $0.0.count > $1.0.count }

    static func rate(for model: String) -> Rate? {
        table.first { model.hasPrefix($0.prefix) }?.rate
    }

    static func cost(model: String, inputTokens: Int, outputTokens: Int) -> Double? {
        guard let rate = rate(for: model) else { return nil }
        return Double(inputTokens) / 1_000_000 * rate.input + Double(outputTokens) / 1_000_000 * rate.output
    }
}

// MARK: - Spend guard and metering

/// Hard stop for a whole invocation. Checked before every request, so a
/// mistaken `--engines` or an oversized corpus can't quietly run up a bill.
final class BudgetGuard: @unchecked Sendable {
    static let shared = BudgetGuard()
    private let lock = NSLock()
    private var spent = 0.0
    private var limit = 5.0

    func configure(limit: Double) {
        lock.lock(); defer { lock.unlock() }
        self.limit = limit
        spent = 0
    }

    func record(_ cost: Double) {
        lock.lock(); defer { lock.unlock() }
        spent += cost
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if spent >= limit { throw BenchError.budgetExceeded(spent: spent, limit: limit) }
    }

    var total: Double {
        lock.lock(); defer { lock.unlock() }
        return spent
    }
}

/// Token and cost totals for one engine over one recording.
final class UsageMeter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    private(set) var cost = 0.0
    private(set) var costKnown = true

    func add(model: String, input: Int, output: Int) {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        inputTokens += input
        outputTokens += output
        if let c = Pricing.cost(model: model, inputTokens: input, outputTokens: output) {
            cost += c
        } else {
            costKnown = false
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        calls = 0; inputTokens = 0; outputTokens = 0; cost = 0; costKnown = true
    }
}

// MARK: - HTTP

struct AnthropicReply {
    var text: String
    var inputTokens: Int
    var outputTokens: Int
    var stopReason: String?
}

/// One Messages API call, shared by the recap engine and the judge.
///
/// Deliberately sends no sampling parameters: the current models reject
/// non-default temperature, and a benchmark should compare defaults anyway.
enum AnthropicHTTP {
    /// Models that accept `output_config.effort`. Haiku 4.5 does not, and sending
    /// it there is an error, so it is only attached where it is known to work.
    static func supportsEffort(_ model: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable", "claude-mythos"]
            .contains { model.hasPrefix($0) }
    }

    /// Models that think by default, where thinking tokens share `max_tokens`
    /// with the answer. They need headroom or a long recap is cut short.
    static func thinksByDefault(_ model: String) -> Bool { supportsEffort(model) }

    static func message(
        model: String,
        system: String,
        user: String,
        maxTokens: Int,
        effort: String?,
        jsonSchema: [String: Any]? = nil,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> AnthropicReply {
        guard !apiKey.isEmpty else { throw BenchError.missingKey }

        var outputConfig: [String: Any] = [:]
        if let effort, supportsEffort(model) { outputConfig["effort"] = effort }
        if let jsonSchema { outputConfig["format"] = ["type": "json_schema", "schema": jsonSchema] }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": thinksByDefault(model) ? max(maxTokens, 16_000) : maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        if !outputConfig.isEmpty { body["output_config"] = outputConfig }
        let payload = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            try BudgetGuard.shared.check()
            try Task.checkCancellation()

            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 600
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.httpBody = payload

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError where attempt < 4 {
                attempt += 1
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                _ = error
                continue
            }

            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) {
                let reply = try parse(data)
                // Charged here, not in the per-engine meter, so judge calls
                // count against --max-cost too.
                if let c = Pricing.cost(model: model, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens) {
                    BudgetGuard.shared.record(c)
                }
                return reply
            }

            let retryable = [408, 409, 429, 500, 502, 503, 504, 529].contains(status)
            if retryable, attempt < 4 {
                attempt += 1
                let header = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                try await Task.sleep(for: .seconds(header ?? pow(2, Double(attempt))))
                continue
            }
            // Never echo request headers; the body of an error response is safe.
            throw EngineError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
    }

    static func parse(_ data: Data) throws -> AnthropicReply {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.badResponse
        }
        let stop = json["stop_reason"] as? String
        if stop == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw BenchError.refused((details?["category"] as? String) ?? "no category")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        // Thinking blocks carry no "text" key, so they drop out here.
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        let usage = json["usage"] as? [String: Any]
        let input = (usage?["input_tokens"] as? Int ?? 0)
            + (usage?["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage?["cache_read_input_tokens"] as? Int ?? 0)
        let output = usage?["output_tokens"] as? Int ?? 0
        if stop == "max_tokens" && text.isEmpty { throw BenchError.truncated }
        guard !text.isEmpty else { throw EngineError.badResponse }
        return AnthropicReply(text: text, inputTokens: input, outputTokens: output, stopReason: stop)
    }
}
