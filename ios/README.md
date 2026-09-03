# CatchMeUp — iOS app

Native SwiftUI app. Recording → on-device transcript (Apple Speech) → recap → notes.
Companion to the `catchup` CLI at the repo root; shares the prompt schemas and provider list.

## Run it

```bash
brew install xcodegen          # once
cd ios
xcodegen generate              # writes CatchMeUp.xcodeproj from project.yml
open CatchMeUp.xcodeproj
```

Pick a Simulator (or your device + your team in **Signing & Capabilities**) and run.
Deployment target is iOS 17; Apple's on-device model path needs iOS 26.

Command-line build:

```bash
xcodebuild -project CatchMeUp.xcodeproj -scheme CatchMeUp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## What works now (Phase 0–1)

| Area | Status |
|---|---|
| Onboarding, tab navigation, light/dark | ✅ |
| Record from mic (`AVAudioRecorder`) + import a file | ✅ |
| On-device transcription with timestamps (`SFSpeechRecognizer`) | ✅ |
| Recap engine — **Demo**, **Your API key** (Anthropic + any OpenAI-compatible), **On-device** (iOS 26 Foundation Models) | ✅ |
| Meeting + lecture recap views, tap-timestamp playback, Markdown share | ✅ |
| Brains: create, assign recaps, ask (scoped RAG), persona | ✅ |
| API key stored in Keychain; audio never leaves the device | ✅ |

## Not yet (later phases)

- WhisperKit for higher-accuracy transcription + diarization
- iCloud / local-network sync with a Mac
- Cortex concept graph, exam/diff, MCP server
- `.docx` export (Markdown only for now)
- App icon, TestFlight polish

## Layout

```
CatchMeUp/
  App/            entry point, tab shell
  Models/         Recording, Transcript, Recap, Brain, Mode
  Persistence/    LibraryStore — JSON in Application Support
  Settings/       AppSettings, provider list, Keychain
  Engine/         Prompts, LLMClient, RecapEngine (Demo / Cloud / Apple on-device)
  Transcription/  SpeechTranscriber (on-device) + Mock
  Audio/          recorder + player
  Pipeline/       RecapPipeline — transcribe → recap → save
  Design/         theme + shared components
  Features/       Onboarding, Home, Recap, Brains, Settings
  Sample/         demo recaps
```
