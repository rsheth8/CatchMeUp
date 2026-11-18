import Foundation

// Stand-ins for the few app-layer symbols that the shared engine files
// reference but that live in files this tool deliberately does not compile
// (Settings pulls in Keychain, SwiftUI-facing state and the showcase mode).
//
// Keep these shapes identical to the originals:
//   Provider.Kind / ProviderConfig  -> ios/CatchMeUp/Settings/Settings.swift
//   durationText                    -> ios/CatchMeUp/Design/Theme.swift

struct Provider {
    enum Kind: String { case openai, anthropic }
}

struct ProviderConfig {
    var kind: Provider.Kind
    var baseURL: String?
    var model: String
    var apiKey: String
}

func durationText(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
