"""One library across the Mac CLI and the iOS app.

The iOS app already keeps its library in its iCloud Drive ubiquity container:
`recordings.json`, `brains.json` and an `audio/` folder. On a Mac that same
container is an ordinary directory under `~/Library/Mobile Documents/`, so the
CLI can read and write it directly and Apple moves the bytes. No server, no
account beyond iCloud, and audio still never reaches a third party.

    push   CLI recaps  ->  shared folder  ->  iPhone
    pull   iPhone recordings  ->  shared folder  ->  CLI brain folders

Both directions merge by id keeping whichever side was updated most recently,
which is the same rule `LibraryStore.mergeFromDisk` applies on the phone. Set
CATCHMEUP_SYNC_DIR to point at any other synced folder (Dropbox, Syncthing, a
USB stick) instead of iCloud.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from .paths import RECORD_NAME, home

CONTAINER_ID = "iCloud.com.catchmeup.app"
RECORDINGS_NAME = "recordings.json"
BRAINS_NAME = "brains.json"
AUDIO_DIR_NAME = "audio"

# Shared with ios/tools/load_cli_data.py — changing it renumbers every
# recording and the phone would see the whole library as new.
UUID_NAMESPACE = uuid.UUID("95946771-cef0-45d7-88c8-73caa1222309")

TOKEN_PATTERN = re.compile(r"<\|[^|>]+\|>")
STAMP_PATTERN = re.compile(r"^\[(\d+):(\d+):(\d+)\]\s*(.*)$")

# Things only the phone can know. A newer recap from the CLI still must not
# untick an action item or unpin audio the user chose to keep.
USER_STATE_FIELDS = (
    "completedActions",
    "keepAudioDownloaded",
    "lastPlayedAt",
    "audioRemoved",
    "cloudAssetID",
)


class SyncUnavailable(RuntimeError):
    """The shared folder isn't reachable yet, with instructions to fix it."""


# --------------------------------------------------------------- where it lives


def default_container() -> Path:
    """`~/Library/Mobile Documents/iCloud~com~catchmeup~app/Documents`."""
    folder = CONTAINER_ID.replace(".", "~")
    return Path.home() / "Library" / "Mobile Documents" / folder / "Documents"


def sync_dir(explicit: str | Path | None = None, create: bool = False) -> Path:
    """The folder both surfaces read and write.

    Order: an explicit path, then CATCHMEUP_SYNC_DIR, then the iCloud container.
    """
    override = explicit or os.environ.get("CATCHMEUP_SYNC_DIR")
    if override:
        path = Path(override).expanduser()
        if create:
            path.mkdir(parents=True, exist_ok=True)
        if not path.is_dir():
            raise SyncUnavailable(f"CATCHMEUP_SYNC_DIR points at {path}, which does not exist.")
        return path

    path = default_container()
    if path.is_dir():
        return path
    if create and path.parent.is_dir():
        path.mkdir(parents=True, exist_ok=True)
        return path
    raise SyncUnavailable(
        "iCloud hasn't created the CatchMeUp folder on this Mac yet.\n"
        "  1. On the iPhone, open CatchMeUp ▸ Settings ▸ Sync and turn it on.\n"
        "  2. Make sure this Mac is signed into the same Apple Account with "
        "iCloud Drive enabled.\n"
        "Or point somewhere else entirely:\n"
        "  CATCHMEUP_SYNC_DIR=~/Dropbox/CatchMeUp ./catchup sync push"
    )


def audio_dir(root: Path) -> Path:
    return root / AUDIO_DIR_NAME


# ------------------------------------------------------------------- utilities


def stable_uuid(key: str) -> str:
    return str(uuid.uuid5(UUID_NAMESPACE, key)).upper()


def iso_date(value: str | None, fallback: datetime | None = None) -> str:
    """An ISO-8601 instant Swift's `.iso8601` decoder accepts."""
    parsed: datetime | None = None
    if value:
        normalized = str(value).strip().replace("Z", "+00:00")
        try:
            parsed = datetime.fromisoformat(normalized)
        except ValueError:
            for pattern in ("%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S"):
                try:
                    parsed = datetime.strptime(str(value), pattern)
                    break
                except ValueError:
                    pass
    parsed = parsed or fallback or datetime.now().astimezone()
    if parsed.tzinfo is None:
        parsed = parsed.astimezone()
    return parsed.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_iso(value: Any) -> datetime:
    """Sort key for merges. Anything unreadable sorts oldest so it never wins."""
    try:
        text = str(value).strip().replace("Z", "+00:00")
        parsed = datetime.fromisoformat(text)
    except (TypeError, ValueError):
        return datetime.min.replace(tzinfo=timezone.utc)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def local_stamp(value: Any) -> str:
    """ISO instant -> the `%Y-%m-%d %H:%M` the CLI records use."""
    moment = parse_iso(value)
    if moment == datetime.min.replace(tzinfo=timezone.utc):
        moment = datetime.now(timezone.utc)
    return moment.astimezone().strftime("%Y-%m-%d %H:%M")


def clean_text(value: Any) -> str:
    text = TOKEN_PATTERN.sub("", str(value or ""))
    return re.sub(r"\s+", " ", text).strip()


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def atomic_json_write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    # iCloud Drive treats rename-over as delete+create and can spawn
    # "recordings 2.json" conflict copies. Overwrite in place there.
    if "Mobile Documents" in path.parts:
        path.write_text(payload, encoding="utf-8")
        return
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        handle.write(payload)
        temporary = Path(handle.name)
    temporary.replace(path)


def normalize_id(value: Any) -> str:
    """Swift UUID encoding is lowercase; we always merge on the uppercase form."""
    return str(value or "").upper()


def stamp_ios_id(path: Path, ios_id: str) -> None:
    """Remember the phone's id on a CLI recap so a later move doesn't clone it."""
    data = read_json(path, {})
    if not isinstance(data, dict):
        return
    if normalize_id(data.get("ios_id")) == ios_id:
        return
    data["ios_id"] = ios_id
    path.write_text(json.dumps(data, indent=2) + "\n")


def folder_date(folder: Path) -> datetime:
    match = re.match(r"(\d{8}_\d{6})", folder.name)
    if match:
        try:
            return datetime.strptime(match.group(1), "%Y%m%d_%H%M%S").astimezone()
        except ValueError:
            pass
    try:
        return datetime.fromtimestamp(folder.stat().st_mtime).astimezone()
    except OSError:
        return datetime.now().astimezone()


# ----------------------------------------------------------- CLI record -> iOS


def find_transcription_json(folder: Path, metadata: dict[str, Any]) -> Path | None:
    audio_name = metadata.get("audio")
    if audio_name:
        preferred = folder / Path(str(audio_name)).with_suffix(".json").name
        if preferred.is_file():
            return preferred
    return next((p for p in folder.glob("*.json") if p.name != RECORD_NAME), None)


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


def load_segments(
    folder: Path, metadata: dict[str, Any], recording_key: str
) -> tuple[list[dict[str, Any]], float]:
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
    """The CLI's snake_case `analysis` in the camelCase shape `Recap` decodes."""
    analysis = metadata.get("analysis") or {}
    return {
        "title": analysis.get("title") or metadata.get("title"),
        "tldr": [str(item) for item in analysis.get("tldr") or []],
        "actionItems": [str(item) for item in analysis.get("action_items") or []],
        "speakers": normalize_object_list(analysis.get("speakers"), ("label", "name", "said")),
        "bookmarks": normalize_object_list(
            analysis.get("bookmarks"), ("timestamp", "heading", "insight")
        ),
        "detailedNotes": normalize_object_list(
            analysis.get("detailed_notes"), ("heading", "content")
        ),
        "terms": normalize_object_list(analysis.get("terms"), ("term", "definition")),
        "study": [str(item) for item in analysis.get("study") or []],
    }


def discover_brains(root: Path | None = None) -> tuple[list[dict[str, Any]], dict[str, str]]:
    """Every CLI brain in the shape `brains.json` expects, plus slug -> id."""
    base = Path(root) if root else home()
    brains: list[dict[str, Any]] = []
    ids: dict[str, str] = {}
    for path in sorted((base / "brains").glob("*/brain.json")):
        metadata = read_json(path, {})
        slug = str(metadata.get("slug") or path.parent.name)
        # A brain first created on the phone keeps the phone's id, or pushing it
        # back would land as a second brain with the same name.
        brain_id = str(metadata.get("ios_id") or "").upper() or stable_uuid(f"brain:{slug}")
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


def discover_record_paths(
    root: Path | None = None, selected_brain: str | None = None
) -> list[Path]:
    base = Path(root) if root else home()
    paths = list((base / "processed").glob(f"*/{RECORD_NAME}"))
    pattern = (
        f"{selected_brain}/recaps/*/{RECORD_NAME}"
        if selected_brain
        else f"*/recaps/*/{RECORD_NAME}"
    )
    paths.extend((base / "brains").glob(pattern))
    return sorted(paths, key=lambda p: p.parent.name)


def convert_recording(
    record_path: Path,
    project_root: Path,
    brain_ids: dict[str, str],
    with_audio: bool = False,
    audio_target: Path | None = None,
) -> dict[str, Any] | None:
    """One `catchmeup.json` as an iOS `Recording`, or None if it has no notes."""
    metadata = read_json(record_path, {})
    if not metadata or not isinstance(metadata.get("analysis"), dict):
        return None

    try:
        relative = record_path.relative_to(project_root).as_posix()
    except ValueError:
        relative = record_path.as_posix()

    # A recap that came from the phone keeps the phone's id, so a round trip
    # updates that recording instead of cloning it.
    recording_id = str(metadata.get("ios_id") or "").upper() or stable_uuid(
        f"recording:{relative}"
    )
    folder = record_path.parent
    fallback_date = folder_date(folder)
    created_at = iso_date(
        metadata.get("recorded_at") or metadata.get("processed_at"), fallback_date
    )
    updated_at = iso_date(metadata.get("processed_at"), fallback_date)
    segments, duration = load_segments(folder, metadata, relative)

    audio_filename: str | None = None
    audio_name = metadata.get("audio")
    source_audio = folder / str(audio_name) if audio_name else None
    if with_audio and audio_target and source_audio and source_audio.is_file():
        audio_filename = f"{recording_id}{source_audio.suffix.lower()}"
        audio_target.mkdir(parents=True, exist_ok=True)
        destination = audio_target / audio_filename
        if (
            not destination.exists()
            or destination.stat().st_size != source_audio.stat().st_size
        ):
            shutil.copy2(source_audio, destination)

    recap = make_recap(metadata)
    brain_slug = metadata.get("brain")
    title = (
        recap.get("title")
        or metadata.get("title")
        or Path(str(metadata.get("source") or "Recap")).stem
    )
    return {
        "id": recording_id,
        "title": str(title),
        "createdAt": created_at,
        "updatedAt": updated_at,
        "deleted": False,
        "mode": "lecture" if metadata.get("mode") == "lecture" else "meeting",
        "audioFilename": audio_filename,
        "duration": duration,
        "segments": segments,
        "recap": recap,
        "brainID": brain_ids.get(str(brain_slug)) if brain_slug else None,
        "completedActions": [],
    }


# ----------------------------------------------------------------- the merge


def merge_by_id(
    existing: list[dict[str, Any]],
    incoming: list[dict[str, Any]],
    carry_user_state: bool = False,
) -> list[dict[str, Any]]:
    """Union by id, newest `updatedAt` wins, ties go to what was already there.

    Ties favouring `existing` is what makes repeated pushes idempotent: a recap
    the CLI has not re-run keeps whatever the phone did to it. With
    `carry_user_state` the phone's ticked actions and audio pins survive even
    when the incoming copy is newer.
    """
    merged: dict[str, dict[str, Any]] = {}
    for item in existing:
        key = normalize_id(item.get("id"))
        if key:
            held = dict(item)
            held["id"] = key
            merged[key] = held

    for item in incoming:
        key = normalize_id(item.get("id"))
        if not key:
            continue
        item = dict(item)
        item["id"] = key
        current = merged.get(key)
        if current is None:
            merged[key] = item
            continue
        if parse_iso(item.get("updatedAt")) <= parse_iso(current.get("updatedAt")):
            continue
        winner = dict(item)
        if carry_user_state:
            for field in USER_STATE_FIELDS:
                if field in current:
                    winner[field] = current[field]
            # Audio the phone holds shouldn't be dropped just because this push
            # skipped audio.
            if not winner.get("audioFilename") and current.get("audioFilename"):
                winner["audioFilename"] = current["audioFilename"]
        merged[key] = winner

    return sorted(merged.values(), key=lambda r: str(r.get("createdAt") or ""), reverse=True)


# ----------------------------------------------------------- iOS -> CLI record


def transcript_text(segments: Iterable[dict[str, Any]]) -> str:
    """`[HH:MM:SS] text` lines — what `brains._chunks` retrieves over."""
    lines = []
    for seg in segments or []:
        if not isinstance(seg, dict):
            continue
        text = clean_text(seg.get("text"))
        if not text:
            continue
        total = int(float(seg.get("start") or 0))
        stamp = f"{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"
        speaker = str(seg.get("speaker") or "").strip()
        lines.append(f"[{stamp}] {speaker}: {text}" if speaker else f"[{stamp}] {text}")
    return "\n".join(lines)


def analysis_from_recap(recap: dict[str, Any]) -> dict[str, Any]:
    """The inverse of `make_recap` — camelCase back to the CLI's `analysis`."""
    recap = recap or {}
    return {
        "title": recap.get("title") or "",
        "tldr": [str(x) for x in recap.get("tldr") or []],
        "action_items": [str(x) for x in recap.get("actionItems") or []],
        "speakers": normalize_object_list(recap.get("speakers"), ("label", "name", "said")),
        "bookmarks": normalize_object_list(
            recap.get("bookmarks"), ("timestamp", "heading", "insight")
        ),
        "detailed_notes": normalize_object_list(
            recap.get("detailedNotes"), ("heading", "content")
        ),
        "terms": normalize_object_list(recap.get("terms"), ("term", "definition")),
        "study": [str(x) for x in recap.get("study") or []],
    }


def cli_record_from_recording(
    recording: dict[str, Any], brain_slug: str | None
) -> dict[str, Any]:
    title = str(recording.get("title") or "Recording")
    return {
        "version": 1,
        "mode": "lecture" if recording.get("mode") == "lecture" else "meeting",
        "brain": brain_slug,
        "title": title,
        "source": f"{title}.m4a",
        "recorded_at": local_stamp(recording.get("createdAt")),
        "processed_at": local_stamp(recording.get("updatedAt")),
        "provider": "ios",
        "analysis": analysis_from_recap(recording.get("recap") or {}),
        "ios_id": normalize_id(recording.get("id")),
        "ios_updated_at": iso_date(recording.get("updatedAt")),
    }


def existing_ios_ids(slug: str) -> dict[str, Path]:
    """Recaps already pulled into this brain, by the phone's recording id."""
    from . import brains as brains_mod

    found: dict[str, Path] = {}
    for record in brains_mod.iter_brain_records(slug):
        ios_id = normalize_id(record.get("ios_id"))
        if ios_id:
            found[ios_id] = Path(record["_path"])
    return found


def existing_processed_ios_ids() -> dict[str, Path]:
    """Unfiled recaps in processed/, keyed by the phone's recording id."""
    from .paths import RECORD_NAME, processed_root

    found: dict[str, Path] = {}
    root = processed_root()
    if not root.is_dir():
        return found
    for rec_path in root.glob(f"*/{RECORD_NAME}"):
        ios_id = normalize_id(read_json(rec_path, {}).get("ios_id"))
        if ios_id:
            found[ios_id] = rec_path
    return found


def write_cli_recap(
    folder_out: Path, record: dict[str, Any], recording: dict[str, Any], with_audio: bool, shared: Path
) -> None:
    """One phone recording as a CLI recap folder (brain or processed/)."""
    from .paths import RECORD_NAME

    folder_out.mkdir(parents=True, exist_ok=True)
    text = transcript_text(recording.get("segments") or [])
    if text:
        (folder_out / "transcript.txt").write_text(text)
    name = recording.get("audioFilename")
    if with_audio and name:
        source_audio = audio_dir(shared) / str(name)
        if source_audio.is_file():
            destination = folder_out / f"{Path(str(name)).stem}{source_audio.suffix}"
            shutil.copy2(source_audio, destination)
            record["audio"] = destination.name
    (folder_out / RECORD_NAME).write_text(json.dumps(record, indent=2) + "\n")


# ------------------------------------------------------------------- reporting


class Report(dict):
    """Counts a caller can print however it likes."""

    def __getattr__(self, name: str) -> Any:
        try:
            return self[name]
        except KeyError as error:
            raise AttributeError(name) from error


# ----------------------------------------------------------------------- push


def push(
    target: str | Path | None = None,
    brain: str | None = None,
    with_audio: bool = False,
    dry_run: bool = False,
) -> Report:
    """CLI library -> shared folder, without clobbering anything the phone did."""
    root = home()
    folder = sync_dir(target, create=True)
    brain_payloads, brain_ids = discover_brains(root)
    paths = discover_record_paths(root, brain)
    if brain:
        brain_payloads = [b for b in brain_payloads if b["id"] == brain_ids.get(brain)]

    converted: list[dict[str, Any]] = []
    skipped = 0
    for path in paths:
        item = convert_recording(
            path,
            root,
            brain_ids,
            with_audio=with_audio and not dry_run,
            audio_target=audio_dir(folder),
        )
        if item:
            converted.append(item)
            if not dry_run:
                stamp_ios_id(path, item["id"])
        else:
            skipped += 1

    if not dry_run:
        from . import brains as brains_mod

        for slug, brain_id in brain_ids.items():
            if not brains_mod.exists(slug):
                continue
            meta = brains_mod.load_brain(slug)
            if normalize_id(meta.get("ios_id")) != brain_id:
                meta["ios_id"] = brain_id
                brains_mod.save_brain(meta)

    existing_recordings = read_json(folder / RECORDINGS_NAME, [])
    existing_brains = read_json(folder / BRAINS_NAME, [])
    merged_recordings = merge_by_id(existing_recordings, converted, carry_user_state=True)
    merged_brains = merge_by_id(existing_brains, brain_payloads)

    added = len(merged_recordings) - len(existing_recordings)
    if not dry_run:
        atomic_json_write(folder / RECORDINGS_NAME, merged_recordings)
        atomic_json_write(folder / BRAINS_NAME, merged_brains)

    return Report(
        folder=str(folder),
        converted=len(converted),
        skipped=skipped,
        added=max(0, added),
        total=len(merged_recordings),
        brains=len(merged_brains),
        with_audio=with_audio,
        dry_run=dry_run,
    )


# ----------------------------------------------------------------------- pull


def pull(
    source: str | Path | None = None,
    brain: str | None = None,
    with_audio: bool = True,
    dry_run: bool = False,
) -> Report:
    """Phone recordings -> CLI brain folders, so cortex and exam can see them."""
    from . import brains as brains_mod

    folder = sync_dir(source)
    recordings = read_json(folder / RECORDINGS_NAME, [])
    remote_brains = read_json(folder / BRAINS_NAME, [])
    if not isinstance(recordings, list):
        raise SyncUnavailable(f"{folder / RECORDINGS_NAME} is not a list of recordings.")

    # brain id -> CLI slug, for both brains the CLI made and brains born on iOS.
    _, local_ids = discover_brains(home())
    slug_by_id = {normalize_id(bid): slug for slug, bid in local_ids.items()}
    name_by_id = {
        normalize_id(b.get("id")): str(b.get("name") or "")
        for b in remote_brains
        if isinstance(b, dict) and not b.get("deleted")
    }

    imported: list[str] = []
    updated: list[str] = []
    unfiled = 0
    touched_slugs: set[str] = set()
    # One scan per brain rather than one per recording.
    seen_by_slug: dict[str, dict[str, Path]] = {}
    seen_processed = existing_processed_ios_ids()

    for recording in recordings:
        if not isinstance(recording, dict) or recording.get("deleted"):
            continue
        if not recording.get("recap"):
            continue  # still processing, or failed on the phone

        brain_id = normalize_id(recording.get("brainID"))
        slug = slug_by_id.get(brain_id)
        if not slug and brain_id and brain_id in name_by_id:
            # Born on the phone: make the matching CLI brain once, and record
            # the phone's id on it so the pair stays one brain forever after.
            slug = brains_mod.slugify(name_by_id[brain_id])
            if not dry_run:
                remote = next(
                    (
                        b
                        for b in remote_brains
                        if normalize_id(b.get("id")) == brain_id
                    ),
                    {},
                )
                if not brains_mod.exists(slug):
                    brains_mod.create_brain(
                        name_by_id[brain_id],
                        kind="meeting" if remote.get("mode") == "meeting" else "lecture",
                        persona=str(remote.get("persona") or "") or None,
                    )
                meta = brains_mod.load_brain(slug)
                if normalize_id(meta.get("ios_id")) != brain_id:
                    meta["ios_id"] = brain_id
                    brains_mod.save_brain(meta)
            slug_by_id[brain_id] = slug

        ios_id = normalize_id(recording.get("id"))
        record = cli_record_from_recording(recording, slug)
        title = record["title"]

        if not slug:
            if brain:
                continue
            already = seen_processed.get(ios_id)
            if already is not None:
                current = read_json(already, {})
                if parse_iso(record["ios_updated_at"]) <= parse_iso(
                    current.get("ios_updated_at")
                ):
                    continue
                if not dry_run:
                    merged = {**current, **record}
                    already.write_text(json.dumps(merged, indent=2) + "\n")
                    text = transcript_text(recording.get("segments") or [])
                    if text:
                        (already.parent / "transcript.txt").write_text(text)
                updated.append(title)
                unfiled += 1
                continue
            if dry_run:
                imported.append(title)
                unfiled += 1
                continue
            folder_out = brains_mod.unique_stamp_dir(
                brains_mod.processed_root(), Path(title).name
            )
            write_cli_recap(folder_out, record, recording, with_audio, folder)
            seen_processed[ios_id] = folder_out / RECORD_NAME
            imported.append(title)
            unfiled += 1
            continue

        if brain and slug != brain:
            continue
        if slug not in seen_by_slug:
            seen_by_slug[slug] = existing_ios_ids(slug) if brains_mod.exists(slug) else {}
        already = seen_by_slug[slug].get(ios_id)

        if already is not None:
            # Only rewrite when the phone actually moved on.
            current = read_json(already, {})
            if parse_iso(record["ios_updated_at"]) <= parse_iso(
                current.get("ios_updated_at")
            ):
                continue
            record["source"] = current.get("source") or record["source"]
            if not dry_run:
                merged = {**current, **record}
                already.write_text(json.dumps(merged, indent=2) + "\n")
                text = transcript_text(recording.get("segments") or [])
                if text:
                    (already.parent / "transcript.txt").write_text(text)
            updated.append(title)
            touched_slugs.add(slug)
            continue

        if dry_run:
            imported.append(title)
            continue

        folder_out = brains_mod.store_recap(slug, record, transcript="")
        write_cli_recap(folder_out, record, recording, with_audio, folder)
        seen_by_slug[slug][ios_id] = folder_out / RECORD_NAME
        imported.append(title)
        touched_slugs.add(slug)

    if not dry_run and touched_slugs:
        # The graph is what `think`, `exam` and `walk` read, so keep it current.
        try:
            from . import cortex as cortex_mod

            for slug in sorted(touched_slugs):
                cortex_mod.rebuild(slug)
        except Exception:
            pass

    return Report(
        folder=str(folder),
        imported=len(imported),
        updated=len(updated),
        unfiled=unfiled,
        titles=imported[:10],
        brains=sorted(touched_slugs),
        dry_run=dry_run,
    )


# --------------------------------------------------------------------- status


def status(target: str | Path | None = None) -> Report:
    """What each side is holding, without moving anything."""
    root = home()
    cli_records = discover_record_paths(root)
    cli_brains, _ = discover_brains(root)

    try:
        folder = sync_dir(target)
    except SyncUnavailable as error:
        return Report(
            available=False,
            reason=str(error),
            cli_records=len(cli_records),
            cli_brains=len(cli_brains),
        )

    recordings = read_json(folder / RECORDINGS_NAME, [])
    shared_brains = read_json(folder / BRAINS_NAME, [])
    live = [r for r in recordings if isinstance(r, dict) and not r.get("deleted")]

    audio_root = audio_dir(folder)
    audio_files = list(audio_root.glob("*")) if audio_root.is_dir() else []
    audio_bytes = sum(f.stat().st_size for f in audio_files if f.is_file())

    return Report(
        available=True,
        folder=str(folder),
        cli_records=len(cli_records),
        cli_brains=len(cli_brains),
        shared_records=len(live),
        shared_tombstones=len(recordings) - len(live),
        shared_brains=len([b for b in shared_brains if not b.get("deleted")]),
        audio_files=len(audio_files),
        audio_bytes=audio_bytes,
        unprocessed=len([r for r in live if not r.get("recap")]),
    )


def human_bytes(size: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} GB"


def want_auto_sync() -> bool:
    raw = (os.environ.get("CATCHMEUP_SYNC") or "auto").strip().lower()
    return raw not in {"0", "false", "off", "no"}


def want_auto_audio() -> bool:
    raw = (os.environ.get("CATCHMEUP_SYNC_AUDIO") or "").strip().lower()
    return raw in {"1", "true", "yes", "on"}


def auto_push(brain: str | None = None) -> Report | None:
    """If the shared folder already exists, send recaps. Never raises.

    Recap on the Mac should show up on the phone without a second command.
    Missing iCloud is normal (the phone hasn't turned Sync on yet), so this
    is silent unless something actually moved.
    """
    if not want_auto_sync():
        return None
    try:
        sync_dir(create=False)
    except SyncUnavailable:
        return None
    try:
        return push(brain=brain, with_audio=want_auto_audio())
    except Exception:
        return None


# ------------------------------------------------------------------------ CLI


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="catchup sync", description=__doc__)
    sub = parser.add_subparsers(dest="action")

    parsers = {}
    for name, helptext in (
        ("push", "Send CLI recaps to the shared folder."),
        ("pull", "Bring phone recordings into CLI brains."),
        ("status", "Show what each side is holding."),
    ):
        p = sub.add_parser(name, help=helptext)
        p.add_argument("--dir", help="Shared folder (default: the iCloud container).")
        if name != "status":
            p.add_argument("--brain", help="Limit to one brain slug.")
            p.add_argument("--dry-run", action="store_true", help="Report without writing.")
        parsers[name] = p
    parsers["push"].add_argument(
        "--with-audio", action="store_true", help="Also copy archived audio (large)."
    )
    parsers["pull"].add_argument(
        "--no-audio", action="store_true", help="Skip copying audio into the brain."
    )

    args = parser.parse_args(argv)
    action = args.action or "status"

    try:
        if action == "push":
            report = push(args.dir, args.brain, args.with_audio, args.dry_run)
            verb = "Would send" if report.dry_run else "Sent"
            print(f"{verb} {report.converted} recap(s) and {report.brains} brain(s).")
            print(f"  Shared folder now holds {report.total} recording(s).")
            if report.skipped:
                print(f"  Skipped {report.skipped} folder(s) with no notes yet.")
            if not report.with_audio:
                print("  Audio skipped — add --with-audio to include it.")
            print(f"  {report.folder}")
        elif action == "pull":
            report = pull(args.dir, args.brain, not args.no_audio, args.dry_run)
            verb = "Would import" if report.dry_run else "Imported"
            print(f"{verb} {report.imported} recording(s), updated {report.updated}.")
            for title in report.titles:
                print(f"  · {title}")
            if report.unfiled:
                print(
                    f"  {report.unfiled} recording(s) had no brain — filed into processed/."
                )
            if report.brains:
                print(f"  Brains touched: {', '.join(report.brains)}")
        else:
            report = status(args.dir)
            if not report.available:
                print(f"CLI library: {report.cli_records} recap(s), {report.cli_brains} brain(s).")
                print()
                print(report.reason)
                return 1
            print(f"Shared folder  {report.folder}")
            print(f"  CLI library    {report.cli_records} recap(s), {report.cli_brains} brain(s)")
            print(f"  Shared         {report.shared_records} recording(s), {report.shared_brains} brain(s)")
            if report.shared_tombstones:
                print(f"  Deleted        {report.shared_tombstones} tombstone(s)")
            if report.unprocessed:
                print(f"  Awaiting notes {report.unprocessed} recording(s) from the phone")
            print(f"  Audio          {report.audio_files} file(s), {human_bytes(report.audio_bytes)}")
    except SyncUnavailable as error:
        print(str(error))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
