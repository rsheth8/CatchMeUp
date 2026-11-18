import Foundation

/// How the judge reaches a model. `api` bills the API key per token. `claudeCLI`
/// runs the Claude Code CLI in print mode, which uses whatever the person is
/// signed in with there (a Claude subscription), so judging costs no API spend
/// and counts against the subscription's usage limits instead.
public enum JudgeBackend: Sendable, Equatable {
    case api(key: String)
    case claudeCLI

    var label: String {
        switch self {
        case .api: return "API key"
        case .claudeCLI: return "Claude subscription (claude CLI)"
        }
    }
}

struct JudgeClient: Sendable {
    let model: String
    let backend: JudgeBackend

    func ask(system: String, user: String, schema: [String: Any], maxTokens: Int) async throws -> String {
        switch backend {
        case .api(let key):
            let reply = try await AnthropicHTTP.message(
                model: model, system: system, user: user,
                maxTokens: maxTokens, effort: "medium", jsonSchema: schema, apiKey: key
            )
            return reply.text
        case .claudeCLI:
            return try await ClaudeCLI.run(model: model, system: system, user: user, schema: schema)
        }
    }
}

/// Print-mode Claude Code, set up so the judge stays blind and clean: no tools,
/// no settings, hooks, skills or MCP servers, no saved session, and a throwaway
/// working directory so no project instructions are picked up. API-key variables
/// are removed from the child's environment, otherwise the CLI would use them
/// instead of the subscription login and bill the key after all.
enum ClaudeCLI {
    static let strippedEnvironment: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
    ]

    static func arguments(model: String, system: String, schema: [String: Any]) throws -> [String] {
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return [
            "-p",
            "--model", model,
            "--system-prompt", system,
            "--tools", "",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--output-format", "json",
            "--json-schema", String(decoding: schemaData, as: UTF8.self),
        ]
    }

    static func environment(from base: [String: String]) -> [String: String] {
        base.filter { !strippedEnvironment.contains($0.key) }
    }

    /// The model's answer as JSON text, from the CLI's `--output-format json` result.
    static func answer(fromOutput data: Data) throws -> String {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BenchError.badJudgeReply("claude CLI printed something that is not JSON: " + String(decoding: data.prefix(120), as: UTF8.self))
        }
        if json["is_error"] as? Bool == true {
            throw BenchError.badJudgeReply("claude CLI reported an error: " + String((json["result"] as? String ?? "").prefix(160)))
        }
        if let structured = json["structured_output"] as? [String: Any],
           let text = try? JSONSerialization.data(withJSONObject: structured) {
            return String(decoding: text, as: UTF8.self)
        }
        if let result = json["result"] as? String, !result.isEmpty { return result }
        throw BenchError.badJudgeReply("claude CLI returned no answer")
    }

    static func run(model: String, system: String, user: String, schema: [String: Any]) async throws -> String {
        let args = try arguments(model: model, system: system, schema: schema)
        let env = environment(from: ProcessInfo.processInfo.environment)
        let output: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["claude"] + args
                process.environment = env
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr
                do { try process.run() } catch {
                    continuation.resume(throwing: BenchError.usage("Could not start the claude CLI (is it installed and on PATH?): \(error.localizedDescription)"))
                    return
                }
                // The transcript is long, so it goes in on stdin rather than as an argument.
                stdin.fileHandleForWriting.write(Data(user.utf8))
                try? stdin.fileHandleForWriting.close()
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0, out.isEmpty {
                    let why = String(decoding: err.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: BenchError.badJudgeReply("claude CLI exited \(process.terminationStatus): \(why)"))
                } else {
                    continuation.resume(returning: out)
                }
            }
        }
        return try answer(fromOutput: output)
    }
}
