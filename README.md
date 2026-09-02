# SkipTheMeet

**Missed the Zoom. Still got the notes.**

macOS CLI that turns a meeting recording into a Word doc — TL;DR, timestamped bookmarks, detailed notes, follow-ups.

Drop in a Zoom, Google Meet, or screen recording. SkipTheMeet does the rest:

```
recording  →  ffmpeg (mp3)  →  whisperkit-cli (on-device transcript)  →  Claude  →  output/*_notes.docx
```

Searchable as: **meeting notes**, **meeting recap**, **transcript to Word**, **WhisperKit**, **ffmpeg**, **macOS CLI**.

The command is `./skip`.

---

## Send this to someone

1. Share https://github.com/rsheth8/SkipTheMeet — **do not send your `.env`** (that’s your API key).
2. They need a Mac, [Homebrew](https://brew.sh), and an [Anthropic API key](https://console.anthropic.com/settings/keys).
3. `./skip doctor` tells them if anything is missing.

---

## Install (about 5 minutes)

```bash
git clone https://github.com/rsheth8/SkipTheMeet.git
cd SkipTheMeet
chmod +x skip watch_and_process.sh pipeline.py
./skip setup
```

`./skip setup` installs the two packages this project cannot run without (same as `brew bundle`):

```bash
brew install ffmpeg
brew install whisperkit-cli
```

| Package | What it does |
|---|---|
| **ffmpeg** | Converts `.mov` / `.mp4` / `.m4a` / … into an `.mp3` WhisperKit can read |
| **whisperkit-cli** | On-device transcription with timestamps (audio never leaves your Mac) |

It also creates a Python virtualenv, installs `anthropic` + `python-docx`, and asks for your Anthropic API key (saved in `.env`, gitignored).

```bash
./skip doctor
```

You want green checkmarks for **ffmpeg**, **whisperkit-cli**, the venv, and `ANTHROPIC_API_KEY`.

---

## Commands

Run `./skip` with no arguments anytime to reprint this list.

| Command | What it does |
|---|---|
| `./skip setup` | First-time install: ffmpeg, whisperkit-cli, Python, `.env` |
| `./skip doctor` | Check ffmpeg, whisperkit-cli, API key, folders |
| `./skip config` | Paste / update the Anthropic API key |
| `./skip recap FILE` | Process **one** recording now |
| `./skip FILE` | Same as `recap` (shortcut) |
| `./skip drop FILE` | Copy a file into `recordings/` |
| `./skip watch` | Watch `recordings/` and recap new files (Ctrl-C to stop) |
| `./skip status` | What’s waiting, latest notes, watcher on/off |
| `./skip list` | List Word docs in `output/` |
| `./skip logs` | Pipeline log (`./skip logs -f` to follow) |
| `./skip open` | Open `output/` in Finder |
| `./skip install-watch` | Background watcher via macOS launchd |
| `./skip uninstall-watch` | Remove the background watcher |

---

## Typical workflows

**One file, right now**

```bash
./skip recap ~/Desktop/standup.mov
./skip open          # notes are in output/
```

**Drop-box (leave it running)**

```bash
./skip watch
# in another window, or from Finder:
./skip drop ~/Downloads/zoom-call.m4a
```

**Hands-off after login (optional)**

```bash
./skip install-watch
# anything you put in recordings/ is recapped automatically
```

When a run finishes you get a macOS notification, a Word file in `output/`, and the original media archived under `processed/`.

---

## Folders

```
recordings/   drop files here (or pass a path to recap)
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
| `ffmpeg not found` | `brew install ffmpeg` then `./skip doctor` |
| `whisperkit-cli not found` | `brew install whisperkit-cli` then `./skip doctor` |
| `ANTHROPIC_API_KEY not set` | `./skip config` |
| `venv missing` | `./skip setup` |
| Claude rate-limit in the log | It retries on its own; wait and check `./skip logs` |
| File sits in `recordings/` forever | Size must be stable (still copying). Then `./skip status` |

Full traceback lives in `logs/pipeline.log`.

---

## Privacy

- Audio stays on your Mac for transcription (**whisperkit-cli**).
- The **text transcript** is sent to Anthropic (Claude) to write the notes.
- `.env` is gitignored. Don’t zip it, don’t Slack it, don’t commit it.
