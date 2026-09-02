#!/usr/bin/env python3
"""
Process one meeting recording end to end:
  video/audio -> mp3 -> WhisperKit transcript (with timestamps)
  -> Claude analysis (TL;DR + bookmarked insights + detailed notes)
  -> .docx report in output/ -> archive the source files.

Prefer the `./skip` CLI over calling this file directly:
  ./skip recap <path-to-recording>
"""
import json
import os
import shutil
import subprocess
import sys
import time
import traceback
from datetime import datetime, timedelta
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = PROJECT_DIR / "output"
PROCESSED_DIR = PROJECT_DIR / "processed"
LOGS_DIR = PROJECT_DIR / "logs"
ENV_FILE = PROJECT_DIR / ".env"

CLAUDE_MODEL = "claude-haiku-4-5-20251001"  # fast + cheap, plenty capable for meeting summarization
MAX_RETRIES = 5

ANALYSIS_SCHEMA_HINT = """
Return ONLY valid JSON (no markdown fences, no commentary) matching this shape:
{
  "title": "short descriptive meeting title",
  "tldr": ["bullet 1", "bullet 2", "..."],
  "bookmarks": [
    {"timestamp": "HH:MM:SS", "heading": "short label", "insight": "why this moment matters, explained in plain terms"}
  ],
  "detailed_notes": [
    {"heading": "topic heading", "content": "in-depth explanation / notes for this topic, several sentences"}
  ]
}
Include 5-15 bookmarks for the important/decision/action-item moments, spread across the whole meeting.
Include as many detailed_notes sections as needed to cover the meeting thoroughly.
"""


def log(msg):
    LOGS_DIR.mkdir(exist_ok=True)
    line = f"[{datetime.now().isoformat(timespec='seconds')}] {msg}"
    print(line, flush=True)
    with open(LOGS_DIR / "pipeline.log", "a") as f:
        f.write(line + "\n")


def load_env():
    """Minimal .env loader so we don't need python-dotenv as a dependency."""
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip())


def which_bin(name, env_var, fallbacks):
    """Find a binary on PATH, then common Homebrew locations."""
    from_env = os.environ.get(env_var)
    if from_env and Path(from_env).exists():
        return from_env
    found = shutil.which(name)
    if found:
        return found
    for candidate in fallbacks:
        if Path(candidate).exists():
            return candidate
    raise FileNotFoundError(
        f"{name} not found. Install it with Homebrew:\n"
        f"  brew install {name}\n"
        f"Then re-run: ./skip doctor"
    )


def ffmpeg_bin() -> str:
    return which_bin(
        "ffmpeg",
        "FFMPEG",
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"],
    )


def whisperkit_bin() -> str:
    return which_bin(
        "whisperkit-cli",
        "WHISPERKIT_CLI",
        ["/opt/homebrew/bin/whisperkit-cli", "/usr/local/bin/whisperkit-cli"],
    )


def notify(title, message):
    if sys.platform != "darwin":
        return
    safe_title = title.replace('"', "'")
    safe_message = message.replace('"', "'")
    subprocess.run(
        ["osascript", "-e", f'display notification "{safe_message}" with title "{safe_title}"'],
        check=False,
    )


def run(cmd, **kwargs):
    log(f"$ {' '.join(str(c) for c in cmd)}")
    subprocess.run(cmd, check=True, **kwargs)


def to_mp3(source: Path) -> Path:
    mp3_path = source.with_suffix(".mp3")
    if mp3_path.exists():
        return mp3_path
    run([
        ffmpeg_bin(), "-y", "-i", str(source),
        "-vn", "-acodec", "libmp3lame", "-ab", "192k", str(mp3_path),
    ])
    return mp3_path


def transcribe(mp3_path: Path) -> dict:
    json_path = mp3_path.with_suffix(".json")
    if not json_path.exists():
        run([
            whisperkit_bin(), "transcribe",
            "--audio-path", str(mp3_path),
            "--language", "en",
            "--report",
            "--report-path", str(mp3_path.parent),
        ])
    if not json_path.exists():
        raise FileNotFoundError(
            f"WhisperKit did not write {json_path.name}. "
            "Run `./skip doctor` and try again."
        )
    return json.loads(json_path.read_text())


def format_timestamp(seconds: float) -> str:
    return str(timedelta(seconds=int(seconds)))


def transcript_with_timestamps(whisper_json: dict) -> str:
    lines = []
    segments = whisper_json.get("segments") or whisper_json.get("transcription", {}).get("segments") or []
    for seg in segments:
        start = seg.get("start", seg.get("startTime", 0))
        text = (seg.get("text") or "").strip()
        if text:
            lines.append(f"[{format_timestamp(float(start))}] {text}")
    if not lines:
        text = (whisper_json.get("text") or "").strip()
        if text:
            return text
        raise ValueError("Transcript JSON had no segments or text")
    return "\n".join(lines)


def call_claude(transcript_text: str) -> dict:
    import anthropic

    client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from env
    prompt = (
        "You are analyzing a transcript of an internal company meeting. "
        "Produce a thorough analysis for someone who did not attend (include any follow-ups/action items mentioned during meeting)\n\n"
        f"{ANALYSIS_SCHEMA_HINT}\n\nTranscript (timestamped):\n{transcript_text}"
    )

    delay = 5
    last_err = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = client.messages.create(
                model=CLAUDE_MODEL,
                max_tokens=8000,
                messages=[{"role": "user", "content": prompt}],
            )
            raw = resp.content[0].text.strip()
            if raw.startswith("```"):
                raw = raw.strip("`")
                raw = raw.split("\n", 1)[1] if "\n" in raw else raw
            return json.loads(raw)
        except anthropic.RateLimitError as e:
            last_err = e
            log(f"Rate limited (attempt {attempt}/{MAX_RETRIES}), backing off {delay}s")
            time.sleep(delay)
            delay = min(delay * 2, 60)
        except anthropic.APIStatusError as e:
            last_err = e
            if e.status_code >= 500:
                log(f"Claude API {e.status_code} (attempt {attempt}/{MAX_RETRIES}), retrying in {delay}s")
                time.sleep(delay)
                delay = min(delay * 2, 60)
            else:
                raise
    raise RuntimeError(f"Claude API call failed after {MAX_RETRIES} attempts: {last_err}")


def build_docx(analysis: dict, source_name: str, meeting_date: str) -> Path:
    from docx import Document
    from docx.shared import Pt

    doc = Document()
    doc.add_heading(analysis.get("title", source_name), level=0)
    doc.add_paragraph(f"Source recording: {source_name}")
    doc.add_paragraph(f"Meeting date: {meeting_date}")

    doc.add_heading("TL;DR", level=1)
    for bullet in analysis.get("tldr", []):
        doc.add_paragraph(bullet, style="List Bullet")

    doc.add_heading("Key Bookmarks & Insights", level=1)
    for bm in analysis.get("bookmarks", []):
        p = doc.add_paragraph()
        run_ts = p.add_run(f"[{bm.get('timestamp', '?')}] ")
        run_ts.bold = True
        run_head = p.add_run(bm.get("heading", ""))
        run_head.bold = True
        run_head.font.size = Pt(12)
        doc.add_paragraph(bm.get("insight", ""))

    doc.add_heading("Detailed Notes", level=1)
    for section in analysis.get("detailed_notes", []):
        doc.add_heading(section.get("heading", ""), level=2)
        doc.add_paragraph(section.get("content", ""))

    OUTPUT_DIR.mkdir(exist_ok=True)
    out_path = OUTPUT_DIR / f"{Path(source_name).stem}_notes.docx"
    doc.save(out_path)
    return out_path


def archive(*paths: Path, dest_dir: Path):
    dest_dir.mkdir(parents=True, exist_ok=True)
    for p in paths:
        if p.exists():
            p.rename(dest_dir / p.name)


def main():
    if len(sys.argv) != 2:
        print("Usage: ./skip recap <recording-path>")
        print(f"   or: {sys.argv[0]} <recording-path>")
        sys.exit(1)

    load_env()
    source = Path(sys.argv[1]).resolve()
    if not source.exists():
        log(f"ERROR: source file not found: {source}")
        sys.exit(1)

    if not os.environ.get("ANTHROPIC_API_KEY"):
        log("ERROR: ANTHROPIC_API_KEY not set (add it to .env or your shell profile). Skipping analysis.")
        notify("Transcribe pipeline", "Missing ANTHROPIC_API_KEY - see logs/pipeline.log")
        sys.exit(1)

    try:
        log(f"Processing {source.name}")
        mp3_path = to_mp3(source)
        whisper_json = transcribe(mp3_path)
        transcript_text = transcript_with_timestamps(whisper_json)

        log("Calling Claude for analysis...")
        analysis = call_claude(transcript_text)

        meeting_date = datetime.fromtimestamp(source.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
        docx_path = build_docx(analysis, source.name, meeting_date)
        log(f"Wrote {docx_path}")

        archive_dir = PROCESSED_DIR / f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{source.stem}"
        json_path = mp3_path.with_suffix(".json")
        srt_path = mp3_path.with_suffix(".srt")
        archive(source, mp3_path, json_path, srt_path, dest_dir=archive_dir)
        log(f"Archived source files to {archive_dir}")
        notify("Transcribe pipeline", f"Done: {docx_path.name} is ready in output/")

    except Exception:
        log("ERROR: pipeline failed\n" + traceback.format_exc())
        notify("Transcribe pipeline FAILED", f"{source.name} - see logs/pipeline.log")
        sys.exit(1)


if __name__ == "__main__":
    main()
