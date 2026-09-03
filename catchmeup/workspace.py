"""Student/work CLI workflows. Reading and organizing never call a model."""
from __future__ import annotations

import argparse
import copy
import json
import sys
import uuid
import zipfile
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

from . import brains, materials
from .paths import RECORD_NAME
from .sync import atomic_json_write, iso_date, parse_iso


def recaps(slug: str) -> list[dict]:
    materials.root(slug)  # Validate scope before touching any path.
    return sorted(brains.iter_brain_records(slug), key=lambda r: r.get("recorded_at", ""), reverse=True)


def followups(record: dict) -> list[dict]:
    """Lazy migration: read-only commands never write or claim a task was reviewed."""
    meeting = record.get("meeting") or {}
    if "followUps" in meeting:
        return copy.deepcopy(meeting["followUps"])
    result, seen = [], {}
    for i, title in enumerate((record.get("analysis") or {}).get("action_items", [])):
        normalized = " ".join(str(title).lower().split())
        if normalized in seen:
            if i in record.get("completedActions", []):
                seen[normalized]["status"] = "done"
            continue
        if not normalized:
            continue
        # Stable across reads; saved iOS UUID is used when available.
        identity = str(record.get("ios_id") or record.get("_dir") or record.get("source"))
        result.append({"id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{identity}:{i}:{normalized}")).upper(),
                       "title": str(title), "owner": "", "deadlineText": "",
                       "status": "done" if i in record.get("completedActions", []) else "open",
                       "timestamp": "", "evidence": "", "needsReview": True, "editedByUser": False})
        seen[normalized] = result[-1]
    return result


def task_rows(slug: str) -> list[tuple[dict, dict]]:
    return [(r, t) for r in recaps(slug) if r.get("mode") == "meeting" for t in followups(r)]


def task_line(task: dict) -> str:
    due = task.get("dueDate") or task.get("deadlineText") or "no deadline"
    if task.get("dueDate"):
        due = str(due)[:10]
    review = " · needs review" if task.get("needsReview", True) else ""
    return f"{task['id'][:8]}  [{task.get('status', 'open')}] {task['title']} · {task.get('owner') or 'unassigned'} · {due}{review}"


def update_task(slug: str, task_id: str, action: str, owner: str | None = None,
                due: str | None = None) -> dict:
    matches = [(r, t) for r, t in task_rows(slug) if t["id"].lower().startswith(task_id.lower())]
    if len(matches) != 1:
        raise ValueError("Task ID must uniquely match a task. Run ./catchup tasks NAME to see IDs.")
    record, selected = matches[0]
    path = Path(record["_dir"]) / RECORD_NAME
    payload = json.loads(path.read_text())
    meeting = payload.setdefault("meeting", None) or {"agenda": "", "outcomes": [], "documentNotes": []}
    tasks = followups(record)
    task = next(t for t in tasks if t["id"] == selected["id"])
    if owner is not None:
        task["owner"] = owner.strip()
    if due is not None:
        task["dueDate"] = None if due == "none" else date.fromisoformat(due).isoformat() + "T12:00:00Z"
        task["deadlineText"] = "" if due == "none" else due
    if action == "review":
        task["needsReview"] = False
    elif action in ("done", "open", "start"):
        task["status"] = {"done": "done", "open": "open", "start": "inProgress"}[action]
    task["editedByUser"] = True
    meeting["followUps"] = tasks
    payload["meeting"] = meeting
    # Swift sync uses whole seconds. Rapid consecutive edits must not tie.
    previous = max((parse_iso(iso_date(payload[k])) for k in ("processed_at", "ios_updated_at") if payload.get(k)),
                   default=datetime.min.replace(tzinfo=timezone.utc))
    updated = max(datetime.now(timezone.utc).replace(microsecond=0), previous + timedelta(seconds=1))
    payload["processed_at"] = iso_date(updated.isoformat())
    atomic_json_write(path, payload)
    return task


def brief(slug: str, study: bool = False) -> str:
    brain = brains.load_brain(slug)
    rows = recaps(slug)
    if study and brain.get("kind") != "lecture":
        raise ValueError("Use ./catchup prepare NAME for a meeting brain.")
    if not study and brain.get("kind") != "meeting":
        raise ValueError("Use ./catchup review NAME for a course brain.")
    lines = [f"{'Study review' if study else 'Meeting prep'} · {brain['name']}",
             "From saved sources only · no AI request\n"]
    if not rows:
        lines.append(f"No recordings yet. Add one with ./catchup into {slug} FILE")
    for record in rows[:3]:
        lines.append(f"\n{record.get('recorded_at', '')} · {record['title']}")
        analysis = record.get("analysis") or {}
        lines.extend(f"  • {x}" for x in (analysis.get("tldr") or [])[:4])
        if study:
            lines.extend(f"  Practice: {x}" for x in (analysis.get("study") or [])[:4])
            for term in (analysis.get("terms") or [])[:5]:
                if isinstance(term, dict):
                    lines.append(f"  Recall: {term.get('term')} — {term.get('definition', '')}")
        else:
            meeting = record.get("meeting") or {}
            if meeting.get("agenda"):
                lines.append(f"  Agenda: {meeting['agenda']}")
            for outcome in meeting.get("outcomes", []):
                state = "resolved" if outcome.get("resolved") else "unresolved"
                review = "reviewed" if outcome.get("reviewed") else "unreviewed"
                lines.append(f"  {outcome.get('kind', 'Outcome')} ({state}, {review}): {outcome.get('text', '')}")
    if not study:
        lines.append("\nOpen follow-ups (all meetings in this brain)")
        pending = [(r, t) for r, t in task_rows(slug) if t.get("status") != "done"]
        lines.extend(f"  {task_line(t)}\n    Source: {r['title']}" for r, t in pending)
        if not pending:
            lines.append("  No open follow-ups.")
    docs = materials.list_materials(slug)
    lines.append(f"\nSupporting materials · {len(docs)}")
    lines.extend(f"  {d['id'][:8]} · {d['name']} · {len(d['pages'])} text section(s)" for d in docs)
    if study:
        lines.append(f"\nNext: ./catchup exam {slug} --print   or   ./catchup drill {slug}")
    else:
        lines.append(f"\nNext: ./catchup tasks {slug}   or   ./catchup diff {slug}")
    lines.append(f'Ask across recordings + materials: ./catchup ask {slug} "YOUR QUESTION" --closed')
    return "\n".join(lines)


def dashboard(audience: str = "all") -> str:
    lines = ["CatchMeUp · Your workspace", "Local overview · no AI request\n"]
    entries = [b for b in brains.list_brains()
               if audience == "all" or b.get("kind") == ("lecture" if audience == "student" else "meeting")]
    for brain in entries:
        slug = brain["slug"]
        study = brain.get("kind") == "lecture"
        rows = recaps(slug)
        docs = materials.list_materials(slug)
        lines.append(f"{'Course' if study else 'Work'} · {brain['name']} ({slug})")
        lines.append(f"  {len(rows)} recap(s) · {len(docs)} material(s)")
        if rows:
            lines.append(f"  Latest: {rows[0]['title']} · {rows[0].get('recorded_at', '')}")
        if not study:
            pending = [t for _, t in task_rows(slug) if t.get("status") != "done"]
            lines.append(f"  {len(pending)} open follow-up(s) · {sum(bool(t.get('needsReview', True)) for t in pending)} need review")
        lines.append(f"  Next: ./catchup {'review' if study else 'prepare'} {slug}\n")
    if not entries:
        lines.extend(["Start with a course or work project:",
                      '  ./catchup brain new "Biology 101" --lecture',
                      '  ./catchup brain new "Product team" --meeting',
                      "Then add recordings with into NAME FILE, or materials with materials NAME add FILE."])
    from . import library
    mode = None if audience == "all" else ("lecture" if audience == "student" else "meeting")
    unfiled = [r for r in library.list_records(mode) if not r.get("brain")]
    if unfiled:
        lines.append(f"\nAlso in your library: {len(unfiled)} unfiled recap(s). See ./catchup library")
        if audience != "student":
            lines.append("Follow-ups from unfiled meetings: ./catchup todos")
    return "\n".join(lines)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="./catchup", description="Local-first study and work tools. No API key needed for these commands.")
    commands = p.add_subparsers(dest="command", required=True)
    today = commands.add_parser("today", help="Overview of courses and work projects")
    today.add_argument("--audience", choices=["all", "student", "work"], default="all")
    for name in ("prepare", "review"):
        sub = commands.add_parser(name, help="Meeting prep" if name == "prepare" else "Course review")
        sub.add_argument("brain")
    tasks = commands.add_parser("tasks", help="Review and track meeting follow-ups")
    tasks.add_argument("brain")
    tasks.add_argument("action", nargs="?", default="list", choices=["list", "review", "done", "open", "start", "edit"])
    tasks.add_argument("id", nargs="?")
    tasks.add_argument("--owner", help="Set owner; quote full names")
    tasks.add_argument("--due", help="Set a confirmed date YYYY-MM-DD, or 'none' to clear")
    tasks.add_argument("--all", action="store_true", help="Include completed tasks")
    tasks.add_argument("--json", action="store_true", help="Machine-readable output")
    docs = commands.add_parser("materials", help="Local PDF/PPTX/TXT/MD materials for a course or team")
    docs.add_argument("brain")
    docs.add_argument("action", choices=["list", "add", "show", "search"], nargs="?", default="list")
    docs.add_argument("values", nargs="*")
    docs.add_argument("--recap", help="Attach to one recap by unique title fragment or folder ID")
    return p


def main(argv=None) -> int:
    p = parser()
    args = p.parse_args(argv)
    try:
        if args.command == "today":
            print(dashboard(args.audience))
        elif args.command in ("prepare", "review"):
            print(brief(args.brain, args.command == "review"))
        elif args.command == "tasks":
            if args.action == "list":
                if args.id or args.owner is not None or args.due is not None:
                    raise ValueError("To change a task, use tasks NAME edit ID --owner NAME --due YYYY-MM-DD.")
                rows = [(r, t) for r, t in task_rows(args.brain) if args.all or t.get("status") != "done"]
                if args.json:
                    print(json.dumps([{**t, "source": r["title"]} for r, t in rows], indent=2))
                else:
                    print(f"Follow-ups · {args.brain}\n")
                    for record, task in rows:
                        print(f"{task_line(task)}\n  Source: {record['title']}")
                        if task.get("evidence"):
                            print(f"  Evidence [{task.get('timestamp') or '?'}]: {task['evidence']}")
                    if not rows:
                        print("No open follow-ups. Use --all to include completed tasks.")
                    print("\nReview: tasks NAME review ID --owner NAME --due YYYY-MM-DD\nTrack: tasks NAME start|done|open ID")
            else:
                if not args.id:
                    raise ValueError("Specify a task ID from ./catchup tasks NAME.")
                if args.action == "edit" and args.owner is None and args.due is None:
                    raise ValueError("Use --owner or --due to edit a task.")
                task = update_task(args.brain, args.id, args.action, args.owner, args.due)
                print(json.dumps(task, indent=2) if args.json else task_line(task) + "\nSaved locally. Run ./catchup sync push when ready to sync.")
        elif args.command == "materials":
            if args.recap and args.action != "add":
                raise ValueError("--recap is only used when adding a material.")
            if args.action == "add":
                if not args.values:
                    raise ValueError("Usage: ./catchup materials NAME add FILE [FILE ...] [--recap TITLE]")
                for value in args.values:
                    material, created = materials.add(args.brain, Path(value), args.recap)
                    print(f"{'Added' if created else 'Already saved'}: {material['name']} · {material['id'][:8]}")
                    for warning in material["warnings"]:
                        print(f"  Note: {warning}")
                print("Originals and extracted text stay local. AI questions can send relevant text to your configured provider. Materials do not sync to iPhone yet.")
            elif args.action == "show":
                if len(args.values) != 1:
                    raise ValueError("Usage: ./catchup materials NAME show ID")
                found = [d for d in materials.list_materials(args.brain) if d["id"].startswith(args.values[0])]
                if len(found) != 1:
                    raise ValueError("Use a unique material ID from ./catchup materials NAME.")
                print(found[0]["name"])
                for page in found[0]["pages"]:
                    print(f"\n[{page['label']}]\n{page['text']}")
            elif args.action == "search":
                if not args.values:
                    raise ValueError("Usage: ./catchup materials NAME search WORDS")
                hits = brains.retrieve(" ".join(args.values), materials.records(args.brain))
                print(brains.format_evidence(hits) if hits else "No matching text in this brain's materials.")
            else:
                if args.values:
                    raise ValueError("Use materials NAME add FILE, show ID, or search WORDS.")
                docs = materials.list_materials(args.brain)
                for d in docs:
                    print(f"{d['id'][:8]}  {d['name']} · {len(d['pages'])} text section(s)")
                    for linked in d.get("recaps", []):
                        print(f"  Attached to: {linked['title']}")
                if not docs:
                    print(f"No materials yet. Add slides, agendas, or readings: ./catchup materials {args.brain} add FILE")
        return 0
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, ET.ParseError) as exc:
        print(f"CatchMeUp: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
