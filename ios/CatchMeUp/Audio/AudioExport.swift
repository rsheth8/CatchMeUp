import Foundation

/// Gets audio out of the app and into the user's own hands.
///
/// This is what makes local-only cleanup defensible: before anything is
/// deleted, there's a way to keep a copy somewhere the app doesn't control.
enum AudioExport {
    enum Failure: LocalizedError {
        case nothingToExport
        case notOnDevice
        case archiveFailed(String)

        var errorDescription: String? {
            switch self {
            case .nothingToExport: return "There's no audio to export here."
            case .notOnDevice: return "That audio is still in iCloud. Play it once to download it, then export."
            case .archiveFailed(let why): return "Couldn't build the export (\(why))."
            }
        }
    }

    /// One file's worth of work, resolved on the main actor and then handed to a
    /// background task so a large copy doesn't hitch the UI.
    private struct Item: Sendable {
        var source: URL
        var basename: String
        var notes: String?
    }

    /// One recording, copied out under a name a human would recognise.
    @MainActor
    static func stage(_ recording: Recording, store: LibraryStore) async throws -> URL {
        guard recording.hasAudio else { throw Failure.nothingToExport }
        let source = try await store.audio.ensureLocal(for: recording)
        let item = Item(source: source, basename: filename(for: recording), notes: nil)
        let folder = try scratchFolder()
        return try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let destination = folder
                .appendingPathComponent("\(item.basename).\(item.source.pathExtension)")
            try FileManager.default.copyItem(at: item.source, to: destination)
            return destination
        }.value
    }

    /// A zip of many recordings — a whole brain, or the entire library.
    ///
    /// Notes go in alongside the audio, because an archive of bare `.m4a` files
    /// is a much worse thing to find in five years than one with the transcript
    /// sitting next to it.
    @MainActor
    static func archive(_ recordings: [Recording], named archiveName: String,
                        store: LibraryStore) async throws -> URL {
        // Whatever is already on the device goes in. Pulling an entire library
        // down from iCloud to build a zip isn't something to do behind a
        // progress spinner.
        let items: [Item] = recordings.compactMap { recording in
            guard recording.hasAudio,
                  let source = store.audio.playableURL(for: recording) else { return nil }
            return Item(source: source,
                        basename: filename(for: recording),
                        notes: recording.recap.map { RecapMarkdown.build(recording, $0) })
        }
        guard !items.isEmpty else { throw Failure.nothingToExport }

        let root = try scratchFolder()
        let name = sanitize(archiveName)
        return try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let payload = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            for item in items {
                let audio = payload
                    .appendingPathComponent("\(item.basename).\(item.source.pathExtension)")
                try? FileManager.default.copyItem(at: item.source, to: audio)
                if let notes = item.notes {
                    try? notes.write(to: payload.appendingPathComponent("\(item.basename).md"),
                                     atomically: true, encoding: .utf8)
                }
            }
            return try zip(payload, named: name, into: root)
        }.value
    }

    // MARK: - Plumbing

    /// `NSFileCoordinator`'s uploading intent hands back a zip of a directory,
    /// which saves pulling in an archiving dependency for this one job.
    private static func zip(_ directory: URL, named name: String, into folder: URL) throws -> URL {
        let destination = folder.appendingPathComponent("\(name).zip")
        try? FileManager.default.removeItem(at: destination)

        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [.forUploading],
                                       error: &coordinationError) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: destination) }
            catch { thrown = error }
        }
        if let thrown { throw Failure.archiveFailed(thrown.localizedDescription) }
        if let coordinationError { throw Failure.archiveFailed(coordinationError.localizedDescription) }
        try? FileManager.default.removeItem(at: directory)
        return destination
    }

    private static func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Export/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Date first, so a folder full of exports sorts chronologically.
    private static func filename(for recording: Recording) -> String {
        let date = recording.createdAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "\(date) \(sanitize(recording.displayTitle))"
    }

    /// Titles come from a language model, so they can contain anything.
    private static func sanitize(_ text: String) -> String {
        let cleaned = text
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Recording" : trimmed
    }
}
