import Foundation
import AVFoundation

/// The recording format, chosen in Settings ▸ Storage.
///
/// Every option is mono AAC in an `.m4a` container. Speech is mono at the
/// source, so the second channel only ever doubled the file. The bit rate is
/// stated outright instead of going through `AVEncoderAudioQualityKey`, which
/// is only a hint to the encoder — asking for `.high` at 44.1 kHz produced
/// roughly 80 MB an hour, most of it spent on frequencies no lecture uses.
enum AudioQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case efficient
    case standard
    case high

    /// What new installs and anyone who never opens Settings records at.
    static let fallback: AudioQuality = .standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .efficient: return "Efficient"
        case .standard: return "Standard"
        case .high: return "High quality"
        }
    }

    var blurb: String {
        switch self {
        case .efficient: return "Smallest files. Fine for one clear voice in a quiet room."
        case .standard: return "Reliable speech for lectures and meetings. Recommended."
        case .high: return "Closest to the room. Worth it for music or a noisy hall."
        }
    }

    /// Bits per second handed to the AAC encoder.
    var bitRate: Int {
        switch self {
        case .efficient: return 48_000
        case .standard: return 64_000
        case .high: return 128_000
        }
    }

    var sampleRate: Double {
        switch self {
        case .efficient: return 22_050
        case .standard: return 32_000
        case .high: return 44_100
        }
    }

    /// Decimal bytes, to match how iOS Settings and the Files app count.
    var bytesPerHour: Int64 { Int64(Double(bitRate) / 8 * 3600) }

    /// Authored rather than computed: AAC spends fewer bits on quiet speech, so
    /// the honest answer for the top setting is a range, not a single number.
    var sizeEstimate: String {
        switch self {
        case .efficient: return "≈22 MB an hour"
        case .standard: return "≈29 MB an hour"
        case .high: return "43–58 MB an hour"
        }
    }

    /// Settings dictionary for `AVAudioRecorder`.
    var recorderSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    /// Output settings for `AVAssetWriter` when re-encoding an import.
    /// `AVAssetWriter` wants the channel layout spelled out; `AVAudioRecorder`
    /// infers it from the channel count.
    var writerSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let layoutData = withUnsafeBytes(of: layout) { Data($0) }
        return [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
            AVChannelLayoutKey: layoutData,
        ]
    }

    /// The container all of our own recordings use.
    static let fileExtension = "m4a"

    /// How `AudioFacts` reports a file we produced.
    static let codec = "aac"

    /// A file already in this shape gains nothing from being re-encoded, and
    /// re-encoding lossy audio always costs a little quality. The 15% headroom
    /// covers encoders that land slightly over the nominal rate.
    func isSatisfied(by facts: AudioFacts) -> Bool {
        guard facts.codec == Self.codec else { return false }
        guard facts.channels ?? 1 <= 1 else { return false }
        guard let rate = facts.bitRate else { return true }
        return Double(rate) <= Double(bitRate) * 1.15
    }
}

// MARK: - Retention

/// How long to keep audio once notes exist. Only ever offered to people whose
/// audio is backed up somewhere, or who opt in with both eyes open — see
/// `AudioRetention.isDestructiveWithoutCloud`.
enum AudioRetention: String, Codable, CaseIterable, Identifiable, Sendable {
    case forever
    case days30
    case days90
    case days180

    static let fallback: AudioRetention = .forever

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .forever: return nil
        case .days30: return 30
        case .days90: return 90
        case .days180: return 180
        }
    }

    var title: String {
        switch self {
        case .forever: return "Keep forever"
        case .days30: return "After 30 days"
        case .days90: return "After 90 days"
        case .days180: return "After 180 days"
        }
    }

    var isAutomatic: Bool { days != nil }

    /// The cutoff a recording has to predate before its audio is eligible.
    func cutoff(from now: Date = .now) -> Date? {
        guard let days else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: now)
    }
}
