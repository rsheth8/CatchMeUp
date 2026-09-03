<p align="center">
  <img src="docs/hero.jpg" alt="CatchMeUp — Missed the Zoom. Missed lecture. Still got the notes." width="100%">
</p>

<p align="center">
  <img src="docs/logo.png" width="88" alt="CatchMeUp constellation C">
</p>

<h1 align="center">CatchMeUp</h1>

<p align="center">
  <strong>Missed the Zoom. Missed lecture. Still got the notes.</strong>
</p>

<p align="center">
  A local-first recap engine for people who skip the live session and still have to own what was said.
  Batch a week of recordings on the Mac. Carry the same library on iPhone.
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-CLI-0E7C86?style=flat-square">
  <img alt="iOS 17+" src="https://img.shields.io/badge/iPhone-iOS%2017%2B-0E7C86?style=flat-square">
  <img alt="Python 3.10+" src="https://img.shields.io/badge/Python-3.10%2B-0E7C86?style=flat-square">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-0E7C86?style=flat-square">
  <img alt="License MIT" src="https://img.shields.io/badge/License-MIT-0E7C86?style=flat-square">
</p>

---

## Why it exists

Live-capture tools assume you were in the room. CatchMeUp assumes you were not.

Drop a Zoom export, a lecture capture, or a folder of OCW videos. Audio is transcribed **on your Mac** with WhisperKit. Notes are written by **your** LLM — Anthropic, OpenAI, Gemini, Groq, or local Ollama. The same recaps, brains, exams, and clips live on the iPhone through iCloud Drive.

| You | Drop in | You get |
|---|---|---|
| **Work** | Zoom, Meet, standup, 1:1, client call | TL;DR, decisions, **action items**, timestamped bookmarks |
| **School** | Recorded lecture, seminar, discussion | What you missed, **terms**, lecture notes, **study / exam checklist** |

Same pipeline either way — only the recap style changes:

```
recording  →  ffmpeg (mp3)  →  whisperkit-cli (on-device)  →  your LLM  →  Word + Markdown
```

Long lectures are split on timestamps, recapped in passes, then merged. Bring your own API key. Audio never leaves the device.

The command is `./catchup`. The iPhone app is in [`ios/`](ios/README.md).

---

## Two surfaces, one library

<p align="center">
  <img src="docs/logo.png" width="48" alt="">
</p>

| | **Mac CLI** | **iPhone** |
|---|---|---|
| For | A week of files, folders, watch folders | Record in class, replay on the train |
| Transcribe | WhisperKit (on-device) | Apple Speech (on-device) |
| Recap | Your cloud LLM or Ollama | Demo / your key / Apple on-device |
| After | `exam`, `clip`, `think`, `cortex`, `sync` | Exam, Clip, Ask, player, iCloud |

```bash
./catchup lecture ~/Downloads/week3.mp4
./catchup sync              # same notes on the phone
```

On the phone: **Settings ▸ Sync**, same Apple Account. Recaps auto-push after a CLI run once that iCloud folder exists. `CATCHMEUP_SYNC=0` opts out.

---

## Install (about 5 minutes)

You need a Mac and [Homebrew](https://brew.sh). **Do not share your `.env`** — that file is the API key.

```bash
git clone https://github.com/rsheth8/CatchMeUp.git
cd CatchMeUp
chmod +x catchup watch_and_process.sh
./catchup setup
```

`./catchup setup` installs the two packages this cannot run without:

| Package | What it does |
|---|---|
| **ffmpeg** | Turns `.mov` / `.mp4` / `.m4a` / … into an `.mp3` WhisperKit can read |
| **whisperkit-cli** | On-device transcription with timestamps |

Then pick a provider and a default style:

```bash
./catchup providers
./catchup config anthropic       # paste a Claude / OpenAI / Gemini / … key
# or stay local, no cloud key:
#   ./catchup config ollama
#   ollama pull qwen3.6:35b
./catchup mode meeting           # work
./catchup mode lecture           # school
./catchup doctor
```

`./catchup doctor` is the send-this-to-a-friend check. If it is green, they are ready.

---

## Everyday use

**One call, right now**

```bash
./catchup meeting ~/Desktop/standup.mov
./catchup open
```

**One lecture, right now**

```bash
./catchup lecture ~/Downloads/cs61a-week3.mp4
./catchup open
```

**Drop-box for the week** (leave it running)

```bash
./catchup watch lecture
./catchup drop ~/Downloads/week4-os.m4a
```

If the filename already says `lecture`, `class`, `week`, `zoom`, `standup`, `1-1`, CatchMeUp can guess. Passing `meeting` or `lecture` always wins.

---

## Brains — named agents over what you missed

Generic RAG over “all my PDFs” is everywhere. CatchMeUp’s wedge is a **named specialist** bound to a folder of recaps you actually skipped:

| Brain folder | Agent | You ask |
|---|---|---|
| `brains/cs61a/` | Course TA | “Explain environment diagrams from week 3” |
| `brains/acme-client/` | Account memory | “What did we promise them about billing?” |
| `brains/standups/` | Team historian | “Who owns the auth migration?” |

Each brain has a persona, an inbox, and a recap corpus the search cannot leave. Ask it from the terminal or from the iOS app.

```bash
./catchup brain new cs61a --lecture
./catchup brain persona cs61a You are a CS 61A TA. Prefer SICP vocabulary.
./catchup into cs61a ~/Downloads/week3.mp4
./catchup into mit-60001 MIT-6.0001/    # whole folder; originals stay put
./catchup ask cs61a what is a binary heap?
./catchup think cs61a explain mutexes for the midterm
./catchup exam cs61a
./catchup clip cs61a mutex
./catchup rec lecture          # mic → recap (Ctrl-C to stop)
./catchup diff cs61a
./catchup cortex cs61a
./catchup watch cs61a          # brains/cs61a/inbox/
```

**`think`** is four passes, not one chatbot call: decompose → fire related concepts in that brain’s cortex → gather cited claims → critique gaps → synthesize. Inspect the graph with `./catchup cortex cs61a`.

Meetings get **speaker labels** (WhisperKit diarization) so action items can say `Speaker 1 / Jordan`. Lectures skip diarization unless you set `CATCHMEUP_DIARIZE=1`.

Each recap also writes Markdown and Word into `output/`. Stay in CatchMeUp — you do not need a second notes app:

```bash
./catchup notes cs61a
./catchup walk cs61a mutex
./catchup graph cs61a          # opens a clickable graph in the browser
```

Obsidian is optional: `./catchup obsidian cs61a` dumps a vault if you already live there.

---

## What the notes look like

**Meeting** (`*_meeting_notes.docx`)

- TL;DR
- Action items & follow-ups (owners / deadlines when they were said)
- Timestamped bookmarks
- Detailed notes

**Lecture** (`*_lecture_notes.docx`)

- What you missed
- Key moments (definitions, worked examples, “this will be on the exam”)
- Lecture notes by topic
- Terms & definitions
- Study / exam checklist

---

## Commands

Run `./catchup` or `./catchup help` for the full list.  
`./catchup help exam` (or `rec`, `brain`, `clip`, …) prints a short page for that command.

<details>
<summary><strong>Setup & config</strong></summary>

| Command | What it does |
|---|---|
| `./catchup setup` | Install ffmpeg, whisperkit-cli, Python, `.env` |
| `./catchup doctor` | Check ffmpeg, whisperkit-cli, API key, folders |
| `./catchup config` | Pick a company and paste its API key |
| `./catchup config openai` | Same, skipping the menu |
| `./catchup providers` | List Anthropic, OpenAI, Gemini, Groq, OpenRouter, … |
| `./catchup model MODEL` | Override the default model for that company |
| `./catchup mode meeting\|lecture` | Set the default recap style |

</details>

<details>
<summary><strong>Recap</strong></summary>

| Command | What it does |
|---|---|
| `./catchup meeting FILE` | Recap a **work** recording |
| `./catchup lecture FILE` | Recap a **class** recording |
| `./catchup drop FILE` | Copy a file into `recordings/` |
| `./catchup watch meeting` | Auto-recap new files as meetings |
| `./catchup watch lecture` | Auto-recap new files as lectures |
| `./catchup rec` | Record from the mic, then recap |
| `./catchup install-watch meeting\|lecture` | Background watcher (launchd) |

</details>

<details>
<summary><strong>Brains, exam, clip</strong></summary>

| Command | What it does |
|---|---|
| `./catchup brain new NAME --lecture\|--meeting` | Create a specialist agent folder |
| `./catchup into NAME FILE` | Recap a recording **into that brain** |
| `./catchup ask NAME QUESTION` | RAG over that brain only |
| `./catchup think NAME TASK` | Deep multi-pass analysis |
| `./catchup exam NAME` | Practice exam from that brain |
| `./catchup clip NAME WORDS` | Play ~25s of that concept |
| `./catchup diff NAME` | What changed since the previous recap |
| `./catchup cortex NAME` | Show that brain's concept graph |

</details>

<details>
<summary><strong>Library & Mac ↔ iPhone</strong></summary>

| Command | What it does |
|---|---|
| `./catchup search WORDS` | Find a topic across meetings + lectures |
| `./catchup ask QUESTION` | Ask your library |
| `./catchup quiz` | Flashcards from lecture terms |
| `./catchup todos` | Action items from all meetings |
| `./catchup moments` | Timestamps from the latest recap |
| `./catchup play HH:MM:SS` | Play 25s of that moment |
| `./catchup sync` | What the Mac and the iPhone each hold |
| `./catchup sync push` | Send recaps to the iPhone (`--with-audio` for playback) |
| `./catchup sync pull` | File iPhone recordings into CLI brains |

</details>

---

## Mac + iPhone

The CLI is the batch engine. The iOS app is the pocket surface. They share a library through the app’s iCloud Drive folder — no extra account.

1. On the iPhone: **Settings ▸ Sync** on, signed into the same Apple Account as this Mac.
2. Recap as usual. When the iCloud folder already exists, CatchMeUp pushes notes to the phone by itself.
3. Record on the phone, then `./catchup sync pull` so exam / clip / think see it too.

```bash
./catchup sync
./catchup sync push
./catchup sync push --with-audio
./catchup sync pull
```

Prefer Dropbox or a USB stick?

```bash
CATCHMEUP_SYNC_DIR=~/Dropbox/CatchMeUp ./catchup sync push
```

The Simulator helper `ios/tools/load_cli_data.py` is only for development. A real iPhone uses this path.

Build the app: see [`ios/README.md`](ios/README.md).

```bash
cd ios
brew install xcodegen   # once
xcodegen generate
open CatchMeUp.xcodeproj
```

---

## Privacy

- **Audio stays on the device** for transcription (WhisperKit on Mac, Apple Speech on iPhone).
- The **text transcript** is sent to whichever LLM you configured, to write the notes.
- `.env` is gitignored. Don’t zip it, don’t Slack it, don’t commit it.

---

## LLM providers

```bash
./catchup providers
./catchup config gemini
./catchup model gemini-2.5-flash
```

| id | Company |
|---|---|
| `anthropic` | Anthropic Claude |
| `openai` | OpenAI GPT |
| `gemini` | Google Gemini |
| `groq` | Groq |
| `openrouter` | OpenRouter (one key, many models) |
| `deepseek` | DeepSeek |
| `mistral` | Mistral |
| `together` | Together AI |
| `xai` | xAI Grok |
| `ollama` | Ollama on your machine (no cloud key). Default: `qwen3.6:35b` |
| `custom` | Any OpenAI-compatible base URL |

```bash
./catchup config custom https://your-gateway.example/v1
```

---

## Folders

```
./catchup         CLI
catchmeup/        Python package
recordings/       drop files here
output/           finished Word notes
processed/        originals + mp3 + transcript, archived per run
brains/           specialist agents (gitignored except README)
ios/              SwiftUI app
docs/             logo + README art
logs/             pipeline.log
.env              your API key + default mode — never commit this
```

Recaps live under `CATCHMEUP_HOME` (the repo root unless you set it).

Supported media: `.mov` `.mp4` `.m4a` `.mp3` `.wav` `.aac` `.mkv` `.webm`

---

## If something fails

| Symptom | Fix |
|---|---|
| `ffmpeg not found` | `brew install ffmpeg` then `./catchup doctor` |
| `whisperkit-cli not found` | `brew install whisperkit-cli` then `./catchup doctor` |
| `ANTHROPIC_API_KEY not set` / no API key | `./catchup config anthropic` or `./catchup config ollama` |
| Notes feel like a meeting but it was class | `./catchup lecture FILE` (or `./catchup mode lecture`) |
| Notes feel like a lecture but it was work | `./catchup meeting FILE` |
| File sits in `recordings/` | Size must be stable (still copying). Then `./catchup status` |

Full traceback lives in `logs/pipeline.log`.

---

## Tests

Recaps, brains, and cortex honor `CATCHMEUP_HOME`, so the suite uses a temp directory and never writes into your real library.

```bash
python3 -m unittest discover -s tests -v
```

That covers brains, cortex, chunking, search, the graph, and the CLI. It does **not** call ffmpeg, whisperkit-cli, or a live LLM.

iOS unit tests:

```bash
cd ios && xcodegen generate
xcodebuild -project CatchMeUp.xcodeproj -scheme CatchMeUp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

---

<p align="center">
  <img src="docs/logo.png" width="56" alt="CatchMeUp">
</p>

<p align="center">
  <sub>MIT License · Audio on-device · Your key, your model</sub>
</p>
