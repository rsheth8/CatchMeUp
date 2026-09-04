<p align="center">
  <img src="../docs/logo.png" width="96" alt="CatchMeUp">
</p>

<h1 align="center">CatchMeUp — iPhone</h1>

<p align="center">
  Native SwiftUI. Record → on-device transcript (Apple Speech) → recap → notes.<br>
  Companion to the <code>./catchup</code> CLI. Same library, same brains, same exam and clip.
</p>

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

### Unit tests

`CatchMeUpTests` covers the logic that has no UI to check it by eye: transcript chunking and
recap merging, retrieval ranking and budgeting, lenient JSON parsing, guided-generation
cleanup and prompt assembly, and the progress and time-remaining maths.

```bash
xcodebuild -project CatchMeUp.xcodeproj -scheme CatchMeUp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

### Show the app without an API key

Open **Settings → Explore the showcase account**. This is a separate local library:
your personal recordings, settings, Keychain credentials, iCloud data, and study history
are not replaced. Exit returns to your account; app relaunches always start there.
Finish ongoing processing before switching. Showcase edits persist between visits.

The showcase includes 12 short narrated sessions across Computer Science, Statistics,
Payments, and Product Studio; timestamp-matched audio and key moments; linked PDFs and
slides; meeting decisions, blockers, owners and follow-ups; seven days of fictional
study history; and two upcoming exams. The **Take a tour** banner provides starting points.

Search, playback, documents, neural maps, practice grading, scheduling, task editing,
and exports use the real app. Brain chat selects relevant source excerpts locally;
meeting analysis uses deterministic extraction. They are **not live AI generation**.
Demo capture uses a narrated fixture instead of pretending to transcribe microphone
audio. Import your own audio in your personal account with a real recap engine selected.
The showcase does not enable iCloud or automatic study/recap notifications.

Narration assets are fictional, generated locally with macOS `say`, and add about 2 MB.
To rebuild them after editing `ShowcaseAssets/showcase-source.json`, run
`python3 ios/tools/build_showcase_audio.py` (requires macOS and FFmpeg).
Unit tests verify content, audio offsets, local answers, and isolation; UI tests exercise
the tour, account exit, capture/playback, and source-backed chat in the Simulator.

### Test with your existing CLI library

Build and launch the app in a Simulator once, then from the repository root run:

```bash
python3 ios/tools/load_cli_data.py
```

This merges the local CLI brains, finished recaps, and transcripts into the booted Simulator.
It creates a backup in the Simulator app container first and never changes the CLI library.
Archived audio is skipped by default so a large library imports quickly. To test playback too:

```bash
python3 ios/tools/load_cli_data.py --brain mit-60002 --limit 3 --with-audio
```

To add audio for one recap you're testing, match any distinctive part of its title or filename:

```bash
python3 ios/tools/load_cli_data.py --match "Program Efficiency, Part 2" --with-audio
```

Use `--replace` for a clean iOS library instead of a merge, or `--dry-run` to inspect the count
without changing the Simulator.

### Transcription does not run in the Simulator

The Simulator ships no speech models, so this is the one step you cannot exercise there.
Both engines claim to be present and neither works: `SFSpeechRecognizer` reports
`isAvailable` and `supportsOnDeviceRecognition` as true and then fails with
`kAFAssistantErrorDomain Code=1101`, and iOS 26's `SpeechAnalyzer` reports
`SpeechTranscriber.isAvailable == false` with zero supported locales and
`AssetInventory.status == .unsupported`. Both work on a real device. There is nothing
to fix in the app — server-based recognition would transcribe fine here, but it would
send the audio to Apple and break the promise the rest of the app is built on.

To exercise everything downstream of transcription — notes, questions, prequestions,
study — run that one step on the Mac, which does have the models, and load the result:

```bash
swift ios/tools/transcribe_on_host.swift path/to/audio.m4a > segments.json
```

It uses the same framework and the same chunking rule as the app, so the segments are
the ones the phone would have produced.

## What works now (Phase 0–1)

| Area | Status |
|---|---|
| Onboarding, tab navigation, light/dark | ✅ |
| Library: search across notes, mode filters, date grouping, swipe-delete, rename | ✅ |
| Record from mic (`AVAudioRecorder`) with live waveform + pause/resume; import a file | ✅ |
| On-device transcription with timestamps (`SpeechAnalyzer` on iOS 26, `SFSpeechRecognizer` below) | ✅ device only |
| Recap engine — **Demo**, **Your API key** (Anthropic + any OpenAI-compatible), **On-device** (iOS 26 Foundation Models, guided generation via `@Generable`) | ✅ |
| Meeting + lecture recap views, tickable action items, scrubbing player, searchable transcript, Markdown share | ✅ |
| Brains: create, assign recaps, ask (scoped RAG), jump to audio, hand a course to the Study tab | ✅ |
| Study loop: questions minted from every recap, FSRS-5 scheduling, confidence rating before each reveal, flashcards / practice exam / weak-spot drill / focus sessions | ✅ |
| Prequestions — two or three questions before a recap's first read, unscored and unscheduled | ✅ |
| Daily review reminder, written from the real schedule and silent on days with nothing due | ✅ |
| API key stored in Keychain; audio never leaves the device | ✅ |
| App icon (generated by `tools/make_icon.swift`) | ✅ |
| iCloud sync across devices (Settings ▸ Sync) | ✅ |
| Spotlight search + deep links into individual recaps | ✅ |
| Siri and Shortcuts actions for recording and recap search | ✅ |
| Handoff for continuing an open recap on another Apple device | ✅ |
| Lock Screen Live Activity + Dynamic Island processing progress | ✅ |
| Send meeting follow-ups to Apple Reminders | ✅ |
| Background recording while the iPhone is locked or another app is open | ✅ |

### Design system

`Design/Theme.swift` holds the tokens — palette (icon teal → seafoam, amber for
lectures), corner radii, motion curves, the ambient background wash and haptics.
`Design/Design.swift` holds the shared components every screen is built from:
`Card`, `SectionHeader`, `Chip`, `FilterChip`, `IconTile`, `EmptyState`,
`WaveBars`, `BrandMark` (the app icon's constellation, redrawn in SwiftUI) and
the button styles. Add UI by composing these rather than restyling in place.

`Design/Markdown.swift` renders model prose. Anything the model writes — a brain
answer, a detailed note, a bullet — goes through `MarkdownText` (block layout:
headings, lists, quotes, fenced code, tables, rules) or `Text(md:)` for a single
inline string. Never put a model's output in a plain `Text`, or the reader sees
the `**` and `##` instead of the formatting. Both take a `MarkdownStyle`, whose
`tint` should be the surrounding mode accent.

### iCloud sync

Off by default. Turn it on in **Settings ▸ Sync**. It uses the app's iCloud Drive
ubiquity container (`iCloud.com.catchmeup.app`): the `recordings.json` / `brains.json`
library and the `audio/` folder live there and Apple syncs them across the user's
devices — including the Mac CLI, which reads and writes that same folder with
`./catchup sync`. Merge is union-by-id, newest `updatedAt` wins; deletes are tombstoned so
they propagate instead of resurrecting. Live updates come from an `NSMetadataQuery`;
a merge also runs on foreground.

On the Mac, recaps also push themselves after `./catchup lecture` / `into` whenever
this folder already exists. `ios/tools/load_cli_data.py` is only for the Simulator.

First build with your own team: Xcode will offer to enable the **iCloud** capability
and create the container — accept it. On the Simulator (no iCloud account / stripped
entitlement) the toggle shows "Sign in to iCloud…" and the app stays local — expected.

### Apple integrations

- Finished recaps are indexed privately in Spotlight. Tapping a result opens that recap directly.
- Siri and the Shortcuts app expose **Record Meeting**, **Record Lecture**, and **Search Recaps**.
- Long-press the app icon for the same recording and search quick actions.
- While CatchMeUp transcribes and writes notes, progress appears as a Live Activity and in the
  Dynamic Island on supported iPhones, with an estimated time remaining. Tapping it returns to
  the recap.
- Recording uses Apple's background audio mode, so locking the iPhone or briefly switching apps
  does not cut off a meeting or lecture.
- Processing is not tied to the screen that started it. Jobs run one at a time on an app-scoped
  queue, hold a background assertion so leaving the app doesn't suspend them mid-transcription,
  and fall back to a `BGProcessingTask` when iOS reclaims the time. A local notification arrives
  when notes are ready if you're no longer in the app.
- Open recaps advertise a private Handoff activity so they can continue on another signed-in device.
- Each meeting action item's menu can add that follow-up to the default Apple Reminders list.

## Not yet (later phases)

- WhisperKit for higher-accuracy transcription + diarization
- Cortex concept graph (exam, clip, and the neural map preview ship)
- `.docx` export (Markdown only for now)
- Richer conflict handling for sync

## Beta

[`BETA.md`](BETA.md) has the TestFlight path: what App Store Connect asks for,
the archive invocation, tester notes, and the known limits worth stating up
front. In the app, **Settings ▸ Send feedback** shares a report carrying version,
device and library counts — never notes, transcripts, answers or the API key
(`App/Diagnostics.swift`, and the tests that hold it to that).

## Layout

```
CatchMeUp/
  App/            entry point, tab shell
  Models/         Recording, Transcript, Recap, Brain, Mode
  Persistence/    LibraryStore — JSON in Application Support
  Settings/       AppSettings, provider list, Keychain
  Engine/         Prompts, LLMClient, RecapEngine (Demo / Cloud / Apple on-device),
                  OnDeviceRecap (@Generable schema for Apple Intelligence),
                  RecapChunking (long transcripts), Retrieval (ranked context for asks)
  Transcription/  SpeechTranscriber (on-device) + Mock
  Audio/          recorder + player
  Pipeline/       ProcessingQueue — transcribe → recap → save, plus background
                  assertions, BGProcessingTask resumption and time estimates
  Study/          FSRS (scheduler), QuestionMint (recap → questions), Grading,
                  Prequestions (the before-you-read warm-up), StudyStore,
                  StudyNotifier (the daily reminder)
  Design/         Theme (tokens) + Design (components)
  Features/       Onboarding, Home (library + recorder), Recap, Study, Brains, Settings
  Sample/         demo recaps
CatchMeUpTests/   unit tests for the scheduler, question minting, reminders,
                  chunking, merging, retrieval, estimates and the bug report
```
