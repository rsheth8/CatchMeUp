#!/usr/bin/env python3
"""Local CatchMeUp library: search, ask, quiz, and action items across recaps.

This is the part Otter-style apps keep in the cloud. Yours lives in processed/.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from . import brains as brains_mod
from .paths import RECORD_NAME


def load_env():
    brains_mod.load_env()


def _iter_dirs():
    roots = []
    processed = brains_mod.processed_root()
    if processed.exists():
        roots.append(processed)
    brains_dir = brains_mod.brains_root()
    if brains_dir.exists():
        for brain in brains_dir.iterdir():
            recaps = brain / "recaps"
            if recaps.is_dir():
                roots.append(recaps)
    return roots


def iter_records(brain: str | None = None):
    if brain:
        yield from brains_mod.iter_brain_records(brain)
        return
    for root in _iter_dirs():
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
            if "brains" in folder.parts:
                try:
                    data.setdefault("brain", folder.parts[folder.parts.index("brains") + 1])
                except (ValueError, IndexError):
                    pass
            yield data


def list_records(mode: str | None = None, brain: str | None = None) -> list[dict]:
    rows = []
    for rec in iter_records(brain=brain):
        if mode and rec.get("mode") != mode:
            continue
        rows.append(rec)
    return rows


def _haystack(rec: dict) -> str:
    analysis = rec.get("analysis") or {}
    parts = [
        rec.get("title", ""),
        rec.get("source", ""),
        rec.get("mode", ""),
        " ".join(analysis.get("tldr") or []),
        " ".join(analysis.get("action_items") or []),
        " ".join(analysis.get("study") or []),
    ]
    for bm in analysis.get("bookmarks") or []:
        if isinstance(bm, dict):
            parts.append(bm.get("heading", ""))
            parts.append(bm.get("insight", ""))
    for section in analysis.get("detailed_notes") or []:
        if isinstance(section, dict):
            parts.append(section.get("heading", ""))
            parts.append(section.get("content", ""))
    for term in analysis.get("terms") or []:
        if isinstance(term, dict):
            parts.append(term.get("term", ""))
            parts.append(term.get("definition", ""))
        else:
            parts.append(str(term))
    for sp in analysis.get("speakers") or []:
        if isinstance(sp, dict):
            parts.append(str(sp.get("label") or ""))
            parts.append(str(sp.get("name") or ""))
            parts.append(str(sp.get("said") or ""))
        else:
            parts.append(str(sp))
    folder = Path(rec.get("_dir", ""))
    transcript = folder / "transcript.txt"
    if transcript.exists():
        parts.append(transcript.read_text()[:20000])
    return "\n".join(parts).lower()


def search_records(query: str, mode: str | None = None, records: list | None = None) -> list[dict]:
    needles = [n for n in query.lower().split() if n]
    hits = []
    pool = records if records is not None else list_records(mode)
    for rec in pool:
        if mode and rec.get("mode") != mode:
            continue
        blob = _haystack(rec)
        if all(n in blob for n in needles):
            hits.append(rec)
    return hits


def cmd_library(mode: str | None, brain: str | None = None):
    if brain:
        meta = brains_mod.load_brain(brain)
        print(f"Brain: {meta.get('name')}  ({brain})  · {meta.get('kind')}")
        print(meta.get("persona", "").strip()[:280])
        print()
    rows = list_records(mode, brain=brain)
    if not rows:
        print("Library is empty. Recap a meeting or lecture first:")
        print("  ./catchup meeting FILE")
        print("  ./catchup lecture FILE")
        return
    print(f"{'when':<20} {'mode':<9} title")
    print("─" * 56)
    for rec in rows:
        when = rec.get("processed_at") or rec.get("recorded_at") or "?"
        print(f"{when:<20} {rec.get('mode', '?'):<9} {rec.get('title') or rec.get('source')}")
    print(f"\n{len(rows)} recap(s). Search: ./catchup search mutex")
    print("Ask:    ./catchup ask what did we decide about the API?")
    print("Quiz:   ./catchup quiz")
    print("Todos:  ./catchup todos")


def cmd_search(query: str, mode: str | None, brain: str | None = None):
    if not query.strip():
        print("Usage: ./catchup search <words>")
        sys.exit(1)
    hits = search_records(query, mode, records=list_records(mode, brain=brain))
    if not hits:
        print(f"No recaps mention {query!r}.")
        return
    print(f"{len(hits)} hit(s) for {query!r}:\n")
    q = query.lower()
    for rec in hits:
        title = rec.get("title") or rec.get("source")
        print(f"• [{rec.get('mode')}] {title}")
        analysis = rec.get("analysis") or {}
        snippets = []
        for bullet in (analysis.get("tldr") or [])[:3]:
            if any(n in str(bullet).lower() for n in q.split()):
                snippets.append(str(bullet))
        folder = Path(rec.get("_dir", ""))
        transcript = folder / "transcript.txt"
        if transcript.exists() and not snippets:
            for line in transcript.read_text().splitlines():
                if any(n in line.lower() for n in q.split()):
                    snippets.append(line.strip())
                    if len(snippets) >= 2:
                        break
        for snip in snippets[:2]:
            print(f"    {snip[:160]}")
        print()


def cmd_ask(question: str, mode: str | None, brain: str | None = None, closed: bool | None = None):
    load_env()
    if not question.strip():
        print("Usage: ./catchup ask [brain] <your question>")
        sys.exit(1)
    if brain:
        print(brains_mod.ask_brain(
            brain, question, log=lambda m: print(f"[{m}]", file=sys.stderr), closed=closed,
        ))
        return
    rows = list_records(mode)
    from . import materials
    for entry in brains_mod.list_brains():
        if not mode or entry.get("kind") == mode:
            rows.extend(materials.records(entry["slug"]))
    if not rows:
        print("Nothing in the library yet. Recap a recording or add supporting materials first.")
        sys.exit(1)
    hits = brains_mod.retrieve(question, rows)
    closed = brains_mod.want_closed(closed)
    if closed and not hits:
        print(
            "Nothing in the library matched that question. "
            "Not guessing from general knowledge."
        )
        sys.exit(1)
    context = brains_mod.format_evidence(hits) if hits else brains_mod.EMPTY_SOURCES
    if closed:
        instruction = (
            "Closed book: numbered sources only. Cite [n] plus the recap title "
            "and timestamps. If the library does not contain the answer, say so."
        )
    else:
        instruction = (
            "Notes first. Write **From your notes** (cite [n]) then, if needed, "
            "**Beyond the recordings** for anything not in the sources."
        )
    prompt = (
        f"You are CatchMeUp. {instruction}\n\n"
        f"Question: {question}\n\nSources:\n{context}"
    )
    from .providers import complete_text

    print(complete_text(
        prompt,
        log=lambda m: print(f"[{m}]", file=sys.stderr),
        system=brains_mod.grounding_system(closed),
    ))


def _terms_from(rec: dict) -> list[tuple[str, str]]:
    cards = []
    analysis = rec.get("analysis") or {}
    for term in analysis.get("terms") or []:
        if isinstance(term, dict) and term.get("term"):
            cards.append((str(term.get("term")), str(term.get("definition") or "")))
    for item in analysis.get("study") or []:
        cards.append((str(item), "(from the study checklist — recall what the lecture said)"))
    return cards


def cmd_quiz(mode: str | None, count: int, brain: str | None = None):
    rows = list_records(mode or "lecture", brain=brain) or list_records(None, brain=brain)
    cards = []
    for rec in rows:
        for term, definition in _terms_from(rec):
            cards.append((term, definition, rec.get("title") or rec.get("source")))
    if not cards:
        print("No terms yet. Recap a lecture first: ./catchup lecture FILE")
        sys.exit(1)
    from . import exam as exam_mod

    if brain:
        cards = exam_mod.order_quiz_cards(cards, brain, count)
    else:
        random.shuffle(cards)
        cards = cards[: max(1, count)]
    from . import viz

    print(f"Quiz — {len(cards)} cards from your library. Enter = reveal. q = quit.\n")
    correctish = 0
    for i, (term, definition, title) in enumerate(cards, 1):
        print(viz.flashcard(i, len(cards), term, title))
        try:
            typed = input("         your answer (or enter): ").strip()
        except EOFError:
            print()
            break
        if typed.lower() in {"q", "quit"}:
            break
        print(f"         → {definition or '(no definition stored)'}")
        if typed and definition:
            fake_q = {"prompt": f"Define: {term}", "answer": definition, "kind": "term"}
            result = exam_mod.grade_answer(fake_q, typed)
            if result["verdict"] == "pass":
                correctish += 1
                print("         (looks close)")
            if brain:
                exam_mod.record_attempt(brain, fake_q, result["verdict"])
        print()
    print("Done. Misses stick around:  ./catchup drill " + (brain or "<brain>"))


def cmd_todos(mode: str | None, brain: str | None = None):
    from .workspace import followups, task_line
    rows = list_records(mode or "meeting", brain=brain)
    items = []
    for rec in rows:
        analysis = rec.get("analysis") or {}
        slug = rec.get("brain") or brain
        mapped = brains_mod.apply_speaker_map(slug, analysis) if slug else analysis
        for item in followups({**rec, "analysis": mapped}):
            if item.get("status") != "done":
                items.append((rec.get("title") or rec.get("source"), rec.get("recorded_at"), task_line(item)))
    if not items:
        print("No action items in the library yet. Recap a meeting: ./catchup meeting FILE")
        return
    print(f"{len(items)} follow-up(s) across your meetings:\n")
    for title, when, item in items:
        print(f"• {item}")
        print(f"    {title}  ({when or '?'})")
        print()


def cmd_moments(mode: str | None):
    rows = list_records(mode)
    if not rows:
        print("Library is empty.")
        sys.exit(1)
    rec = rows[0]
    bookmarks = (rec.get("analysis") or {}).get("bookmarks") or []
    print(f"{rec.get('title') or rec.get('source')}  [{rec.get('mode')}]")
    if not bookmarks:
        print("No timestamps stored for this recap.")
        return
    from . import viz

    track = viz.timeline(bookmarks)
    if track:
        print()
        print(track)
        print()
    for bm in bookmarks:
        if not isinstance(bm, dict):
            continue
        print(f"  [{bm.get('timestamp', '?')}] {bm.get('heading')}")
        insight = (bm.get("insight") or "").strip()
        if insight:
            print(f"      {insight}")
    print("\nPlay a moment: ./catchup play 00:12:40")


def _parse_ts(ts: str) -> float:
    raw = (ts or "").strip()
    if not raw:
        return 0.0
    parts = [float(p) for p in raw.split(":")]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    return float(parts[0])


def recap_audio(rec: dict) -> Path | None:
    folder = Path(rec.get("_dir", ""))
    name = rec.get("audio") or ""
    if name:
        path = folder / name
        if path.exists():
            return path
    if folder.is_dir():
        for mp3 in list(folder.glob("*.mp3")) + list(folder.glob("*.m4a")) + list(folder.glob("*.wav")):
            return mp3
    return None


def play_range(audio: Path, start: float, duration: float = 25) -> str:
    """Cut 25s with ffmpeg, then afplay a real file. `afplay -` (stdin) fails on macOS.

    Returns 'ok', 'stopped' (Ctrl-C), or 'error'.
    """
    ffmpeg = shutil.which("ffmpeg") or ""
    if not ffmpeg:
        bundled = Path("/opt/homebrew/bin/ffmpeg")
        ffmpeg = str(bundled) if bundled.exists() else ""
    if not ffmpeg:
        print("ffmpeg not found — open the file yourself:")
        print(f"  {audio}")
        return "error"
    if not Path(audio).exists():
        print(f"Audio missing: {audio}")
        return "error"
    afplay = shutil.which("afplay")
    tmp = ""
    try:
        fd, tmp = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        subprocess.run(
            [
                ffmpeg, "-hide_banner", "-loglevel", "error",
                "-ss", str(max(0.0, start)), "-t", str(duration),
                "-i", str(audio), "-vn", "-y", tmp,
            ],
            check=True,
        )
        if afplay:
            subprocess.run([afplay, tmp], check=False)
        else:
            print("afplay not found — extracted clip:")
            print(f"  {tmp}")
            tmp = ""
        return "ok"
    except subprocess.CalledProcessError:
        print(f"Could not extract a clip from {audio}")
        return "error"
    except KeyboardInterrupt:
        print()
        return "stopped"
    finally:
        if tmp:
            Path(tmp).unlink(missing_ok=True)


def _recap_for_episode(slug: str, episode: str) -> dict | None:
    needle = (episode or "").strip().lower()
    if not needle:
        return None
    fallback = None
    for rec in brains_mod.iter_brain_records(slug):
        title = (rec.get("title") or "").strip().lower()
        source = (rec.get("source") or "").strip().lower()
        if title and (needle == title or needle in title or title in needle):
            return rec
        if source and needle in source:
            fallback = rec
    return fallback


def _clip_from_moment(rec: dict, moment: dict, concept: str = "") -> dict:
    ts = str(moment.get("timestamp") or "")
    return {
        "rec": rec,
        "heading": moment.get("heading") or concept,
        "insight": moment.get("insight") or "",
        "timestamp": ts or "00:00:00",
        "start": _parse_ts(ts) if ts else 0.0,
        "audio": recap_audio(rec),
        "score": 100.0,
        "concept": concept,
        "episode": moment.get("episode") or rec.get("title") or "",
    }


def clips_from_cortex(slug: str, query: str) -> list[dict]:
    """Every timestamp this concept was heard, in lecture order."""
    from . import cortex as cortex_mod

    try:
        graph = cortex_mod.load_cortex(slug)
    except FileNotFoundError:
        return []
    nid = cortex_mod.find_node(graph, query)
    if not nid:
        return []
    node = (graph.get("nodes") or {}).get(nid) or {}
    moments = [m for m in (node.get("moments") or []) if str(m.get("timestamp") or "").strip()]
    out = []
    seen = set()
    for moment in moments:
        rec = _recap_for_episode(slug, str(moment.get("episode") or ""))
        if not rec:
            for ep in node.get("episodes") or []:
                rec = _recap_for_episode(slug, str(ep))
                if rec:
                    break
        if not rec:
            continue
        hit = _clip_from_moment(rec, moment, concept=nid)
        key = (hit["timestamp"], hit.get("heading"), str(rec.get("source") or ""))
        if key in seen:
            continue
        seen.add(key)
        out.append(hit)
    out.sort(key=lambda h: (h.get("start") or 0.0, h.get("heading") or ""))
    return out


def _clip_from_cortex(slug: str, query: str) -> dict | None:
    clips = clips_from_cortex(slug, query)
    return clips[0] if clips else None


def find_clip(query: str, mode: str | None = None, brain: str | None = None, records: list | None = None) -> dict | None:
    from .brains import _tokens

    needles = _tokens(query)
    if not needles:
        return None
    if brain and records is None:
        hit = _clip_from_cortex(brain, query)
        if hit:
            return hit
    pool = records if records is not None else list_records(mode, brain=brain)
    best = None
    best_score = 0.0
    q = (query or "").strip().lower()
    for rec in pool:
        analysis = rec.get("analysis") or {}
        title = rec.get("title") or rec.get("source") or ""
        candidates = []
        for bm in analysis.get("bookmarks") or []:
            if isinstance(bm, dict):
                blob = f"{bm.get('heading', '')} {bm.get('insight', '')} {title}"
                candidates.append((blob, bm.get("heading") or "", bm.get("insight") or "", str(bm.get("timestamp") or "")))
        for term in analysis.get("terms") or []:
            if isinstance(term, dict):
                blob = f"{term.get('term', '')} {term.get('definition', '')} {title}"
                ts = ""
                for bm in analysis.get("bookmarks") or []:
                    if isinstance(bm, dict) and (term.get("term") or "").lower() in (
                        f"{bm.get('heading', '')} {bm.get('insight', '')}".lower()
                    ):
                        ts = str(bm.get("timestamp") or "")
                        break
                candidates.append((blob, term.get("term") or "", term.get("definition") or "", ts))
        for blob, heading, insight, ts in candidates:
            words = set(_tokens(blob))
            overlap = sum(1 for w in needles if w in words)
            if overlap == 0:
                continue
            heading_l = heading.lower()
            score = float(overlap)
            if heading_l == q or heading_l.startswith(q + " ") or heading_l.endswith(" " + q):
                score += 8
            elif q and q in heading_l:
                score += 4
            if ts:
                score += 0.3
            if score > best_score:
                best_score = score
                best = {
                    "rec": rec,
                    "heading": heading,
                    "insight": insight,
                    "timestamp": ts or "00:00:00",
                    "start": _parse_ts(ts) if ts else 0.0,
                    "audio": recap_audio(rec),
                    "score": score,
                }
    return best


def list_clips(query: str, mode: str | None = None, brain: str | None = None, records: list | None = None) -> list[dict]:
    if brain and records is None:
        clips = clips_from_cortex(brain, query)
        if clips:
            return clips
    hit = find_clip(query, mode=mode, brain=brain, records=records)
    return [hit] if hit else []


def cmd_play(timestamp: str, mode: str | None, brain: str | None = None):
    if not timestamp:
        print("Usage: ./catchup play HH:MM:SS")
        sys.exit(1)
    rows = list_records(mode, brain=brain)
    audio = None
    rec = None
    for candidate in rows:
        audio = recap_audio(candidate)
        if audio:
            rec = candidate
            break
    if not audio:
        print("No archived mp3 found. Recap a file first (audio is stored in processed/).")
        sys.exit(1)
    start = _parse_ts(timestamp)
    print(f"Playing {rec.get('title') or audio.name} from {timestamp}")
    play_range(audio, start)


def _print_clip(hit: dict, index: int, total: int) -> None:
    rec = hit["rec"]
    title = rec.get("title") or rec.get("source")
    ts = hit["timestamp"]
    where = f"{index}/{total}" if total > 1 else ""
    prefix = f"[{where}] " if where else ""
    print(f"{prefix}{title}")
    src = rec.get("source") or ""
    if src and src != title:
        print(f"  {src}")
    print(f"  [{ts}] {hit['heading']}")
    if hit.get("insight"):
        print(f"      {hit['insight']}")


def cmd_clip(query: str, mode: str | None, brain: str | None = None, dry: bool = False):
    if not query.strip():
        print("Usage: ./catchup clip [brain] <words>")
        sys.exit(1)
    clips = list_clips(query, mode=mode, brain=brain)
    if not clips:
        print(f"No bookmark or term matched {query!r}.")
        print("Try: ./catchup search " + query)
        sys.exit(1)
    if dry or os.environ.get("CATCHMEUP_NO_AUDIO"):
        for i, hit in enumerate(clips, 1):
            _print_clip(hit, i, len(clips))
            audio = hit.get("audio")
            if audio:
                print(f"  audio: {audio}")
        if len(clips) > 1:
            print(f"\n{len(clips)} moments. Play them:  ./catchup clip {brain or ''} {query}".replace("  ", " "))
        return
    interactive = sys.stdin.isatty() and sys.stdout.isatty() and len(clips) > 1
    i = 0
    while 0 <= i < len(clips):
        hit = clips[i]
        _print_clip(hit, i + 1, len(clips))
        audio = hit.get("audio")
        if not audio:
            print("No archived audio for that recap. Timestamp is above.")
            print(f"  ./catchup play {hit['timestamp']}")
        else:
            print(f"Playing 25s from {hit['timestamp']}…")
            if interactive:
                print("  n next · p prev · w walk · enter replay · q quit   (Ctrl-C = next)")
            status = play_range(audio, hit["start"])
            if interactive and status == "stopped":
                i = (i + 1) % len(clips)
                continue
        if not interactive:
            if len(clips) > 1:
                print(f"\n{len(clips)} moments. Replay with n/p in a terminal, or --print to list them.")
            return
        try:
            raw = input("clip> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if raw in {"q", "quit", "exit"}:
            return
        if raw in {"n", "next", "+", "j"}:
            i = (i + 1) % len(clips)
            continue
        if raw in {"p", "prev", "-", "k"}:
            i = (i - 1) % len(clips)
            continue
        if raw in {"w", "walk"} and brain and hit.get("concept"):
            from . import cortex as cortex_mod
            cortex_mod.run_walk(brain, hit["concept"])
            continue
        if raw.isdigit():
            idx = int(raw) - 1
            if 0 <= idx < len(clips):
                i = idx
            continue
        # enter / unknown → replay same clip
        continue


def _norm_set(items) -> set[str]:
    out = set()
    for item in items or []:
        s = re.sub(r"\s+", " ", str(item).strip().lower())
        if s:
            out.add(s)
    return out


def _term_set(rec: dict) -> set[str]:
    names = set()
    for term in (rec.get("analysis") or {}).get("terms") or []:
        if isinstance(term, dict) and term.get("term"):
            names.add(str(term["term"]).strip().lower())
        elif term:
            names.add(str(term).strip().lower())
    return names


def _topic_set(rec: dict) -> set[str]:
    names = set()
    analysis = rec.get("analysis") or {}
    for section in analysis.get("detailed_notes") or []:
        if isinstance(section, dict) and section.get("heading"):
            names.add(str(section["heading"]).strip().lower())
    for bm in analysis.get("bookmarks") or []:
        if isinstance(bm, dict) and bm.get("heading"):
            names.add(str(bm["heading"]).strip().lower())
    return names


def diff_recaps(newer: dict, older: dict) -> dict:
    new_actions = _norm_set((newer.get("analysis") or {}).get("action_items"))
    old_actions = _norm_set((older.get("analysis") or {}).get("action_items"))
    new_terms = _term_set(newer)
    old_terms = _term_set(older)
    new_topics = _topic_set(newer)
    old_topics = _topic_set(older)
    new_tldr = _norm_set((newer.get("analysis") or {}).get("tldr"))
    old_tldr = _norm_set((older.get("analysis") or {}).get("tldr"))
    return {
        "newer_title": newer.get("title") or newer.get("source"),
        "older_title": older.get("title") or older.get("source"),
        "newer_when": newer.get("recorded_at") or newer.get("processed_at"),
        "older_when": older.get("recorded_at") or older.get("processed_at"),
        "mode": newer.get("mode") or older.get("mode"),
        "terms_added": sorted(new_terms - old_terms),
        "terms_dropped": sorted(old_terms - new_terms),
        "actions_added": sorted(new_actions - old_actions),
        "actions_closed": sorted(old_actions - new_actions),
        "topics_added": sorted(new_topics - old_topics),
        "topics_dropped": sorted(old_topics - new_topics),
        "tldr_added": sorted(new_tldr - old_tldr),
        "tldr_dropped": sorted(old_tldr - new_tldr),
    }


def format_diff(diff: dict) -> str:
    lines = [
        f"Diff  {diff.get('older_title')}  →  {diff.get('newer_title')}",
        f"      {diff.get('older_when') or '?'}  →  {diff.get('newer_when') or '?'}",
        "",
    ]

    def block(title: str, added, dropped):
        if not added and not dropped:
            return
        lines.append(title)
        for item in added:
            lines.append(f"  + {item}")
        for item in dropped:
            lines.append(f"  − {item}")
        lines.append("")

    if (diff.get("mode") or "") == "meeting" or diff.get("actions_added") or diff.get("actions_closed"):
        block("Action items", diff.get("actions_added"), diff.get("actions_closed"))
    block("Terms", diff.get("terms_added"), diff.get("terms_dropped"))
    block("Topics / moments", diff.get("topics_added"), diff.get("topics_dropped"))
    block("TL;DR", diff.get("tldr_added"), diff.get("tldr_dropped"))
    if len(lines) <= 3:
        lines.append("These two recaps look the same from the structured fields.")
    return "\n".join(lines).rstrip() + "\n"


def cmd_diff(mode: str | None, brain: str | None = None):
    rows = list_records(mode, brain=brain)
    if len(rows) < 2:
        print("Need at least two recaps to diff.")
        print("  ./catchup into NAME FILE   (again)")
        sys.exit(1)
    newer, older = rows[0], rows[1]
    print(format_diff(diff_recaps(newer, older)))


def main(argv=None):
    parser = argparse.ArgumentParser(prog="catchup-library")
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("library", "search", "ask", "quiz", "todos", "moments", "play", "clip", "diff"):
        p = sub.add_parser(name)
        p.add_argument("--mode", choices=("meeting", "lecture"))
        p.add_argument("--brain")
        if name == "search":
            p.add_argument("query", nargs="+")
        elif name == "ask":
            p.add_argument("question", nargs="+")
            p.add_argument(
                "--closed",
                action="store_true",
                help="Exam mode: answer only from recaps, no general knowledge",
            )
        elif name == "quiz":
            p.add_argument("-n", "--count", type=int, default=8)
        elif name == "play":
            p.add_argument("timestamp")
        elif name == "clip":
            p.add_argument("query", nargs="+")
            p.add_argument("--print", dest="dry", action="store_true")
    args = parser.parse_args(argv)
    mode = getattr(args, "mode", None)
    brain = getattr(args, "brain", None) or None
    if args.cmd == "library":
        cmd_library(mode, brain=brain)
    elif args.cmd == "search":
        cmd_search(" ".join(args.query), mode, brain=brain)
    elif args.cmd == "ask":
        cmd_ask(
            " ".join(args.question),
            mode,
            brain=brain,
            closed=True if getattr(args, "closed", False) else None,
        )
    elif args.cmd == "quiz":
        cmd_quiz(mode, args.count, brain=brain)
    elif args.cmd == "todos":
        cmd_todos(mode, brain=brain)
    elif args.cmd == "moments":
        cmd_moments(mode)
    elif args.cmd == "play":
        cmd_play(args.timestamp, mode, brain=brain)
    elif args.cmd == "clip":
        cmd_clip(" ".join(args.query), mode, brain=brain, dry=getattr(args, "dry", False))
    elif args.cmd == "diff":
        cmd_diff(mode, brain=brain)


if __name__ == "__main__":
    main()
