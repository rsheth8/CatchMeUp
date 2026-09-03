import Foundation

enum MaterialKind: String, Codable, CaseIterable, Hashable {
    case pdf
    case slides

    var title: String { self == .pdf ? "PDF" : "Slides" }
    var symbol: String { self == .pdf ? "doc.richtext" : "rectangle.on.rectangle.angled" }
}

enum MaterialState: Codable, Hashable, Equatable {
    case queued
    case extracting(Double)
    case indexing(Double)
    case ready
    case failed(String)

    var progress: Double {
        switch self {
        case .queued: return 0.03
        case .extracting(let value): return 0.1 + 0.55 * value
        case .indexing(let value): return 0.65 + 0.34 * value
        case .ready: return 1
        case .failed: return 0
        }
    }

    var isReady: Bool { self == .ready }
    var isWorking: Bool {
        switch self {
        case .queued, .extracting, .indexing: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .queued: return "Waiting to be understood"
        case .extracting: return "Reading the document"
        case .indexing: return "Connecting its ideas"
        case .ready: return "Ready"
        case .failed(let message): return message
        }
    }
}

struct MaterialPage: Codable, Identifiable, Hashable {
    var id = UUID()
    var number: Int
    var title: String = ""
    var text: String = ""
    var speakerNotes: String = ""
    var thumbnailFilename: String?

    var combinedText: String {
        [title, text, speakerNotes].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var locationLabel: String { "\(number)" }
}

struct MaterialConcept: Codable, Identifiable, Hashable {
    var id: String { name.lowercased() }
    var name: String
    var pageNumbers: [Int]
}

struct SupplementalMaterial: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: MaterialKind
    var brainID: UUID?
    var usageMode: Mode? = nil
    var recordingIDs: [UUID] = []
    var originalFilename: String
    var byteSize: Int64 = 0
    var state: MaterialState = .queued
    var pages: [MaterialPage] = []
    var summary: String = ""
    var concepts: [MaterialConcept] = []
    var createdAt = Date()
    var updatedAt = Date()
    var deleted = false

    var pageCount: Int { pages.count }
    var locationNoun: String { kind == .slides ? "slide" : "page" }
    var countLabel: String {
        guard pageCount > 0 else { return kind.title }
        return "\(pageCount) \(locationNoun)\(pageCount == 1 ? "" : "s")"
    }

    var searchBlob: String {
        ([name, summary] + concepts.map(\.name) + pages.map(\.combinedText)).joined(separator: " ")
    }
}

struct MaterialCitation: Identifiable, Hashable {
    var id: String { "\(materialID.uuidString)-\(pageNumber)" }
    let materialID: UUID
    let title: String
    let kind: MaterialKind
    let pageNumber: Int

    var label: String { "\(title) · \(kind == .slides ? "Slide" : "Page") \(pageNumber)" }
}
