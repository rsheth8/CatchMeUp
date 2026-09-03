"""Split a long transcript so one LLM call cannot silently drop the rest.

Mirrors `ios/CatchMeUp/Engine/RecapChunking.swift`. Short recordings stay a
single pass. Long lectures are cut on `[HH:MM:SS]` lines, recapped per
window, then merged with overlap deduped.
"""
from __future__ import annotations

import os
import re
from typing import Any

CLOUD_CHARS = 60_000
OLLAMA_CHARS = 12_000
OVERLAP_LINES = 2

_LETTER_NUM = re.compile(r"[^a-z0-9]+")


def recap_budget() -> int:
    raw = (os.environ.get("CATCHMEUP_CHUNK_CHARS") or "").strip()
    if raw:
        try:
            return max(2_000, int(raw))
        except ValueError:
            pass
    try:
        from .providers import active_provider

        if active_provider() == "ollama":
            return OLLAMA_CHARS
    except Exception:
        pass
    return CLOUD_CHARS


def transcript_chunks(
    transcript: str, max_characters: int | None = None, overlap_lines: int = OVERLAP_LINES
) -> list[str]:
    """Split on timestamp lines. Nothing is dropped; seams carry a little context."""
    budget = recap_budget() if max_characters is None else max_characters
    text = transcript or ""
    if budget <= 0:
        return [] if not text else [text]
    if not text:
        return []
    if len(text) <= budget:
        return [text]

    lines = text.split("\n")
    chunks: list[str] = []
    current: list[str] = []
    length = 0

    for line in lines:
        if length + len(line) + 1 > budget and current:
            chunks.append("\n".join(current))
            carried = current[-overlap_lines:] if overlap_lines else []
            carried_len = sum(len(s) + 1 for s in carried)
            if carried and carried_len <= budget // 3:
                current = list(carried)
                length = carried_len
            else:
                current = []
                length = 0
        current.append(line)
        length += len(line) + 1
    if current:
        chunks.append("\n".join(current))
    return chunks


def _norm(text: str) -> str:
    return _LETTER_NUM.sub("", (text or "").lower())


def _ts_seconds(stamp: str) -> float:
    parts = [p for p in re.split(r"[:.]", str(stamp or "").strip()) if p]
    nums: list[float] = []
    for part in parts:
        try:
            nums.append(float(part))
        except ValueError:
            return 0.0
    if not nums:
        return 0.0
    total = 0.0
    for n in nums:
        total = total * 60 + n
    return total


def _dedupe(items: list[Any], cap: int, key) -> list[Any]:
    seen: set[str] = set()
    out: list[Any] = []
    for item in items:
        k = _norm(key(item))
        if not k or k in seen:
            continue
        seen.add(k)
        out.append(item)
        if len(out) >= cap:
            break
    return out


def _as_str_list(value: Any) -> list[str]:
    return [str(x) for x in (value or []) if str(x).strip()]


def _as_obj_list(value: Any) -> list[dict]:
    return [x for x in (value or []) if isinstance(x, dict)]


def merge_analyses(parts: list[dict[str, Any]]) -> dict[str, Any]:
    """Union of partial recaps. A single part is returned unchanged."""
    live = [p for p in parts if isinstance(p, dict)]
    if not live:
        return {}
    if len(live) == 1:
        return dict(live[0])

    title = next((str(p.get("title") or "").strip() for p in live if str(p.get("title") or "").strip()), "")

    tldr = _dedupe(sum((_as_str_list(p.get("tldr")) for p in live), []), 12, lambda s: s)
    actions = _dedupe(
        sum((_as_str_list(p.get("action_items")) for p in live), []), 30, lambda s: s
    )
    study = _dedupe(sum((_as_str_list(p.get("study")) for p in live), []), 18, lambda s: s)
    terms = _dedupe(
        sum((_as_obj_list(p.get("terms")) for p in live), []),
        50,
        lambda t: str(t.get("term") or ""),
    )
    bookmarks = _dedupe(
        sum((_as_obj_list(p.get("bookmarks")) for p in live), []),
        24,
        lambda b: str(b.get("heading") or ""),
    )
    bookmarks.sort(key=lambda b: _ts_seconds(str(b.get("timestamp") or "")))

    notes: list[dict] = []
    notes_by: dict[str, dict] = {}
    order: list[str] = []
    for note in sum((_as_obj_list(p.get("detailed_notes")) for p in live), []):
        heading = str(note.get("heading") or "")
        content = str(note.get("content") or "")
        key = _norm(heading) or _norm(content)[:40]
        if not key:
            continue
        existing = notes_by.get(key)
        if existing is None:
            notes_by[key] = {"heading": heading, "content": content}
            order.append(key)
        elif _norm(content) and _norm(content) not in _norm(str(existing.get("content") or "")):
            existing["content"] = str(existing.get("content") or "") + "\n\n" + content
    notes = [notes_by[k] for k in order[:30]]

    speakers_by: dict[str, dict] = {}
    speaker_order: list[str] = []
    for speaker in sum((_as_obj_list(p.get("speakers")) for p in live), []):
        label = str(speaker.get("label") or "")
        name = str(speaker.get("name") or "")
        key = _norm(label or name)
        if not key:
            continue
        existing = speakers_by.get(key)
        if existing is None:
            speakers_by[key] = {
                "label": label,
                "name": name,
                "said": str(speaker.get("said") or ""),
            }
            speaker_order.append(key)
        else:
            if not existing.get("name") and name:
                existing["name"] = name
            if not existing.get("said"):
                existing["said"] = str(speaker.get("said") or "")
    speakers = [speakers_by[k] for k in speaker_order[:12]]

    out: dict[str, Any] = {"title": title, "tldr": tldr, "bookmarks": bookmarks, "detailed_notes": notes}
    if actions:
        out["action_items"] = actions
    if speakers:
        out["speakers"] = speakers
    if terms:
        out["terms"] = terms
    if study:
        out["study"] = study
    return out
