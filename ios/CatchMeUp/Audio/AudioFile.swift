import Foundation
@preconcurrency import AVFoundation
import CoreMedia

// MARK: - What a file on disk actually is

/// Measured, not assumed. Imports arrive in whatever shape the user had them,
/// and recordings made before the format was pinned down are all over the map.
struct AudioFacts: Sendable, Equatable {
    var byteSize: Int64
    var duration: Double
    var codec: String?
    var bitRate: Int?
    var sampleRate: Int?
    var channels: Int?

    /// "AAC · 64 kbps · mono"
    var formatLabel: String {
        var parts: [String] = []
        if let codec { parts.append(codec.uppercased()) }
        if let bitRate, bitRate > 0 { parts.append("\(Int((Double(bitRate) / 1000).rounded())) kbps") }
        switch channels {
        case 1: parts.append("mono")
        case 2: parts.append("stereo")
        case let c?: parts.append("\(c) ch")
        default: break
        }
        return parts.isEmpty ? "Unknown format" : parts.joined(separator: " · ")
    }
}

enum AudioFile {
    /// Reads size, duration and stream format. Returns nil only when the file
    /// isn't there — a file we can't decode still reports its size, which is
    /// what the storage dashboard needs most.
    static func facts(at url: URL) async -> AudioFacts? {
        guard let size = byteSize(at: url) else { return nil }
        var facts = AudioFacts(byteSize: size, duration: 0)

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return facts }

        facts.duration = (try? await asset.load(.duration).seconds) ?? 0
        if facts.duration.isNaN || facts.duration.isInfinite { facts.duration = 0 }

        if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            facts.bitRate = Int(rate)
        }
        if let descriptions = try? await track.load(.formatDescriptions),
           let asbd = descriptions.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) {
            facts.codec = codecName(asbd.mFormatID)
            facts.sampleRate = Int(asbd.mSampleRate)
            facts.channels = Int(asbd.mChannelsPerFrame)
        }
        return facts
    }

    static func byteSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private static func codecName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
            return "aac"
        case kAudioFormatMPEGLayer1, kAudioFormatMPEGLayer2, kAudioFormatMPEGLayer3: return "mp3"
        case kAudioFormatLinearPCM: return "pcm"
        case kAudioFormatAppleLossless: return "alac"
        case kAudioFormatOpus: return "opus"
        case kAudioFormatFLAC: return "flac"
        case kAudioFormatAMR, kAudioFormatAMR_WB: return "amr"
        case kAudioFormatAppleIMA4: return "ima4"
        default: return fourCharCode(id)
        }
    }

    private static func fourCharCode(_ id: AudioFormatID) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((id >> UInt32($0)) & 0xFF) }
        let text = String(bytes: bytes, encoding: .macOSRoman)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? "unknown" : text
    }
}

// MARK: - Re-encoding

/// Converts an existing file into our own mono AAC format.
///
/// Nothing here touches the original. The caller gets a finished temporary file
/// and decides whether to swap it in — see `AudioStorage.replaceAudio`.
enum AudioTranscoder {
    enum Failure: LocalizedError {
        case noAudioTrack
        case unreadable(String)
        case unwritable(String)
        case durationDrift(expected: Double, actual: Double)
        case noSaving

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "This file has no audio track."
            case .unreadable(let why): return "Couldn't read the audio (\(why))."
            case .unwritable(let why): return "Couldn't write the converted audio (\(why))."
            case .durationDrift(let expected, let actual):
                return "The converted audio ran \(durationText(actual)) instead of \(durationText(expected)), so the original was kept."
            case .noSaving: return "Converting this file wouldn't save any space."
            }
        }
    }

    /// Longest gap we'll accept between the source and the result. Encoders pad
    /// the final AAC frame, so an exact match never happens.
    private static let durationTolerance: Double = 0.75

    /// Writes a converted copy to `destination` and returns what it measured.
    ///
    /// Throws `Failure.durationDrift` if the result doesn't run as long as the
    /// source, which is the cheap way to catch a truncated or silent encode
    /// before it replaces something irreplaceable.
    @discardableResult
    static func encode(
        _ source: URL,
        to destination: URL,
        quality: AudioQuality,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioFacts {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudioTrack
        }
        let sourceDuration = try await asset.load(.duration).seconds
        try? FileManager.default.removeItem(at: destination)

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw Failure.unreadable(error.localizedDescription) }

        // Plain interleaved 16-bit PCM, no channel layout. Anything more exotic
        // in reader settings raises an Objective-C exception rather than
        // throwing, so this stays on the well-trodden path.
        let pcm: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: quality.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // The mix output, rather than a plain track output, because it's the
        // path that reliably downmixes stereo to mono and resamples on the way.
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: pcm)
        guard reader.canAdd(output) else { throw Failure.unreadable("unsupported source format") }
        reader.add(output)

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: destination, fileType: .m4a) }
        catch { throw Failure.unwritable(error.localizedDescription) }

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: quality.writerSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.unwritable("unsupported output format") }
        writer.add(input)

        guard reader.startReading() else {
            throw Failure.unreadable(reader.error?.localizedDescription ?? "reader wouldn't start")
        }
        guard writer.startWriting() else {
            throw Failure.unwritable(writer.error?.localizedDescription ?? "writer wouldn't start")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try await pump(output, from: reader, into: input, on: writer,
                           totalDuration: sourceDuration, progress: progress)
        } catch {
            reader.cancelReading()
            await writer.finishWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.unwritable(writer.error?.localizedDescription ?? "encode didn't finish")
        }

        guard let facts = await AudioFile.facts(at: destination) else {
            throw Failure.unwritable("the converted file went missing")
        }
        guard sourceDuration <= 0 || abs(facts.duration - sourceDuration) <= durationTolerance else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.durationDrift(expected: sourceDuration, actual: facts.duration)
        }
        return facts
    }

    /// Drives samples from reader to writer.
    ///
    /// `AVAssetWriterInput` calls the block back every time it drains, and the
    /// block may still be in flight when we finish, so `Once` guarantees the
    /// continuation resumes exactly one time.
    private static func pump(
        _ output: AVAssetReaderOutput,
        from reader: AVAssetReader,
        into input: AVAssetWriterInput,
        on writer: AVAssetWriter,
        totalDuration: Double,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let queue = DispatchQueue(label: "com.catchmeup.transcode")
        // AVFoundation's writer/reader types predate Swift concurrency. They
        // are deliberately confined to this one serial queue; wrapping them
        // as one transfer object makes that ownership explicit and prevents a
        // future Swift language-mode upgrade from turning imports into errors.
        let context = AudioPumpContext(output: output, reader: reader,
                                       input: input, writer: writer)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                context.input.requestMediaDataWhenReady(on: queue) {
                    // A writer that has already failed stops asking for data, so
                    // without this the continuation would never resume.
                    if context.writer.status == .failed {
                        if context.once.claim() {
                            context.input.markAsFinished()
                            let why = context.writer.error?.localizedDescription ?? "the writer failed"
                            continuation.resume(throwing: Failure.unwritable(why))
                        }
                        return
                    }
                    while context.input.isReadyForMoreMediaData {
                        if Task.isCancelled {
                            if context.once.claim() {
                                context.input.markAsFinished()
                                continuation.resume(throwing: CancellationError())
                            }
                            return
                        }
                        guard let sample = context.output.copyNextSampleBuffer() else {
                            if context.once.claim() {
                                context.input.markAsFinished()
                                // A failed read also returns nil, which would
                                // otherwise pass for a clean end of stream and
                                // silently truncate the recording.
                                if context.reader.status == .failed {
                                    let why = context.reader.error?.localizedDescription
                                        ?? "the source couldn't be read to the end"
                                    continuation.resume(throwing: Failure.unreadable(why))
                                } else {
                                    progress?(1)
                                    continuation.resume()
                                }
                            }
                            return
                        }
                        if totalDuration > 0, let progress {
                            let at = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            if at.isFinite { progress(min(1, max(0, at / totalDuration))) }
                        }
                        guard context.input.append(sample) else {
                            if context.once.claim() {
                                context.input.markAsFinished()
                                let why = context.writer.error?.localizedDescription ?? "the writer rejected a sample"
                                continuation.resume(throwing: Failure.unwritable(why))
                            }
                            return
                        }
                    }
                }
            }
        } onCancel: {
            queue.async { context.input.markAsFinished() }
        }
    }
}

// MARK: - Small concurrency helpers

/// A one-shot latch. Cheaper than an actor and usable from the AVFoundation
/// callbacks, which are synchronous and can't await anything.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for exactly one caller, ever.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// All non-Sendable AVFoundation objects used by one encode. Access is
/// serialized by `AudioTranscoder.pump`; the box exists to document and
/// enforce that transfer boundary in one place.
private final class AudioPumpContext: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let reader: AVAssetReader
    let input: AVAssetWriterInput
    let writer: AVAssetWriter
    let once = Once()

    init(output: AVAssetReaderOutput, reader: AVAssetReader,
         input: AVAssetWriterInput, writer: AVAssetWriter) {
        self.output = output
        self.reader = reader
        self.input = input
        self.writer = writer
    }
}

/// Thins a firehose of progress callbacks down to something worth sending to
/// the main actor.
final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private let step: Double
    private var last = -1.0

    init(step: Double = 0.02) { self.step = step }

    func shouldReport(_ value: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value >= 1 || value - last >= step else { return false }
        last = value
        return true
    }
}
