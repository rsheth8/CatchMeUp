import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class MaterialStore {
    static let shared = MaterialStore()

    private(set) var materials: [SupplementalMaterial] = []
    private(set) var importError: String?
    private var workers: [UUID: Task<Void, Never>] = [:]

    private let root: URL
    private let metadataURL: URL

    init(root: URL? = nil) {
        let support = root ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask)[0]
            .appendingPathComponent("CatchMeUp", isDirectory: true)
        self.root = support.appendingPathComponent("Materials", isDirectory: true)
        self.metadataURL = support.appendingPathComponent("materials.json")
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        load()
    }

    var visibleMaterials: [SupplementalMaterial] {
        materials.filter { !$0.deleted }.sorted { $0.createdAt > $1.createdAt }
    }

    func material(_ id: UUID) -> SupplementalMaterial? {
        materials.first { $0.id == id && !$0.deleted }
    }

    func materials(inBrain id: UUID) -> [SupplementalMaterial] {
        let recordingIDs = Set(LibraryStore.shared.recordings(inBrain: id).map(\.id))
        return visibleMaterials.filter {
            $0.brainID == id || !$0.recordingIDs.allSatisfy { !recordingIDs.contains($0) }
        }
    }

    func materials(forRecording id: UUID) -> [SupplementalMaterial] {
        visibleMaterials.filter { $0.recordingIDs.contains(id) }
    }

    /// Best unlinked source in the same brain. This is intentionally a
    /// suggestion rather than an automatic link: matching dates and vocabulary
    /// are useful evidence, but only the person knows whether "Week 8" was the
    /// deck actually used in that lecture.
    func suggestedMaterial(for recording: Recording) -> SupplementalMaterial? {
        guard let brainID = recording.brainID else { return nil }
        let attached = Set(materials(forRecording: recording.id).map(\.id))
        let recordingWords = Self.matchWords(recording.searchBlob)
        return materials(inBrain: brainID)
            .filter { !attached.contains($0.id) }
            .map { material -> (SupplementalMaterial, Double) in
                let titleWords = Self.matchWords(material.name)
                let materialWords = titleWords.union(Self.matchWords(material.summary))
                let overlap = Double(recordingWords.intersection(materialWords).count)
                let days = abs(material.createdAt.timeIntervalSince(recording.createdAt)) / 86_400
                let dateScore = days <= 1 ? 2.5 : (days <= 7 ? 1 : 0)
                return (material, overlap + dateScore)
            }
            .filter { $0.1 >= 2 }
            .max { $0.1 < $1.1 }?.0
    }

    func importFiles(_ urls: [URL], into brainID: UUID?, attachingTo recordingID: UUID? = nil) {
        importError = nil
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard let kind: MaterialKind = ext == "pdf" ? .pdf : (ext == "pptx" ? .slides : nil) else { continue }
            let id = UUID()
            let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("original.\(ext)")
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                let values = try? destination.resourceValues(forKeys: [.fileSizeKey])
                var item = SupplementalMaterial(
                    id: id,
                    name: url.deletingPathExtension().lastPathComponent,
                    kind: kind,
                    brainID: brainID,
                    recordingIDs: recordingID.map { [$0] } ?? [],
                    originalFilename: url.lastPathComponent
                )
                item.byteSize = Int64(values?.fileSize ?? 0)
                item.usageMode = recordingID.flatMap { LibraryStore.shared.recording($0)?.mode }
                    ?? LibraryStore.shared.brain(brainID)?.mode
                materials.append(item)
                save()
                process(id)
            } catch {
                importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    func process(_ id: UUID) {
        guard workers[id] == nil, let item = material(id) else { return }
        setState(id, .extracting(0.08))
        let url = originalURL(for: item)
        let kind = item.kind
        workers[id] = Task {
            do {
                let extracted = try await Task.detached(priority: .utility) {
                    try DocumentProcessor.extract(url: url, kind: kind)
                }.value
                guard !Task.isCancelled else { return }
                setState(id, .indexing(0.18))
                let pages = try storePages(extracted, materialID: id)
                guard let index = materials.firstIndex(where: { $0.id == id }) else { return }
                materials[index].pages = pages
                materials[index].summary = Self.summary(from: pages)
                materials[index].concepts = Self.concepts(from: pages)
                materials[index].state = .indexing(0.58)
                save()

                if let insight = await MaterialIntelligence.analyze(pages: pages),
                   let refreshed = materials.firstIndex(where: { $0.id == id }) {
                    if !insight.summary.isEmpty { materials[refreshed].summary = insight.summary }
                    let semantic = insight.topics.map { topic in
                        let matches = pages.filter {
                            $0.combinedText.localizedCaseInsensitiveContains(topic)
                        }.map(\.number)
                        return MaterialConcept(name: topic, pageNumbers: matches)
                    }
                    if !semantic.isEmpty { materials[refreshed].concepts = semantic }
                }
                guard let index = materials.firstIndex(where: { $0.id == id }) else { return }
                materials[index].state = .ready
                materials[index].updatedAt = .now
                save()
                StudyStore.shared.mintOffline(for: [materials[index]])
            } catch is CancellationError {
                setState(id, .queued)
            } catch {
                setState(id, .failed(error.localizedDescription))
            }
            workers[id] = nil
        }
    }

    func resumePending() {
        for item in visibleMaterials where item.state.isWorking { process(item.id) }
    }

    func attach(_ materialID: UUID, to recordingID: UUID) {
        guard let index = materials.firstIndex(where: { $0.id == materialID }) else { return }
        if !materials[index].recordingIDs.contains(recordingID) {
            materials[index].recordingIDs.append(recordingID)
            materials[index].updatedAt = .now
            save()
        }
    }

    func detach(_ materialID: UUID, from recordingID: UUID) {
        guard let index = materials.firstIndex(where: { $0.id == materialID }) else { return }
        materials[index].recordingIDs.removeAll { $0 == recordingID }
        materials[index].updatedAt = .now
        save()
    }

    func delete(_ material: SupplementalMaterial) {
        workers[material.id]?.cancel()
        workers[material.id] = nil
        if let index = materials.firstIndex(where: { $0.id == material.id }) {
            materials[index].deleted = true
            materials[index].updatedAt = .now
            save()
        }
        try? FileManager.default.removeItem(at: folder(for: material.id))
        StudyStore.shared.deleteItems(forMaterial: material.id)
    }

    func originalURL(for material: SupplementalMaterial) -> URL {
        folder(for: material.id).appendingPathComponent("original.\(material.kind == .pdf ? "pdf" : "pptx")")
    }

    func thumbnailURL(materialID: UUID, filename: String?) -> URL? {
        guard let filename else { return nil }
        return folder(for: materialID).appendingPathComponent(filename)
    }

    private func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func setState(_ id: UUID, _ state: MaterialState) {
        guard let index = materials.firstIndex(where: { $0.id == id }) else { return }
        materials[index].state = state
        materials[index].updatedAt = .now
        save()
    }

    private func storePages(_ extracted: [ExtractedMaterialPage], materialID: UUID) throws -> [MaterialPage] {
        let folder = folder(for: materialID)
        return try extracted.map { page in
            let filename: String?
            if let thumbnail = page.thumbnail {
                let name = "page-\(page.number).jpg"
                try thumbnail.write(to: folder.appendingPathComponent(name), options: .atomic)
                filename = name
            } else {
                filename = nil
            }
            return MaterialPage(number: page.number, title: page.title, text: page.text,
                                speakerNotes: page.speakerNotes, thumbnailFilename: filename)
        }
    }

    private static func summary(from pages: [MaterialPage]) -> String {
        let headings = pages.map(\.title).filter { !$0.isEmpty }
        if !headings.isEmpty { return headings.prefix(4).joined(separator: " · ") }
        return String(pages.map(\.text).joined(separator: " ").prefix(280))
    }

    private static func concepts(from pages: [MaterialPage]) -> [MaterialConcept] {
        let stop: Set<String> = ["this", "that", "with", "from", "have", "will", "your", "into", "about",
                                 "there", "their", "which", "when", "what", "where", "were", "been", "than",
                                 "then", "also", "using", "used", "each", "such", "these", "those", "page",
                                 "slide", "lecture", "meeting", "the", "and", "for", "are", "but", "not"]
        var locations: [String: Set<Int>] = [:]
        var display: [String: String] = [:]
        for page in pages {
            for raw in page.combinedText.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let word = String(raw)
                let key = word.lowercased()
                guard key.count >= 5, !stop.contains(key), !key.allSatisfy(\.isNumber) else { continue }
                locations[key, default: []].insert(page.number)
                display[key] = display[key] ?? word
            }
        }
        return locations.sorted {
            if $0.value.count == $1.value.count { return $0.key < $1.key }
            return $0.value.count > $1.value.count
        }.prefix(20).map {
            MaterialConcept(name: display[$0.key] ?? $0.key.capitalized,
                            pageNumbers: $0.value.sorted())
        }
    }

    private static func matchWords(_ text: String) -> Set<String> {
        let noise: Set<String> = ["this", "that", "with", "from", "meeting", "lecture", "recap",
                                  "notes", "slides", "slide", "the", "and", "for", "are"]
        return Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 4 && !noise.contains($0) })
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder.materials.decode([SupplementalMaterial].self, from: data) else { return }
        materials = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder.materials.encode(materials) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var materials: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var materials: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
