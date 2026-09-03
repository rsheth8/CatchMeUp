import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct MaterialInsight: Sendable {
    let summary: String
    let topics: [String]
}

enum MaterialIntelligence {
    static func analyze(pages: [MaterialPage]) async -> MaterialInsight? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            return try? await analyzeOnDevice(pages: pages)
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func analyzeOnDevice(pages: [MaterialPage]) async throws -> MaterialInsight {
        let windows = windows(for: pages, limit: 7_200)
        var summaries: [String] = []
        var topics: [String] = []

        for window in windows {
            try Task.checkCancellation()
            let session = LanguageModelSession(instructions: """
                Understand supplied course or work material. Stay grounded in the text. \
                Identify the ideas that would help an assistant answer questions about a related \
                meeting or lecture. Do not imply the material was spoken aloud.
                """)
            let generated = try await session.respond(
                to: "Summarize this portion and identify its important concepts:\n\n\(window)",
                generating: GeneratedMaterialInsight.self
            ).content
            let summary = generated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty { summaries.append(summary) }
            topics += generated.topics
        }

        var seen = Set<String>()
        let unique = topics.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return MaterialInsight(summary: summaries.joined(separator: " "), topics: Array(unique.prefix(20)))
    }

    private static func windows(for pages: [MaterialPage], limit: Int) -> [String] {
        var output: [String] = []
        var buffer = ""
        for page in pages {
            let block = "[Page or slide \(page.number)]\n\(page.combinedText)\n"
            if !buffer.isEmpty && buffer.count + block.count > limit {
                output.append(buffer)
                buffer = ""
            }
            if block.count > limit {
                output.append(String(block.prefix(limit)))
            } else {
                buffer += block
            }
        }
        if !buffer.isEmpty { output.append(buffer) }
        return output
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable(description: "Grounded understanding of one portion of supplied material.")
private struct GeneratedMaterialInsight {
    @Guide(description: "A concise but substantive summary grounded only in the supplied pages.")
    var summary: String

    @Guide(description: "Important named concepts, methods, requirements, formulas, or decisions.",
           .maximumCount(12))
    var topics: [String]
}
#endif
