"""Folder brains: one specialist agent per subject or team.

Each brain is a directory with a persona plus recaps filed into it.
Asking that brain RAG-searches only its folder, then answers in character.
"""
from __future__ import annotations

import json
import os
import re
from datetime import datetime
from pathlib import Path

CODE_DIR = Path(__file__).resolve().parent
RECORD_NAME = "catchmeup.json"

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
MEDIA_SUFFIXES = {".mov", ".mp4", ".m4a", ".mp3", ".wav", ".aac", ".mkv", ".webm"}
STOP = {
    "a", "an", "the", "of", "to", "for", "in", "on", "and", "or", "is", "was",
    "what", "who", "how", "why", "did", "does", "are", "be", "this", "that",
    "with", "from", "about", "into", "your", "you", "we", "they", "it",
}

DEFAULT_PERSONAS = {
    "lecture": (
        "You are an all-knowing course specialist. You only teach from the recaps "
        "and transcripts in this folder — lectures the student actually has. "
        "Explain clearly, define terms, cite timestamps, and flag likely exam material. "
        "If it was not in these recordings, say so."
    ),
    "meeting": (
        "You are the institutional memory for this team, account, or project. "
        "You only use the meeting recaps in this folder. Track decisions, owners, "
        "deadlines, and open loops. Cite which meeting something came from. "
        "If it was not discussed here, say so."
    ),
}


def home() -> Path:
    return Path(os.environ.get("CATCHMEUP_HOME") or CODE_DIR)


def brains_root() -> Path:
    return home() / "brains"


def processed_root() -> Path:
    return home() / "processed"


def output_root() -> Path:
    return home() / "output"


def logs_root() -> Path:
    return home() / "logs"


def recordings_root() -> Path:
    return home() / "recordings"


def load_env() -> None:
    seen: set[Path] = set()
    for path in (home() / ".env", CODE_DIR / ".env"):
        resolved = path.resolve() if path.exists() else path
        if resolved in seen or not path.is_file():
            continue
        seen.add(resolved)
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip())


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")
    return s[:63] or "brain"


def brain_dir(slug: str) -> Path:
    return brains_root() / slug


def brain_meta_path(slug: str) -> Path:
    return brain_dir(slug) / "brain.json"


def recaps_dir(slug: str) -> Path:
    return brain_dir(slug) / "recaps"


def inbox_dir(slug: str) -> Path:
    return brain_dir(slug) / "inbox"


def notes_dir(slug: str) -> Path:
    return brain_dir(slug) / "notes"


def exists(slug: str) -> bool:
    return brain_meta_path(slug).is_file()


def load_brain(slug: str) -> dict:
    path = brain_meta_path(slug)
    if not path.is_file():
        raise FileNotFoundError(
            f"No brain named {slug!r}. Create one with: ./catchup brain new {slug}"
        )
    data = json.loads(path.read_text())
    data["slug"] = slug
    data["_dir"] = str(brain_dir(slug))
    return data


def list_brains() -> list[dict]:
    root = brains_root()
    if not root.exists():
        return []
    rows = []
    for folder in sorted(root.iterdir()):
        meta = folder / "brain.json"
        if not meta.is_file():
            continue
        try:
            data = json.loads(meta.read_text())
        except json.JSONDecodeError:
            continue
        data["slug"] = folder.name
        data["_dir"] = str(folder)
        data["recap_count"] = sum(1 for _ in iter_brain_records(folder.name))
        rows.append(data)
    return rows


def create_brain(name: str, kind: str = "lecture", persona: str | None = None) -> dict:
    slug = slugify(name)
    if not SLUG_RE.match(slug):
        raise ValueError(f"Invalid brain name {name!r}")
    if exists(slug):
        raise FileExistsError(f"Brain {slug} already exists")
    if kind not in ("lecture", "meeting"):
        kind = "lecture"
    folder = brain_dir(slug)
    recaps_dir(slug).mkdir(parents=True, exist_ok=True)
    inbox_dir(slug).mkdir(parents=True, exist_ok=True)
    notes_dir(slug).mkdir(parents=True, exist_ok=True)
    (inbox_dir(slug) / ".gitkeep").write_text("")
    meta = {
        "name": name.strip() or slug,
        "slug": slug,
        "kind": kind,
        "persona": (persona or DEFAULT_PERSONAS[kind]).strip(),
        "created": datetime.now().strftime("%Y-%m-%d %H:%M"),
    }
    brain_meta_path(slug).write_text(json.dumps(meta, indent=2) + "\n")
    return meta


def save_brain(meta: dict) -> None:
    slug = meta["slug"]
    payload = {k: v for k, v in meta.items() if not k.startswith("_") and k != "recap_count"}
    brain_meta_path(slug).write_text(json.dumps(payload, indent=2) + "\n")


def iter_brain_records(slug: str):
    root = recaps_dir(slug)
    if not root.exists():
        return
    for folder in sorted(root.iterdir(), reverse=True):
        rec_path = folder / RECORD_NAME
        if not rec_path.is_file():
            continue
        try:
            data = json.loads(rec_path.read_text())
        except json.JSONDecodeError:
            continue
        data["_dir"] = str(folder)
        data["_path"] = str(rec_path)
        data["brain"] = slug
        yield data


def media_files(path: Path) -> list[Path]:
    """One recording, or every media file in a folder (non-recursive)."""
    path = Path(path)
    if path.is_file():
        return [path] if path.suffix.lower() in MEDIA_SUFFIXES else []
    if not path.is_dir():
        return []
    return sorted(
        p for p in path.iterdir()
        if p.is_file() and p.suffix.lower() in MEDIA_SUFFIXES and not p.name.startswith(".")
    )


def ingested_sources(slug: str) -> set[str]:
    return {str(rec.get("source") or "") for rec in iter_brain_records(slug)}


def pending_media(slug: str, path: Path) -> list[Path]:
    have = ingested_sources(slug)
    return [p for p in media_files(path) if p.name not in have]


def keep_source(source: Path, brain_slug: str | None = None) -> bool:
    """Leave originals in a library folder. Inbox / recordings/ are consumed."""
    src = Path(source).resolve()
    roots = [recordings_root().resolve()]
    if brain_slug:
        roots.append(inbox_dir(brain_slug).resolve())
    for root in roots:
        try:
            src.relative_to(root)
            return False
        except ValueError:
            continue
    return True


def unique_stamp_dir(root: Path, stem: str) -> Path:
    """Timestamped folder that will not clobber a sibling from the same second."""
    root.mkdir(parents=True, exist_ok=True)
    safe = re.sub(r"[^a-zA-Z0-9._-]+", "-", stem).strip("-") or "recap"
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    folder = root / f"{stamp}_{safe}"
    n = 1
    while folder.exists():
        folder = root / f"{stamp}-{n}_{safe}"
        n += 1
    return folder


def store_recap(slug: str, rec: dict, transcript: str = "") -> Path:
    """Write a recap folder under this brain (used by the pipeline and tests)."""
    load_brain(slug)
    source = rec.get("source") or rec.get("title") or "recap"
    stem = Path(str(source)).stem
    folder = unique_stamp_dir(recaps_dir(slug), stem)
    folder.mkdir(parents=True, exist_ok=True)
    if transcript:
        (folder / "transcript.txt").write_text(transcript)
    payload = {k: v for k, v in rec.items() if not str(k).startswith("_")}
    payload["brain"] = slug
    (folder / RECORD_NAME).write_text(json.dumps(payload, indent=2) + "\n")
    return folder


def _tokens(text: str) -> list[str]:
    return [w for w in re.findall(r"[a-z0-9]+", (text or "").lower()) if w not in STOP and len(w) > 2]


def _chunks(rec: dict) -> list[tuple[str, str]]:
    """(label, text) pieces used for retrieval."""
    analysis = rec.get("analysis") or {}
    title = rec.get("title") or rec.get("source") or "recap"
    when = rec.get("recorded_at") or ""
    prefix = f"{title} ({when})"
    chunks = []
    tldr = analysis.get("tldr") or []
    if tldr:
        chunks.append((f"{prefix} · summary", "\n".join(str(x) for x in tldr)))
    for item in analysis.get("action_items") or []:
        chunks.append((f"{prefix} · action", str(item)))
    for bm in analysis.get("bookmarks") or []:
        if isinstance(bm, dict):
            chunks.append((
                f"{prefix} · [{bm.get('timestamp', '?')}] {bm.get('heading', '')}",
                f"{bm.get('heading', '')}: {bm.get('insight', '')}",
            ))
    for section in analysis.get("detailed_notes") or []:
        if isinstance(section, dict):
            chunks.append((
                f"{prefix} · {section.get('heading', 'notes')}",
                f"{section.get('heading', '')}\n{section.get('content', '')}",
            ))
    for term in analysis.get("terms") or []:
        if isinstance(term, dict):
            chunks.append((f"{prefix} · term {term.get('term')}", f"{term.get('term')}: {term.get('definition')}"))
        else:
            chunks.append((f"{prefix} · term", str(term)))
    for item in analysis.get("study") or []:
        chunks.append((f"{prefix} · study", str(item)))
    folder = Path(rec.get("_dir", ""))
    transcript = folder / "transcript.txt"
    if transcript.exists():
        text = transcript.read_text()
        step = 1400
        for i in range(0, len(text), step):
            piece = text[i : i + step + 200]
            if piece.strip():
                chunks.append((f"{prefix} · transcript", piece))
    return chunks


def retrieve(question: str, records: list[dict], k: int = 12) -> list[dict]:
    q = _tokens(question)
    if not q:
        return []
    scored = []
    for rec in records:
        for label, text in _chunks(rec):
            words = set(_tokens(text))
            if not words:
                continue
            overlap = sum(1 for w in q if w in words)
            if overlap == 0:
                continue
            score = overlap / (1 + (len(words) ** 0.3))
            scored.append({
                "score": score,
                "label": label,
                "text": text.strip(),
                "title": rec.get("title") or rec.get("source"),
                "mode": rec.get("mode"),
            })
    scored.sort(key=lambda x: x["score"], reverse=True)
    # de-dupe near-identical labels
    seen = set()
    out = []
    for hit in scored:
        key = hit["label"]
        if key in seen:
            continue
        seen.add(key)
        out.append(hit)
        if len(out) >= k:
            break
    return out


def ask_brain(slug: str, question: str, log=print) -> str:
    from providers import complete_text

    brain = load_brain(slug)
    records = list(iter_brain_records(slug))
    if not records:
        return (
            f"Brain `{slug}` has no recaps yet. Drop a recording into "
            f"brains/{slug}/inbox/ or run: ./catchup into {slug} FILE"
        )
    hits = retrieve(question, records)
    if not hits:
        hits = [{"label": rec.get("title"), "text": " ".join((rec.get("analysis") or {}).get("tldr") or [])} for rec in records[:6]]
    packed = []
    budget = 42000
    for hit in hits:
        piece = f"### {hit.get('label')}\n{hit.get('text', '')}\n"
        if budget - len(piece) < 0:
            break
        packed.append(piece)
        budget -= len(piece)
    context = "\n".join(packed)
    prompt = (
        f"{brain.get('persona')}\n\n"
        f"You are the specialist agent for **{brain.get('name')}** "
        f"(folder `brains/{slug}/`). Use ONLY the retrieved notes and transcript "
        f"chunks below. Cite the recap title and timestamps. If the answer is not "
        f"in this brain, say you don't have it — do not borrow from general knowledge "
        f"that wasn't in the recordings.\n\n"
        f"Question: {question}\n\nRetrieved context:\n{context}"
    )
    return complete_text(prompt, log=log)
