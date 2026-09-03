# CatchMeUp

**Missed the Zoom. Missed lecture. Still got the notes.**

One macOS CLI for two lives:

| You | Drop in | You get |
|---|---|---|
| **Full-time / intern** | Zoom, Meet, standup, 1:1, client call | TL;DR, decisions, **action items**, timestamped bookmarks |
| **Student** | Recorded lecture, seminar, discussion section | What you missed, **terms**, lecture notes, **study / exam checklist** |

Same engine either way — only the recap style changes:

```
recording  →  ffmpeg (mp3)  →  whisperkit-cli (on-device transcript)  →  your LLM  →  output/*_notes.docx
```

Bring **your own API key** from Anthropic, OpenAI, Google Gemini, Groq, OpenRouter, DeepSeek, Mistral, Together, xAI, local Ollama, or any OpenAI-compatible endpoint.

The command is `./catchup`.

---

## Send this to someone

1. Share the GitHub repo. **Do not send your `.env`** — that file has your API key.
2. They need a Mac and [Homebrew](https://brew.sh). For notes they can paste a key (`./catchup config anthropic`) **or** stay local with no key: install [Ollama](https://ollama.com), then `./catchup config ollama` and `ollama pull qwen3.6:35b`.
3. `./catchup doctor` tells them if anything is missing.

---

## Install (about 5 minutes)

```bash
git clone https://github.com/rsheth8/CatchMeUp.git
cd CatchMeUp
chmod +x catchup watch_and_process.sh
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

Then pick how notes get written, and a recap style:

```bash
./catchup providers
./catchup config anthropic       # paste a Claude / OpenAI / Gemini / … key
# or, no cloud key:
#   ./catchup config ollama
#   ollama pull qwen3.6:35b
./catchup mode meeting           # work
./catchup mode lecture           # school
./catchup doctor
```

---

## Commands

Run `./catchup` or `./catchup help` anytime for the full command list.  
`./catchup help exam` (or `rec`, `brain`, `clip`, …) prints a short page for that command.

The table below is the everyday set. New commands land in `./catchup help` first.

| Command | What it does |
|---|---|
| `./catchup setup` | Install ffmpeg, whisperkit-cli, Python, `.env` |
| `./catchup doctor` | Check ffmpeg, whisperkit-cli, API key, folders |
| `./catchup config` | Pick a company and paste its API key |
| `./catchup config openai` | Same, skipping the menu (any id from `providers`) |
| `./catchup providers` | List Anthropic, OpenAI, Gemini, Groq, OpenRouter, … |
| `./catchup model MODEL` | Override the default model for that company |
| `./catchup mode meeting\|lecture` | Set the default recap style |
| `./catchup meeting FILE` | Recap a **work** recording |
| `./catchup lecture FILE` | Recap a **class** recording |
| `./catchup drop FILE` | Copy a file into `recordings/` |
| `./catchup watch meeting` | Auto-recap new files as meetings |
| `./catchup watch lecture` | Auto-recap new files as lectures |
| `./catchup brain new NAME --lecture\|--meeting` | Create a specialist agent folder |
| `./catchup into NAME FILE` | Recap a recording **into that brain** |
| `./catchup ask NAME QUESTION` | RAG over that brain only |
| `./catchup think NAME TASK` | Deep multi-pass analysis (cortex + critique) |
| `./catchup exam NAME` | Practice exam from that brain |
| `./catchup diff NAME` | What changed since the previous recap |
| `./catchup clip NAME WORDS` | Play the audio of a concept |
| `./catchup rec` | Record from the mic, then recap |
| `./catchup cortex NAME` | Show that brain's concept graph |
| `./catchup mcp install` | Expose brains to Cursor via MCP |
| `./catchup search WORDS` | Find a topic across meetings + lectures |
| `./catchup ask QUESTION` | Ask your library |
| `./catchup quiz` | Flashcards from lecture terms |
| `./catchup todos` | Action items from all meetings |
| `./catchup moments` | Timestamps from the latest recap |
| `./catchup play HH:MM:SS` | Play 25s of that moment |
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

## After the recap (the unique part)

Generic RAG over “all my PDFs” is everywhere. CatchMeUp’s wedge is **named specialist agents**, each bound to a folder of recaps that *you actually missed*:

| Brain folder | Agent | You ask |
|---|---|---|
| `brains/cs61a/` | Course TA | “Explain environment diagrams from week 3” |
| `brains/acme-client/` | Account memory | “What did we promise them about billing?” |
| `brains/standups/` | Team historian | “Who owns the auth migration?” |

Each brain has a **persona** (how it should think), an **inbox** (drop recordings), and a **recap corpus** the RAG search cannot leave. Cursor talks to the same agents over **MCP**.

```bash
./catchup brain new cs61a --lecture
./catchup brain persona cs61a You are a CS 61A TA. Prefer SICP vocabulary.
./catchup into cs61a ~/Downloads/week3.mp4
./catchup into mit-60001 MIT-6.0001/    # whole OCW folder; originals stay put
./catchup ask cs61a what is a binary heap?
./catchup think cs61a explain mutexes for the midterm
./catchup exam cs61a
./catchup clip cs61a mutex
./catchup rec lecture          # mic → recap (Ctrl-C to stop)
./catchup diff cs61a
./catchup cortex cs61a
./catchup watch cs61a          # anything dropped in brains/cs61a/inbox/

./catchup mcp install          # Cursor: “ask the cs61a brain about heaps”
```

Otter and Fireflies summarize one call in the cloud. CatchMeUp keeps a **local library** of everything you missed, then you query a *specific* brain from the terminal or from Cursor.

Each recap also writes Markdown and Word into `output/`. Read concepts **in CatchMeUp** — you do not need Obsidian or another notes app:

```bash
./catchup notes cs61a
./catchup walk cs61a mutex      # hop around the graph in the terminal
./catchup graph cs61a           # clickable graph CatchMeUp generates (opens in your browser)
```

Obsidian is optional: `./catchup obsidian cs61a` dumps a vault folder if you already live there.

**Deep analysis (`./catchup think`)** is four passes, not one chatbot call: decompose the task → fire related concepts in that brain’s cortex (a concept graph that grows as recaps co-occur) → gather cited claims → critique gaps → synthesize. The LLM is the inner voice; the graph is the memory. Inspect it with `./catchup cortex cs61a`.

Meetings get **speaker labels** (WhisperKit diarization) so action items can say `Speaker 1 / Jordan` instead of “someone.” Lectures skip diarization unless you set `CATCHMEUP_DIARIZE=1`.

After a few recaps in a brain:

```bash
./catchup exam cs61a --print     # practice test from terms + study list
./catchup diff cs61a             # what appeared / vanished since last time
./catchup clip cs61a mutex       # jump 25s into the archived audio
./catchup rec lecture            # record from the mic, Ctrl-C, auto-recap
./catchup rec --devices
```

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
./catchup         CLI
catchmeup/        Python package (pipeline, brains, cortex, MCP, …)
recordings/       drop files here
output/           finished Word notes
processed/        originals + mp3 + transcript json, archived per run
brains/           specialist agents (gitignored except README)
logs/             pipeline.log
.env              your API key + default mode (never commit this)
```

Recaps and recordings live under `CATCHMEUP_HOME` (the repo root unless you set it). Code stays in `catchmeup/`.

Supported media: `.mov` `.mp4` `.m4a` `.mp3` `.wav` `.aac` `.mkv` `.webm`

---

## If something fails

| Symptom | Fix |
|---|---|
| `ffmpeg not found` | `brew install ffmpeg` then `./catchup doctor` |
| `whisperkit-cli not found` | `brew install whisperkit-cli` then `./catchup doctor` |
| `ANTHROPIC_API_KEY not set` / no API key | `./catchup config anthropic` (paste a key) or `./catchup config ollama` |
| Notes feel like a meeting but it was class | `./catchup lecture FILE` (or `./catchup mode lecture`) |
| Notes feel like a lecture but it was work | `./catchup meeting FILE` |
| File sits in `recordings/` | Size must be stable (still copying). Then `./catchup status` |

Full traceback lives in `logs/pipeline.log`.

---

## Privacy

- Audio stays on your Mac for transcription (**whisperkit-cli**).
- The **text transcript** is sent to whichever LLM you configured (Anthropic, OpenAI, Gemini, …) to write the notes.
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
| `ollama` | Ollama on your machine (no cloud key). Default model: `qwen3.6:35b` |
| `custom` | Any OpenAI-compatible base URL |

`custom` example:

```bash
./catchup config custom https://your-gateway.example/v1
```

---

## Tests

Recaps, brains, and cortex data honor `CATCHMEUP_HOME`, so the suite uses a temp directory and never writes into your real `brains/` or `processed/`.

```bash
python3 -m unittest discover -s tests -v
```

That covers folder brains, isolation, cortex ingest/activate/think (LLM mocked), markdown + library search, the clickable graph, MCP tools, and the CLI (`brain new/list/show`, `cortex`, `help`). It does **not** call ffmpeg, whisperkit-cli, or a live LLM — those need a real recording and `./catchup doctor` to go green.
