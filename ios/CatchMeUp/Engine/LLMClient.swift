import Foundation

/// Minimal HTTP client for Anthropic + any OpenAI-compatible chat endpoint.
struct LLMClient {
    let config: ProviderConfig

    func complete(system: String, user: String, maxTokens: Int = 8000) async throws -> String {
        switch config.kind {
        case .anthropic: return try await anthropic(system: system, user: user, maxTokens: maxTokens)
        case .openai:    return try await openAICompatible(system: system, user: user, maxTokens: maxTokens)
        }
    }

    // MARK: Anthropic

    private func anthropic(system: String, user: String, maxTokens: Int) async throws -> String {
        guard !config.apiKey.isEmpty else { throw EngineError.missingKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        let text = content?.compactMap { $0["text"] as? String }.joined()
        guard let text, !text.isEmpty else { throw EngineError.badResponse }
        return text
    }

    // MARK: OpenAI-compatible

    private func openAICompatible(system: String, user: String, maxTokens: Int) async throws -> String {
        guard let base = config.baseURL, let url = URL(string: base.hasSuffix("/") ? base + "chat/completions" : base + "/chat/completions") else {
            throw EngineError.onDeviceUnavailable("This provider needs a base URL. Add it in Settings.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let text = message?["content"] as? String
        guard let text, !text.isEmpty else { throw EngineError.badResponse }
        return text
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw EngineError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
