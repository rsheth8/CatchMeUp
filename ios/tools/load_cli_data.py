#!/usr/bin/env python3
"""Load the local CatchMeUp CLI library into an installed iOS Simulator app.

This is a development helper. Real phones share a library with the Mac through
iCloud Drive — use `./catchup sync push` (and Settings ▸ Sync in the app).

The import is additive by default, creates a backup inside the Simulator
container, and never edits the CLI library. Audio is opt-in because a real
library can be several gigabytes while recaps and transcripts are small.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


BUNDLE_ID = "com.catchmeup.app"
UUID_NAMESPACE = uuid.UUID("95946771-cef0-45d7-88c8-73caa1222309")
TOKEN_PATTERN = re.compile(r"<\|[^|>]+\|>")
STAMP_PATTERN = re.compile(r"^\[(\d+):(\d+):(\d+)\]\s*(.*)$")


def run(*args: str, capture: bool = False, check: bool = True) -> str:
    result = subprocess.run(
        args,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else ""


def stable_uuid(key: str) -> str:
    return str(uuid.uuid5(UUID_NAMESPACE, key)).upper()


def iso_date(value: str | None, fallback: datetime | None = None) -> str:
    parsed: datetime | None = None
    if value:
        normalized = value.strip().replace("Z", "+00:00")
        try:
            parsed = datetime.fromisoformat(normalized)
        except ValueError:
            for pattern in ("%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S"):
                try:
                    parsed = datetime.strptime(value, pattern)
                    break
                except ValueError:
                    pass
    parsed = parsed or fallback or datetime.now().astimezone()
    if parsed.tzinfo is None:
        parsed = parsed.astimezone()
    return parsed.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def folder_date(folder: Path) -> datetime:
    match = re.match(r"(\d{8}_\d{6})", folder.name)
    if match:
        try:
            return datetime.strptime(match.group(1), "%Y%m%d_%H%M%S").astimezone()
        except ValueError:
            pass
    return datetime.fromtimestamp(folder.stat().st_mtime).astimezone()


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def clean_text(value: Any) -> str:
    text = TOKEN_PATTERN.sub("", str(value or ""))
    return re.sub(r"\s+", " ", text).strip()


def find_transcription_json(folder: Path, metadata: dict[str, Any]) -> Path | None:
    audio_name = metadata.get("audio")
    if audio_name:
        preferred = folder / Path(str(audio_name)).with_suffix(".json").name
        if preferred.is_file():
            return preferred
    return next((p for p in folder.glob("*.json") if p.name != "catchmeup.json"), None)


def segments_from_text(path: Path, recording_key: str) -> list[dict[str, Any]]:
    segments: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return segments
    for index, line in enumerate(lines):
        match = STAMP_PATTERN.match(line)
        if not match:
            continue
        hours, minutes, seconds, raw_text = match.groups()
        text = clean_text(raw_text)
        if not text:
            continue
        start = int(hours) * 3600 + int(minutes) * 60 + int(seconds)
        segments.append({
            "id": stable_uuid(f"{recording_key}:segment:{index}"),
            "start": float(start),
            "text": text,
        })
    return segments


def load_segments(folder: Path, metadata: dict[str, Any], recording_key: str) -> tuple[list[dict[str, Any]], float]:
    report_path = find_transcription_json(folder, metadata)
    report = read_json(report_path, {}) if report_path else {}
    raw_segments = report.get("segments") or report.get("transcription", {}).get("segments") or []
    segments: list[dict[str, Any]] = []
    max_end = 0.0

    for index, raw in enumerate(raw_segments):
        if not isinstance(raw, dict):
            continue
        text = clean_text(raw.get("text"))
        if not text:
            continue
        start = float(raw.get("start", raw.get("startTime", 0)) or 0)
        end = float(raw.get("end", raw.get("endTime", start)) or start)
        item: dict[str, Any] = {
            "id": stable_uuid(f"{recording_key}:segment:{index}"),
            "start": start,
            "text": text,
        }
        speaker = raw.get("speaker") or raw.get("speakerLabel") or raw.get("speaker_label")
        if speaker:
            item["speaker"] = str(speaker)
        segments.append(item)
        max_end = max(max_end, end)

    if not segments:
        segments = segments_from_text(folder / "transcript.txt", recording_key)
        if segments:
            max_end = segments[-1]["start"]

    timing_duration = (report.get("timings") or {}).get("inputAudioSeconds")
    try:
        duration = max(max_end, float(timing_duration or 0))
    except (TypeError, ValueError):
        duration = max_end
    return segments, duration


def normalize_object_list(value: Any, fields: tuple[str, ...]) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    for item in value or []:
        if isinstance(item, dict):
            result.append({field: str(item.get(field) or "") for field in fields})
        elif fields:
            result.append({fields[0]: str(item), **{field: "" for field in fields[1:]}})
    return result


def make_recap(metadata: dict[str, Any]) -> dict[str, Any]:
    analysis = metadata.get("analysis") or {}
    return {
        "title": analysis.get("title") or metadata.get("title"),
        "tldr": [str(item) for item in analysis.get("tldr") or []],
        "actionItems": [str(item) for item in analysis.get("action_items") or []],
        "speakers": normalize_object_list(analysis.get("speakers"), ("label", "name", "said")),
        "bookmarks": normalize_object_list(analysis.get("bookmarks"), ("timestamp", "heading", "insight")),
        "detailedNotes": normalize_object_list(analysis.get("detailed_notes"), ("heading", "content")),
        "terms": normalize_object_list(analysis.get("terms"), ("term", "definition")),
        "study": [str(item) for item in analysis.get("study") or []],
    }


def discover_brains(project_root: Path) -> tuple[list[dict[str, Any]], dict[str, str]]:
    brains: list[dict[str, Any]] = []
    ids: dict[str, str] = {}
    for path in sorted((project_root / "brains").glob("*/brain.json")):
        metadata = read_json(path, {})
        slug = str(metadata.get("slug") or path.parent.name)
        brain_id = stable_uuid(f"brain:{slug}")
        ids[slug] = brain_id
        created = iso_date(metadata.get("created"), folder_date(path.parent))
        brains.append({
            "id": brain_id,
            "name": str(metadata.get("name") or slug),
            "persona": str(metadata.get("persona") or ""),
            "mode": "meeting" if metadata.get("kind") == "meeting" else "lecture",
            "createdAt": created,
            "updatedAt": created,
            "deleted": False,
        })
    return brains, ids


def discover_record_paths(project_root: Path, selected_brain: str | None) -> list[Path]:
    paths = list((project_root / "processed").glob("*/catchmeup.json"))
    brain_pattern = f"{selected_brain}/recaps/*/catchmeup.json" if selected_brain else "*/recaps/*/catchmeup.json"
    paths.extend((project_root / "brains").glob(brain_pattern))
    return sorted(paths, key=lambda p: p.parent.name)


def matches_record(path: Path, query: str) -> bool:
    needle = query.casefold()
    metadata = read_json(path, {})
    candidates = [
        path.as_posix(),
        str(metadata.get("title") or ""),
        str(metadata.get("source") or ""),
        str((metadata.get("analysis") or {}).get("title") or ""),
    ]
    return any(needle in candidate.casefold() for candidate in candidates)


def convert_recording(
    record_path: Path,
    project_root: Path,
    brain_ids: dict[str, str],
    with_audio: bool,
    audio_dir: Path,
) -> dict[str, Any] | None:
    metadata = read_json(record_path, {})
    if not metadata or not isinstance(metadata.get("analysis"), dict):
        return None

    relative = record_path.relative_to(project_root).as_posix()
    recording_id = stable_uuid(f"recording:{relative}")
    folder = record_path.parent
    fallback_date = folder_date(folder)
    created_at = iso_date(metadata.get("recorded_at") or metadata.get("processed_at"), fallback_date)
    updated_at = iso_date(metadata.get("processed_at"), fallback_date)
    segments, duration = load_segments(folder, metadata, relative)
    audio_filename: str | None = None

    audio_name = metadata.get("audio")
    source_audio = folder / str(audio_name) if audio_name else None
    if with_audio and source_audio and source_audio.is_file():
        audio_filename = f"{recording_id}{source_audio.suffix.lower()}"
        destination = audio_dir / audio_filename
        if not destination.exists() or destination.stat().st_size != source_audio.stat().st_size:
            shutil.copy2(source_audio, destination)

    mode = "lecture" if metadata.get("mode") == "lecture" else "meeting"
    recap = make_recap(metadata)
    brain_slug = metadata.get("brain")
    title = recap.get("title") or metadata.get("title") or Path(str(metadata.get("source") or "Recap")).stem
    return {
        "id": recording_id,
        "title": str(title),
        "createdAt": created_at,
        "updatedAt": updated_at,
        "deleted": False,
        "mode": mode,
        "audioFilename": audio_filename,
        "duration": duration,
        "segments": segments,
        "recap": recap,
        "brainID": brain_ids.get(str(brain_slug)) if brain_slug else None,
        "completedActions": [],
    }


def merge_by_id(existing: list[dict[str, Any]], imported: list[dict[str, Any]]) -> list[dict[str, Any]]:
    merged = {str(item.get("id")): item for item in existing if item.get("id")}
    for item in imported:
        merged[str(item["id"])] = item
    return list(merged.values())


def atomic_json_write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        temporary = Path(handle.name)
    temporary.replace(path)


def simulator_data_container(device: str) -> Path:
    try:
        raw = run("xcrun", "simctl", "get_app_container", device, BUNDLE_ID, "data", capture=True)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or "").strip()
        raise SystemExit(
            "CatchMeUp is not installed on that Simulator. Build and run it once in Xcode first."
            + (f"\n{detail}" if detail else "")
        )
    return Path(raw)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="booted", help="Simulator UDID or 'booted' (default).")
    parser.add_argument("--brain", help="Import only one brain slug, such as mit-60002.")
    parser.add_argument("--match", help="Import recaps whose title, source, or folder contains this text.")
    parser.add_argument("--limit", type=int, help="Import only the newest N matching recaps.")
    parser.add_argument("--with-audio", action="store_true", help="Also copy archived audio for playback.")
    parser.add_argument("--replace", action="store_true", help="Replace Simulator records instead of merging.")
    parser.add_argument("--dry-run", action="store_true", help="Convert and report without changing the Simulator.")
    args = parser.parse_args()

    project_root = Path(__file__).resolve().parents[2]
    brains, brain_ids = discover_brains(project_root)
    paths = discover_record_paths(project_root, args.brain)
    if args.match:
        paths = [path for path in paths if matches_record(path, args.match)]
    if args.limit is not None:
        paths = paths[-max(args.limit, 0):]
    if not paths:
        raise SystemExit("No CLI recaps matched the requested import.")

    if args.dry_run:
        print(f"Found {len(paths)} recaps and {len(brains)} brains.")
        print("Audio would be included." if args.with_audio else "Audio would be skipped (use --with-audio to include it).")
        return 0

    container = simulator_data_container(args.device)
    data_dir = container / "Library" / "Application Support" / "CatchMeUp"
    audio_dir = data_dir / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)

    run("xcrun", "simctl", "terminate", args.device, BUNDLE_ID, check=False)

    backup_dir = data_dir / "import-backups" / datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_dir.mkdir(parents=True, exist_ok=True)
    for name in ("recordings.json", "brains.json"):
        source = data_dir / name
        if source.exists():
            shutil.copy2(source, backup_dir / name)

    converted: list[dict[str, Any]] = []
    for index, path in enumerate(paths, 1):
        item = convert_recording(path, project_root, brain_ids, args.with_audio, audio_dir)
        if item:
            converted.append(item)
        print(f"[{index:>2}/{len(paths)}] {path.parent.name}")

    recordings_file = data_dir / "recordings.json"
    brains_file = data_dir / "brains.json"
    existing_recordings = [] if args.replace else read_json(recordings_file, [])
    existing_brains = [] if args.replace else read_json(brains_file, [])
    atomic_json_write(recordings_file, merge_by_id(existing_recordings, converted))
    atomic_json_write(brains_file, merge_by_id(existing_brains, brains))

    run("xcrun", "simctl", "launch", args.device, BUNDLE_ID, check=False)
    audio_note = " with audio" if args.with_audio else " (notes and transcripts; audio skipped)"
    print(f"\nImported {len(converted)} recaps and {len(brains)} brains{audio_note}.")
    print(f"Backup: {backup_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
