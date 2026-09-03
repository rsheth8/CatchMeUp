"""Folder brains: one specialist agent per subject or team.

Each brain is a directory with a persona plus recaps filed into it.
Asking that brain RAG-searches only its folder, then answers in character.
"""
from __future__ import annotations

import json
import math
import re
from datetime import datetime
from pathlib import Path

from .paths import (
    RECORD_NAME,
    brains_root,
    home,
    load_env,
    logs_root,
    output_root,
    processed_root,
    recordings_root,
)

# home / load_env / *_root stay on this module so `brains.home()` still works.

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
        "speakers": {},
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
    """One recording, or every media file under a folder (nested week dirs included)."""
    path = Path(path)
    if path.is_file():
        return [path] if path.suffix.lower() in MEDIA_SUFFIXES else []
    if not path.is_dir():
        return []
    out = []
    for p in path.rglob("*"):
        if not p.is_file() or p.name.startswith("."):
            continue
        try:
            rel = p.relative_to(path)
        except ValueError:
            continue
        if any(part.startswith(".") for part in rel.parts):
            continue
        if p.suffix.lower() in MEDIA_SUFFIXES:
            out.append(p)
    return sorted(out)


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


def retrieve(question: str, records: list[dict], k: int = 12, boost: list[dict] | None = None) -> list[dict]:
    q = _tokens(question)
    if not q:
        return []
    packed: list[tuple[dict, str, str, set[str]]] = []
    for rec in records:
        for label, text in _chunks(rec):
            words = set(_tokens(text))
            if words:
                packed.append((rec, label, text, words))
    n_docs = max(1, len(packed))
    df: dict[str, int] = {}
    for _, _, _, words in packed:
        for w in words:
            df[w] = df.get(w, 0) + 1
    boost_ids = {str(n.get("id") or "") for n in (boost or []) if n.get("id")}
    boost_eps = set()
    for node in boost or []:
        for ep in node.get("episodes") or []:
            if ep:
                boost_eps.add(str(ep).lower())
    q_blob = re.sub(r"\s+", " ", (question or "").strip().lower())[:80]
    scored = []
    for rec, label, text, words in packed:
        hits = [w for w in q if w in words]
        if not hits:
            continue
        score = 0.0
        for w in hits:
            score += math.log(1.0 + n_docs / max(1, df.get(w, 1)))
        blob = text.lower()
        if q_blob and q_blob in blob:
            score += 2.4
        title = str(rec.get("title") or rec.get("source") or "").lower()
        if any(ep in title or title in ep for ep in boost_eps if ep):
            score += 0.9
        if any(bid and bid in blob for bid in boost_ids):
            score += 0.5
        score = score / (1 + (len(words) ** 0.2))
        scored.append({
            "score": score,
            "label": label,
            "text": text.strip(),
            "title": rec.get("title") or rec.get("source"),
            "mode": rec.get("mode"),
        })
    scored.sort(key=lambda x: x["score"], reverse=True)
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
    from .providers import complete_text

    brain = load_brain(slug)
    records = list(iter_brain_records(slug))
    if not records:
        return (
            f"Brain `{slug}` has no recaps yet. Drop a recording into "
            f"brains/{slug}/inbox/ or run: ./catchup into {slug} FILE"
        )
    fired: list[dict] = []
    try:
        from . import cortex as cortex_mod

        if cortex_mod.load_cortex(slug).get("nodes"):
            fired = cortex_mod.activate(slug, question, hops=2, top=10)
    except Exception:
        fired = []
    hits = retrieve(question, records, boost=fired)
    if not hits:
        hits = [{"label": rec.get("title"), "text": " ".join((rec.get("analysis") or {}).get("tldr") or [])} for rec in records[:6]]
    packed = []
    budget = 42000
    if fired:
        concept_lines = ["Activated concepts:"]
        for node in fired[:8]:
            concept_lines.append(
                f"- {node.get('id')} ({node.get('kind')}) {node.get('definition') or ''}"
            )
        packed.append("\n".join(concept_lines) + "\n")
        budget -= len(packed[-1])
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


def canonical_speaker_label(raw: str) -> str:
    s = (raw or "").strip()
    named = re.match(r"(?i)^speaker\s*(\d+)$", s)
    if named:
        return f"Speaker {int(named.group(1))}"
    if re.match(r"^\d+$", s):
        return f"Speaker {int(s)}"
    return s


def speaker_map(slug: str) -> dict:
    try:
        return dict(load_brain(slug).get("speakers") or {})
    except FileNotFoundError:
        return {}


def set_speaker_name(slug: str, label: str, name: str) -> dict:
    meta = load_brain(slug)
    speakers = meta.setdefault("speakers", {})
    key = canonical_speaker_label(label)
    name = (name or "").strip()
    if not name:
        speakers.pop(key, None)
    else:
        speakers[key] = name
    meta["speakers"] = speakers
    save_brain(meta)
    return speakers


def speaker_prompt_hint(slug: str | None) -> str:
    if not slug:
        return ""
    mapping = speaker_map(slug)
    if not mapping:
        return ""
    roster = ", ".join(f"{k} is {v}" for k, v in mapping.items() if v)
    if not roster:
        return ""
    return (
        f" Known roster: {roster}. Use those names in action_items and speakers[] "
        "(keep the Speaker N label too)."
    )


def apply_speaker_map(slug: str | None, analysis: dict) -> dict:
    if not slug or not isinstance(analysis, dict):
        return analysis
    mapping = speaker_map(slug)
    if not mapping:
        return analysis

    def rewrite(text: str) -> str:
        out = str(text)
        for label, name in mapping.items():
            if not name:
                continue
            out = re.sub(rf"\b{re.escape(label)}\b", name, out, flags=re.I)
        return out

    items = analysis.get("action_items")
    if items:
        analysis["action_items"] = [rewrite(str(x)) for x in items]
    for sp in analysis.get("speakers") or []:
        if not isinstance(sp, dict):
            continue
        label = canonical_speaker_label(str(sp.get("label") or ""))
        if label in mapping:
            sp["name"] = mapping[label]
        if sp.get("said"):
            sp["said"] = rewrite(str(sp["said"]))
    for bm in analysis.get("bookmarks") or []:
        if isinstance(bm, dict):
            for key in ("heading", "insight"):
                if bm.get(key):
                    bm[key] = rewrite(str(bm[key]))
    return analysis


def grade_work(slug: str, work: str, assignment: str = "", log=print) -> str:
    """Grade homework / code against this brain's recaps only."""
    from .providers import complete_text

    brain = load_brain(slug)
    records = list(iter_brain_records(slug))
    if not records:
        return (
            f"Brain `{slug}` has no recaps yet. File lectures first: "
            f"./catchup into {slug} FILE"
        )
    work = (work or "").strip()
    if not work:
        return "Paste the homework, code, or written answer to grade."
    query = f"{assignment} {work[:900]}".strip()
    fired: list[dict] = []
    try:
        from . import cortex as cortex_mod

        if cortex_mod.load_cortex(slug).get("nodes"):
            fired = cortex_mod.activate(slug, query, hops=2, top=12)
    except Exception:
        fired = []
    hits = retrieve(query, records, k=12, boost=fired)
    packed = []
    budget = 36000
    for hit in hits:
        piece = f"### {hit.get('label')}\n{hit.get('text', '')}\n"
        if budget - len(piece) < 0:
            break
        packed.append(piece)
        budget -= len(piece)
    evidence = "\n".join(packed) if packed else "(no overlapping recap chunks)"
    prompt = (
        f"{brain.get('persona')}\n\n"
        f"Grade this student work using ONLY the recaps in **{brain.get('name')}**. "
        "Do not invent lecture content. Structure the reply as:\n"
        "1. Verdict: correct / partial / off\n"
        "2. What matches the recordings (cite recap titles and timestamps)\n"
        "3. What's missing or contradicts the lectures\n"
        "4. What to clip or restudy next (`./catchup clip {slug} TERM`)\n"
        "If the work uses ideas that were never in these recordings, say so.\n\n"
        f"Assignment prompt (may be empty): {assignment or '(none given)'}\n\n"
        f"Student work:\n{work[:12000]}\n\n"
        f"Evidence from recaps:\n{evidence}"
    )
    return complete_text(prompt, log=log)
