#!/usr/bin/env swift
//
// transcribe_on_host.swift — transcribe an audio file with Apple's on-device
// engine and print the segments as JSON.
//
// Why this exists: the iOS Simulator ships no speech models. Both engines say
// they are there and neither works — `SFSpeechRecognizer` fails with
// kAFAssistantErrorDomain 1101, and iOS 26's `SpeechAnalyzer` reports
// `isAvailable == false` with zero supported locales. A real iPhone has both.
// So the Simulator can exercise every part of this app except the one step that
// turns audio into words.
//
// This runs that step on the Mac, with the same framework and the same chunking
// rule the app uses (`Transcription.assemble`), so the segments it produces are
// the ones the phone would have produced. Feed them into a Simulator library
// and the rest of the pipeline — notes, questions, prequestions, study — runs
// for real on material that was never in a fixture.
//
// It is a development aid. Nothing in the shipping app calls it.
//
//   swift ios/tools/transcribe_on_host.swift <audio-file> > segments.json
//
// Requires macOS 26 with the language model installed (System Settings ▸
// General ▸ Language & Region, or any use of system dictation).

import AVFoundation
import Foundation
import Speech

struct OutSegment: Codable {
    let start: Double
    let text: String
}

/// The app's rule, copied deliberately rather than shared: this file is built
/// on its own, outside the Xcode project. If `Transcription.assemble` changes,
/// change it here too.
func assemble(_ pieces: [(start: Double, end: Double, text: String)]) -> [OutSegment] {
    var out: [OutSegment] = []
    var buffer = ""
    var chunkStart: Double?
    var lastEnd: Double = 0

    for piece in pieces {
        let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        if chunkStart == nil { chunkStart = piece.start }
        buffer += (buffer.isEmpty ? "" : " ") + text
        lastEnd = piece.end

        let endsSentence = text.range(of: #"[.!?]["')\]]?$"#, options: .regularExpression) != nil
        let longEnough = (lastEnd - (chunkStart ?? 0)) > 18
        if endsSentence || longEnough {
            out.append(OutSegment(start: chunkStart ?? 0, text: buffer))
            buffer = ""
            chunkStart = nil
        }
    }
    if !buffer.isEmpty { out.append(OutSegment(start: chunkStart ?? 0, text: buffer)) }
    return out
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

@available(macOS 26.0, *)
func run(_ url: URL) async throws -> [OutSegment] {
    guard SpeechTranscriber.isAvailable else { fail("SpeechTranscriber is not available on this Mac") }

    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        ?? Locale(identifier: "en-US")
    let module = SpeechTranscriber(locale: locale,
                                   transcriptionOptions: [],
                                   reportingOptions: [],
                                   attributeOptions: [.audioTimeRange])

    switch await AssetInventory.status(forModules: [module]) {
    case .installed:
        break
    case .unsupported:
        fail("no speech model for \(locale.identifier) — install it in System Settings ▸ General ▸ Language & Region")
    case .supported, .downloading:
        FileHandle.standardError.write(Data("downloading speech model…\n".utf8))
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    @unknown default:
        break
    }

    let file = try AVAudioFile(forReading: url)
    let total = Double(file.length) / max(1, file.processingFormat.sampleRate)
    let analyzer = SpeechAnalyzer(modules: [module])

    let collector = Task { () -> [OutSegment] in
        var pieces: [(start: Double, end: Double, text: String)] = []
        var lastReport = 0.0
        for try await result in module.results {
            let start = result.range.start.seconds
            let end = result.range.end.seconds
            pieces.append((start: start.isFinite ? start : 0,
                           end: end.isFinite ? end : 0,
                           text: String(result.text.characters)))
            if total > 0, end.isFinite, end - lastReport > 30 {
                lastReport = end
                let pct = Int(min(99, end / total * 100))
                FileHandle.standardError.write(Data("  \(pct)%\n".utf8))
            }
        }
        return assemble(pieces)
    }

    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
    return try await collector.value
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: transcribe_on_host.swift <audio-file>") }
let url = URL(fileURLWithPath: args[1])
guard FileManager.default.fileExists(atPath: url.path) else { fail("no such file: \(url.path)") }

guard #available(macOS 26.0, *) else { fail("needs macOS 26") }

let segments = try await run(url)
FileHandle.standardError.write(Data("\(segments.count) segments\n".utf8))

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(segments))
