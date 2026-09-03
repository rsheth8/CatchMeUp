import Foundation

/// Moves the audio folder between its local home and iCloud Drive.
///
/// The old version of this copied JSON and audio on the main thread and gave up
/// silently on anything that already existed at the destination, which meant a
/// large library froze the app and a partial move looked like a finished one.
enum CloudMigration {
    struct Report: Sendable, Equatable {
        var moved = 0
        /// Already at the destination.
        var skipped = 0
        /// In iCloud but not on this device, so there was nothing to copy down.
        var notDownloaded = 0
        var failed = 0
        var bytes: Int64 = 0
        var failureReason: String?

        var isClean: Bool { failed == 0 }
    }

    /// Hands the local audio folder to iCloud.
    ///
    /// `setUbiquitous` moves rather than copies, so the device doesn't end up
    /// holding two of everything — and if it throws, the local file is still
    /// exactly where it was.
    static func moveToCloud(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> Report {
        await transfer(from: source, to: destination, progress: progress) { fm, file, target in
            try fm.setUbiquitous(true, itemAt: file, destinationURL: target)
            return true
        }
    }

    /// Brings iCloud audio back down to the device.
    ///
    /// Copies rather than moves: the iCloud copy is left alone so nothing is
    /// riding on this succeeding. Files that aren't downloaded are requested and
    /// counted, not waited for — a library can be larger than the user's
    /// patience, and `AudioStorage` keeps reading them from the container in the
    /// meantime.
    static func copyFromCloud(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> Report {
        await transfer(from: source, to: destination, progress: progress) { fm, file, target in
            guard fm.fileExists(atPath: file.path) else {
                try? fm.startDownloadingUbiquitousItem(at: file)
                return false
            }
            try fm.copyItem(at: file, to: target)
            return true
        }
    }

    // MARK: - Plumbing

    /// `action` returns false when the file wasn't available to transfer, which
    /// is different from failing.
    private static func transfer(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int, Int) -> Void,
        action: @escaping @Sendable (FileManager, URL, URL) throws -> Bool
    ) async -> Report {
        await Task.detached(priority: .utility) { () -> Report in
            let fm = FileManager.default
            var report = Report()
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

            guard let contents = try? fm.contentsOfDirectory(
                at: source, includingPropertiesForKeys: [.fileSizeKey]
            ) else { return report }

            // An evicted iCloud file shows up as `.name.m4a.icloud`, so the
            // directory listing has to be un-mangled before anything else.
            let names = contents.compactMap { realName(of: $0.lastPathComponent) }
            let unique = Array(Set(names)).sorted()

            for (index, name) in unique.enumerated() {
                progress(index, unique.count)
                let file = source.appendingPathComponent(name)
                let target = destination.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) {
                    report.skipped += 1
                    continue
                }
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map(Int64.init) ?? 0
                do {
                    if try action(fm, file, target) {
                        report.moved += 1
                        report.bytes += size
                    } else {
                        report.notDownloaded += 1
                    }
                } catch {
                    report.failed += 1
                    report.failureReason = error.localizedDescription
                }
            }
            progress(unique.count, unique.count)
            return report
        }.value
    }

    /// The name a file has when it's downloaded, given whatever the directory
    /// listing showed. Nil for dot-files that aren't iCloud placeholders.
    static func realName(of component: String) -> String? {
        guard component.hasPrefix(".") else { return component }
        guard component.hasSuffix(".icloud") else { return nil }
        return String(component.dropFirst().dropLast(".icloud".count))
    }
}
