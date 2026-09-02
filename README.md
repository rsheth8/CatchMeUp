# CatchMeUp

**Missed the Zoom. Missed lecture. Still got the notes.**

One macOS CLI for two lives:

| You | Drop in | You get |
|---|---|---|
| **Full-time / intern** | Zoom, Meet, standup, 1:1, client call | TL;DR, decisions, **action items**, timestamped bookmarks |
| **Student** | Recorded lecture, seminar, discussion section | What you missed, **terms**, lecture notes, **study / exam checklist** |

Same engine either way — only the recap style changes:

```
recording  →  ffmpeg (mp3)  →  whisperkit-cli (on-device transcript)  →  Claude  →  output/*_notes.docx
```

The command is `./catchup`.

---

## Send this to someone

1. Share the GitHub repo. **Do not send your `.env`** — that file has your API key.
2. They need a Mac, [Homebrew](https://brew.sh), and an [Anthropic API key](https://console.anthropic.com/settings/keys).
3. `./catchup doctor` tells them if anything is missing.

---

## Install (about 5 minutes)

```bash
git clone https://github.com/rsheth8/CatchMeUp.git
cd CatchMeUp
chmod +x catchup watch_and_process.sh pipeline.py
./catchup setup
```

`./catchup setup` installs the two packages this cannot run without:

```bash
brew install ffmpeg
brew install whisperkit-cli
```

| Package | What it does |
|---|---|
| **ffmpeg** | Converts `.mov` / `.mp4` / `.m4a` / … into an `.mp3` WhisperKit can read |
| **whisperkit-cli** | On-device transcription with timestamps (audio never leaves your Mac) |

Then pick a default style (you can always override per file):

```bash
./catchup mode meeting    # work
./catchup mode lecture    # school
./catchup doctor
```

---

## Commands

Run `./catchup` with no arguments anytime to reprint this list.

| Command | What it does |
|---|---|
| `./catchup setup` | Install ffmpeg, whisperkit-cli, Python, `.env` |
| `./catchup doctor` | Check ffmpeg, whisperkit-cli, API key, folders |
| `./catchup config` | Paste / update the Anthropic API key |
| `./catchup mode meeting\|lecture` | Set the default recap style |
| `./catchup meeting FILE` | Recap a **work** recording |
| `./catchup lecture FILE` | Recap a **class** recording |
| `./catchup drop FILE` | Copy a file into `recordings/` |
| `./catchup watch meeting` | Auto-recap new files as meetings |
| `./catchup watch lecture` | Auto-recap new files as lectures |
| `./catchup status` / `list` / `logs` / `open` | What’s waiting, notes, log, Finder |
| `./catchup install-watch meeting\|lecture` | Background watcher (launchd) |

---

## Typical workflows

**Work — one call, right now**

```bash
./catchup meeting ~/Desktop/standup.mov
./catchup open
```

**School — one lecture, right now**

```bash
./catchup lecture ~/Downloads/cs61a-week3.mp4
./catchup open
```

**Drop-box for the week** (leave it running)

```bash
./catchup watch lecture          # midterms week
./catchup drop ~/Downloads/week4-os.m4a
```

```bash
./catchup watch meeting          # a sprint of standups
./catchup drop ~/Downloads/zoom-sync.m4a
```

If the filename already says `lecture`, `class`, `week`, `zoom`, `standup`, `1-1`, … CatchMeUp can guess. Passing `meeting` or `lecture` always wins.

---

## What the Word doc looks like

**Meeting recap** (`*_meeting_notes.docx`)

- TL;DR
- Action items & follow-ups (owners / deadlines when they were said)
- Timestamped bookmarks
- Detailed notes

**Lecture recap** (`*_lecture_notes.docx`)

- What you missed
- Key moments (definitions, worked examples, “this will be on the exam”)
- Lecture notes by topic
- Terms & definitions
- Study / exam checklist

---

## Folders

```
recordings/   drop files here
output/       finished Word notes
processed/    originals + mp3 + transcript json, archived per run
logs/         pipeline.log
.env          your API key + default mode (never commit this)
```

Supported media: `.mov` `.mp4` `.m4a` `.mp3` `.wav` `.aac` `.mkv` `.webm`

---

## If something fails

| Symptom | Fix |
|---|---|
| `ffmpeg not found` | `brew install ffmpeg` then `./catchup doctor` |
| `whisperkit-cli not found` | `brew install whisperkit-cli` then `./catchup doctor` |
| `ANTHROPIC_API_KEY not set` | `./catchup config` |
| Notes feel like a meeting but it was class | `./catchup lecture FILE` (or `./catchup mode lecture`) |
| Notes feel like a lecture but it was work | `./catchup meeting FILE` |
| File sits in `recordings/` | Size must be stable (still copying). Then `./catchup status` |

Full traceback lives in `logs/pipeline.log`.

---

## Privacy

- Audio stays on your Mac for transcription (**whisperkit-cli**).
- The **text transcript** is sent to Anthropic (Claude) to write the notes.
- `.env` is gitignored. Don’t zip it, don’t Slack it, don’t commit it.
