import Foundation
import Observation
import WhisperKit

// MARK: - WhisperVariant
//
// The models we offer, not every model WhisperKit can load. A picker listing
// twenty CoreML variants asks the reader to know what "large-v2_949MB" costs
// them; four rungs with an honest size and an honest trade does not.
//
// `id` is the repo folder name in `argmaxinc/whisperkit-coreml`, which is what
// `WhisperKit.download(variant:)` matches on.

enum WhisperVariant: String, CaseIterable, Identifiable, Sendable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case turbo = "openai_whisper-large-v3_turbo"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .turbo: return "Large v3 Turbo"
        }
    }

    /// Rounded download size. Deliberately approximate — the exact byte count
    /// depends on the repo revision, and a number that drifts is worse than a
    /// number that is openly a rough one.
    var approximateMB: Int {
        switch self {
        case .tiny: return 75
        case .base: return 145
        case .small: return 470
        case .turbo: return 950
        }
    }

    var blurb: String {
        switch self {
        case .tiny: return "Fastest and smallest. Fine for clear, close speech; it will misread names and technical terms."
        case .base: return "The balanced choice. Noticeably better than Tiny on lecture audio without a long wait."
        case .small: return "More accurate on accents, crosstalk and jargon. Roughly twice the time of Base."
        case .turbo: return "The most accurate option here, and the largest. Best on a recent iPhone with room to spare."
        }
    }

    var sizeLabel: String { "≈\(approximateMB) MB" }

    /// What this device can run without thrashing, as WhisperKit's own device
    /// table reports it. Older hardware is not offered Small or Turbo, because
    /// offering a download that will page the app out is not a choice.
    static var supportedOnThisDevice: [WhisperVariant] {
        let supported = Set(WhisperKit.recommendedModels().supported)
        let allowed = allCases.filter { supported.contains($0.rawValue) }
        // A device WhisperKit has no entry for still gets the two small rungs
        // rather than an empty picker.
        return allowed.isEmpty ? [.tiny, .base] : allowed
    }

    /// The rung to preselect.
    ///
    /// Deliberately *not* WhisperKit's own recommendation, which optimises for
    /// the best transcript a device can manage and lands on Turbo for anything
    /// recent. That is the right answer for a benchmark and the wrong one for a
    /// default: picking "Whisper" would then queue a ≈950 MB download the user
    /// never asked for. Base is the rung the blurb calls balanced, and moving
    /// up is one tap away — capped by what this device actually supports, and
    /// never above what WhisperKit itself would choose.
    static var recommended: WhisperVariant {
        let supported = supportedOnThisDevice
        let ceiling = WhisperVariant(rawValue: WhisperKit.recommendedModels().default)
        let preferred: [WhisperVariant] = [.base, .tiny, .small, .turbo]
        for candidate in preferred where supported.contains(candidate) {
            guard let ceiling, candidate.approximateMB > ceiling.approximateMB else { return candidate }
        }
        return supported.first ?? .base
    }
}

// MARK: - WhisperModelStore
//
// Where the downloaded CoreML models live and what state they're in. Kept apart
// from the transcriber so Settings can show and manage a download without a job
// running, and so the transcriber never has to guess a path: whatever
// `WhisperKit.download` handed back is what gets loaded.

@MainActor
@Observable
final class WhisperModelStore {
    static let shared = WhisperModelStore()

    enum State: Equatable {
        case absent
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var states: [WhisperVariant: State] = [:]

    private let d: UserDefaults
    private var tasks: [WhisperVariant: Task<URL, Error>] = [:]

    /// Everything WhisperKit downloads goes under one folder we own, so
    /// "delete the models" is a folder removal and the storage screen can size
    /// it in one call.
    nonisolated static var downloadBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("WhisperModels", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        for variant in WhisperVariant.allCases {
            states[variant] = folder(for: variant) == nil ? .absent : .ready
        }
    }

    // MARK: Disk

    private func key(_ variant: WhisperVariant) -> String { "whisperModelFolder.\(variant.rawValue)" }

    /// The on-disk folder for a variant, or nil if it isn't downloaded. The
    /// recorded path is re-checked rather than trusted: the container moves
    /// between installs, and a stale path would fail deep inside CoreML with a
    /// message no user could act on.
    func folder(for variant: WhisperVariant) -> URL? {
        guard let path = d.string(forKey: key(variant)) else { return nil }
        // `isDirectory: true` explicitly: the same folder built with and without
        // that hint produces two URLs that are not `==`, and callers compare
        // them. Everything that reads a model folder comes through here so
        // there is one spelling of it.
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            d.removeObject(forKey: key(variant))
            return nil
        }
        return url
    }

    func isReady(_ variant: WhisperVariant) -> Bool { folder(for: variant) != nil }

    func state(_ variant: WhisperVariant) -> State { states[variant] ?? .absent }

    /// Bytes used by every downloaded model, for the storage screen.
    nonisolated static func bytesOnDisk() -> Int64 {
        let base = downloadBase
        guard let e = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    // MARK: Download

    /// Downloads if needed and returns the model folder. Concurrent callers for
    /// the same variant join the one download rather than starting a second:
    /// Settings and a running job asking at the same moment is the normal case,
    /// not the rare one.
    @discardableResult
    func ensure(_ variant: WhisperVariant,
                progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> URL {
        if let url = folder(for: variant) {
            states[variant] = .ready
            return url
        }
        if let running = tasks[variant] {
            return try await running.value
        }

        states[variant] = .downloading(0)
        let task = Task<URL, Error> { [weak self] in
            let url = try await WhisperKit.download(
                variant: variant.rawValue,
                downloadBase: Self.downloadBase
            ) { p in
                let fraction = p.fractionCompleted
                Task { @MainActor [weak self] in
                    self?.states[variant] = .downloading(fraction)
                    progress(fraction)
                }
            }
            return try await MainActor.run { [weak self] in
                guard let self else { throw CancellationError() }
                d.set(url.path, forKey: key(variant))
                states[variant] = .ready
                // Hand back the same URL a later `folder(for:)` will produce,
                // not the one the downloader happened to build.
                return folder(for: variant) ?? url
            }
        }
        tasks[variant] = task

        do {
            let url = try await task.value
            tasks[variant] = nil
            return url
        } catch {
            tasks[variant] = nil
            // A cancelled download is not a failure worth showing as one — the
            // user either switched engines or left the screen.
            states[variant] = error is CancellationError ? .absent : .failed(error.localizedDescription)
            throw error
        }
    }

    func cancelDownload(_ variant: WhisperVariant) {
        tasks[variant]?.cancel()
        tasks[variant] = nil
        if case .downloading = state(variant) { states[variant] = .absent }
    }

    /// Removes one variant from disk. The folder WhisperKit returned sits
    /// inside the snapshot it downloaded, so the repo-level parent goes too
    /// rather than leaving the blobs behind weighing the same as the model.
    func delete(_ variant: WhisperVariant) {
        cancelDownload(variant)
        if let url = folder(for: variant) {
            try? FileManager.default.removeItem(at: url)
        }
        d.removeObject(forKey: key(variant))
        states[variant] = .absent
    }

    func deleteAll() {
        for variant in WhisperVariant.allCases { delete(variant) }
        try? FileManager.default.removeItem(at: Self.downloadBase)
    }
}
