#!/usr/bin/env python3
"""Practice exams from a CatchMeUp brain (terms, study list, cortex gaps)."""
from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent
if str(PROJECT_DIR) not in sys.path:
    sys.path.insert(0, str(PROJECT_DIR))

import brains
import library
from brains import _tokens


def _records(brain: str | None):
    rows = library.list_records(mode="lecture", brain=brain) or library.list_records(brain=brain)
    return rows


def build_exam(records: list[dict], count: int = 8, rng: random.Random | None = None) -> list[dict]:
    """Build short-answer questions from recaps. No network."""
    rng = rng or random.Random()
    pool: list[dict] = []
    seen = set()

    def add(prompt: str, answer: str, source: str, kind: str, timestamp: str = ""):
        key = prompt.strip().lower()
        if not prompt.strip() or not answer.strip() or key in seen:
            return
        seen.add(key)
        pool.append({
            "kind": kind,
            "prompt": prompt.strip(),
            "answer": answer.strip(),
            "source": source,
            "timestamp": timestamp,
        })

    for rec in records:
        analysis = rec.get("analysis") or {}
        title = rec.get("title") or rec.get("source") or "recap"
        for term, definition in library._terms_from(rec):
            if definition.startswith("(from the study"):
                add(term, f"(from {title}) {term}", title, "study")
            else:
                add(f"Define: {term}", definition, title, "term")
        for bm in analysis.get("bookmarks") or []:
            if not isinstance(bm, dict):
                continue
            heading = (bm.get("heading") or "").strip()
            insight = (bm.get("insight") or "").strip()
            if heading and insight:
                add(
                    f"Why does “{heading}” matter?",
                    insight,
                    title,
                    "moment",
                    str(bm.get("timestamp") or ""),
                )
        for section in analysis.get("detailed_notes") or []:
            if isinstance(section, dict) and section.get("heading") and section.get("content"):
                add(
                    f"Explain: {section['heading']}",
                    str(section["content"])[:400],
                    title,
                    "notes",
                )
    rng.shuffle(pool)
    return pool[: max(1, count)] if pool else []


def grade_answer(question: dict, typed: str) -> dict:
    """Cheap token overlap — used when you don't want to spend an LLM call."""
    expected = set(_tokens(question.get("answer") or ""))
    got = set(_tokens(typed or ""))
    if not typed.strip():
        return {"score": 0.0, "verdict": "blank", "overlap": 0}
    if not expected:
        return {"score": 0.5, "verdict": "ungraded", "overlap": 0}
    overlap = len(expected & got)
    score = overlap / max(1, len(expected))
    if score >= 0.45 or (typed.strip() and typed.strip().lower() in (question.get("answer") or "").lower()):
        verdict = "pass"
    elif score >= 0.2:
        verdict = "partial"
    else:
        verdict = "miss"
    return {"score": round(score, 2), "verdict": verdict, "overlap": overlap}


def format_exam(questions: list[dict], answers: bool = False) -> str:
    if not questions:
        return "No exam material yet. Recap a lecture into this brain first."
    lines = [f"CatchMeUp exam — {len(questions)} question(s)", ""]
    for i, q in enumerate(questions, 1):
        where = q.get("source") or ""
        ts = f"  [{q['timestamp']}]" if q.get("timestamp") else ""
        lines.append(f"{i}. {q['prompt']}")
        lines.append(f"    ({q.get('kind')}) {where}{ts}")
        if answers:
            lines.append(f"    → {q['answer']}")
        lines.append("")
    if not answers:
        lines.append("Reveal answers:  ./catchup exam NAME --print --answers")
        lines.append("Take it live:    ./catchup exam NAME")
        lines.append("Hear a moment:   ./catchup clip NAME <words from the question>")
    return "\n".join(lines).rstrip() + "\n"


def cmd_exam(brain: str | None, count: int, print_only: bool, show_answers: bool):
    if brain:
        brains.load_brain(brain)
    rows = _records(brain)
    if not rows:
        print("Nothing to examine. Recap a lecture first:")
        print("  ./catchup lecture FILE")
        print("  ./catchup into cs61a FILE")
        sys.exit(1)
    questions = build_exam(rows, count=count)
    if not questions:
        print("Recaps have no terms / study items / notes to examine yet.")
        sys.exit(1)
    if print_only:
        print(format_exam(questions, answers=show_answers))
        return
    print(f"Exam — {len(questions)} questions from your recaps. q = quit.\n")
    passed = 0
    attempted = 0
    import viz

    for i, q in enumerate(questions, 1):
        print(f"[{i}/{len(questions)}]  {q['prompt']}")
        print(f"         {q.get('source')}")
        try:
            typed = input("         your answer: ").strip()
        except EOFError:
            print()
            break
        if typed.lower() in {"q", "quit"}:
            break
        attempted += 1
        result = grade_answer(q, typed)
        mark = viz.verdict_mark(result["verdict"])
        print(f"         {mark}  {q['answer'][:220]}")
        if result["verdict"] == "pass":
            passed += 1
        print()
    print(viz.exam_card(passed, attempted or 0, len(questions)))
    if brain:
        print(f"Go deeper:  ./catchup think {brain} <the one you missed>")
        print(f"Hear it:    ./catchup clip {brain} <term>")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="catchup-exam")
    parser.add_argument("--brain")
    parser.add_argument("-n", "--count", type=int, default=8)
    parser.add_argument("--print", dest="print_only", action="store_true")
    parser.add_argument("--answers", action="store_true")
    args = parser.parse_args(argv)
    cmd_exam(args.brain, args.count, args.print_only, args.answers)


if __name__ == "__main__":
    main()
