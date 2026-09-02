# meet — meeting recordings → Word notes

Drop in a Zoom / Meet / screen recording. This turns it into a `.docx` with:

- a **TL;DR**
- **bookmarked moments** with timestamps
- **detailed notes** and follow-ups

Everything is terminal-based. The command is `./meet`.

```
recording  →  ffmpeg (mp3)  →  whisperkit-cli (transcript)  →  Claude  →  output/*_notes.docx
```

macOS only (WhisperKit is Apple’s on-device speech stack).

---

## Send this to someone

1. Share the GitHub repo (or a zip). **Do not send your `.env`** — that file has your API key.
2. They need a Mac, [Homebrew](https://brew.sh), and an [Anthropic API key](https://console.anthropic.com/settings/keys).
3. Tell them to run the steps below in order. `./meet doctor` will tell them if anything is missing.

---

## Install (about 5 minutes)

```bash
git clone https://github.com/rsheth8/transcribe-proj.git
cd transcribe-proj
chmod +x meet watch_and_process.sh pipeline.py
./meet setup
```

`./meet setup` installs the two packages this project cannot run without (same as `brew bundle` from this repo):

```bash
brew install ffmpeg
brew install whisperkit-cli
```

| Package | What it does |
|---|---|
| **ffmpeg** | Converts `.mov` / `.mp4` / `.m4a` / … into an `.mp3` WhisperKit can read |
| **whisperkit-cli** | On-device transcription with timestamps (no audio sent to OpenAI) |

It also creates a Python virtualenv, installs `anthropic` + `python-docx`, and asks for your Anthropic API key (saved in `.env`, which is gitignored).

Check the machine:

```bash
./meet doctor
```

You want green checkmarks for **ffmpeg**, **whisperkit-cli**, the venv, and `ANTHROPIC_API_KEY`.

---

## Commands

Run `./meet` with no arguments anytime to reprint this list.

| Command | What it does |
|---|---|
| `./meet setup` | First-time install: Homebrew packages, Python, `.env` |
| `./meet doctor` | Check ffmpeg, whisperkit-cli, API key, folders |
| `./meet config` | Paste / update the Anthropic API key |
| `./meet transcribe FILE` | Process **one** recording now |
| `./meet drop FILE` | Copy a file into `recordings/` |
| `./meet watch` | Watch `recordings/` and process new files (Ctrl-C to stop) |
| `./meet status` | What’s waiting, latest notes, watcher on/off |
| `./meet list` | List Word docs in `output/` |
| `./meet logs` | Show the pipeline log (`./meet logs -f` to follow) |
| `./meet open` | Open `output/` in Finder |
| `./meet install-watch` | Background watcher via macOS launchd |
| `./meet uninstall-watch` | Remove the background watcher |

---

## Typical workflows

**One file, right now**

```bash
./meet transcribe ~/Desktop/standup.mov
./meet open          # notes are in output/
```

**Drop-box (leave it running)**

```bash
./meet watch
# in another window, or from Finder:
./meet drop ~/Downloads/zoom-call.m4a
```

**Hands-off after login (optional)**

```bash
./meet install-watch
# anything you put in recordings/ is processed automatically
```

When a run finishes you’ll get a macOS notification, a Word file in `output/`, and the original media archived under `processed/`.

---

## Folders

```
recordings/   drop files here (or pass a path to transcribe)
output/       finished *_notes.docx files
processed/    originals + mp3 + transcript json, archived per run
logs/         pipeline.log
.env          your API key (never commit this)
```

Supported media: `.mov` `.mp4` `.m4a` `.mp3` `.wav` `.aac` `.mkv` `.webm`

---

## If something fails

| Symptom | Fix |
|---|---|
| `ffmpeg not found` | `brew install ffmpeg` then `./meet doctor` |
| `whisperkit-cli not found` | `brew install whisperkit-cli` then `./meet doctor` |
| `ANTHROPIC_API_KEY not set` | `./meet config` |
| `venv missing` | `./meet setup` |
| Claude rate-limit in the log | It retries on its own; wait and check `./meet logs` |
| File sits in `recordings/` forever | It waits until the file size is stable (still copying). Then `./meet status` |

Full traceback lives in `logs/pipeline.log`.

---

## Privacy

- Audio stays on your Mac for transcription (**whisperkit-cli**).
- The **text transcript** is sent to Anthropic (Claude) to write the notes.
- `.env` is gitignored. Don’t zip it, don’t Slack it, don’t commit it.
