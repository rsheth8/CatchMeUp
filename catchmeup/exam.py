#!/usr/bin/env python3
"""Practice exams from a CatchMeUp brain (terms, study list, cortex gaps)."""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
from datetime import datetime
from pathlib import Path

from . import brains
from . import library
from .brains import _tokens

MEMORY_FILE = "memory.json"


def _records(brain: str | None):
    rows = library.list_records(mode="lecture", brain=brain) or library.list_records(brain=brain)
    return rows


def memory_path(slug: str) -> Path:
    return brains.brain_dir(slug) / MEMORY_FILE


def load_memory(slug: str) -> dict:
    path = memory_path(slug)
    if not path.is_file():
        return {"attempts": []}
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        return {"attempts": []}
    data.setdefault("attempts", [])
    return data


def save_memory(slug: str, memory: dict) -> None:
    brains.brain_dir(slug).mkdir(parents=True, exist_ok=True)
    memory_path(slug).write_text(json.dumps(memory, indent=2) + "\n")


FLUFF_HEAD = re.compile(
    r"(walkthrough|overview|big picture|announcement|introduction to |"
    r"basics and initialization|practical example|summary|conclusion|recap$|"
    r"^key moments|^lecture notes)",
    re.I,
)
META_SENT = re.compile(
    r"will (definitely )?be on the (quiz or )?exam|"
    r"multiple-choice|common exam question|quiz question|"
    r"high-difficulty|expect .*questions?|"
    r"this is a core rule of python oop|"
    r"this type of trace is exactly|"
    r"knowing how to verify your work|"
    r"options [a-d]\b|"
    r"critical exam topic|"
    r"appear frequently on exams|"
    r"this is a common exam",
    re.I,
)
EXAM_FILLER = re.compile(
    r"\s*(this will (definitely )?be on the (quiz or )?exam[^.]*\.?|"
    r"this is a high-difficulty topic[^.]*\.?|"
    r"this is (the )?(core idea|fundamental syntax)[^.]*\.?|"
    r"this type of trace is exactly what quiz questions ask\.?)",
    re.I,
)
CODE_RE = re.compile(
    r"`([^`]+)`|"
    r"(\b[A-Za-z_][\w.]*\[[^\]]+\])|"
    r"(s\[[^\]]+\])|"
    r"(\+=)|"
    r"(\b\w+\(\))",
)
KEY_STOP = brains.STOP | {
    "only", "also", "just", "like", "used", "using", "very", "common", "means",
    "meaning", "called", "make", "makes", "does", "done", "take", "takes",
    "give", "gives", "one", "two", "can", "will", "often", "each", "then",
    "than", "them", "your", "their", "this", "that", "these", "those",
    "most", "more", "some", "any", "still", "even", "into", "over",
    "best", "though", "doesn", "expect", "core", "rule", "python", "name",
    "call", "value", "data", "define", "short", "answer", "choice", "exam",
    "quiz", "practice", "question", "students", "student", "lecture",
    "when", "both", "piece", "instead", "exist", "options", "wrong",
    "specifically", "because", "violate",
}
SYNONYM_GROUPS = [
    {"concatenate", "concatenation", "concat", "join", "joined", "joining", "append", "appended", "combine", "combined"},
    {"mutex", "lock", "locks"},
    {"exclusive", "excluded", "exclude"},
    {"inclusive", "included", "include", "including"},
    {"zero", "zerobased", "zero-based"},
    {"backward", "backwards", "reverse", "reversed", "reversing"},
    {"shorthand", "equivalent", "same"},
    {"acquire", "acquired", "acquiring"},
    {"release", "released", "releasing"},
    {"frame", "frames", "stack"},
    {"pointer", "pointers", "parent"},
    {"thread", "threads"},
    {"index", "indexes", "indices", "position", "offset"},
    {"slice", "slicing", "substring", "substr"},
    {"immutable", "unchangeable"},
    {"alias", "aliasing", "same-object", "sameobject"},
    {"mutate", "mutated", "mutation", "mutable"},
]


def concept_key(question: dict) -> str:
    if question.get("concept"):
        return str(question["concept"]).strip().lower()
    prompt = (question.get("prompt") or "").strip()
    m = re.match(r"(?i)^define:\s*(.+)$", prompt)
    if m:
        return m.group(1).strip().lower()
    m = re.match(r"(?i)^explain:\s*(.+)$", prompt)
    if m:
        return m.group(1).strip().lower()
    m = re.match(r"(?i)^(?:in your own words,? )?what is (?:an? )?(.+?)\??$", prompt)
    if m:
        return m.group(1).strip().lower().rstrip(".")
    m = re.match(r"(?i)^what does [`']?(.+?)[`']? mean", prompt)
    if m:
        return m.group(1).strip().lower()
    m = re.match(r"(?i)^why does [“\"](.+?)[”\"] matter\??$", prompt)
    if m:
        return m.group(1).strip().lower()
    return prompt.lower()[:80]


def record_attempt(slug: str, question: dict, verdict: str, typed: str = "") -> None:
    if not slug:
        return
    try:
        brains.load_brain(slug)
    except FileNotFoundError:
        return
    memory = load_memory(slug)
    memory["attempts"].append({
        "at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "prompt": (question.get("prompt") or "")[:200],
        "kind": question.get("kind") or "",
        "verdict": verdict,
        "concept": concept_key(question),
        "source": question.get("source") or "",
        "typed": (typed or "")[:160],
    })
    memory["attempts"] = memory["attempts"][-400:]
    save_memory(slug, memory)


def weakness_scores(slug: str) -> dict[str, float]:
    """Higher = needs more drill. Misses weigh more; recent misses weigh most."""
    scores: dict[str, float] = {}
    attempts = load_memory(slug).get("attempts") or []
    n = len(attempts)
    for i, row in enumerate(attempts):
        concept = (row.get("concept") or "").strip().lower()
        if not concept:
            continue
        recency = 0.5 + (i / max(1, n))
        verdict = row.get("verdict") or ""
        delta = {"miss": 1.0, "blank": 0.8, "partial": 0.45, "pass": -0.25}.get(verdict, 0.0)
        scores[concept] = scores.get(concept, 0.0) + delta * recency
    return scores


def weakest_concepts(slug: str, limit: int = 8) -> list[tuple[str, float, int]]:
    scores = weakness_scores(slug)
    counts: dict[str, int] = {}
    for row in load_memory(slug).get("attempts") or []:
        concept = (row.get("concept") or "").strip().lower()
        if concept and row.get("verdict") in {"miss", "blank", "partial"}:
            counts[concept] = counts.get(concept, 0) + 1
    ranked = sorted(scores.items(), key=lambda kv: -kv[1])
    out = []
    for concept, score in ranked:
        if score <= 0:
            continue
        out.append((concept, score, counts.get(concept, 0)))
        if len(out) >= limit:
            break
    return out


def order_quiz_cards(cards: list[tuple], slug: str, count: int) -> list[tuple]:
    weak = weakness_scores(slug)
    decorated = []
    for card in cards:
        term = str(card[0]).strip().lower()
        decorated.append((weak.get(term, 0.0), card))
    decorated.sort(key=lambda x: -x[0])
    n = max(1, count)
    focus = [c for s, c in decorated if s > 0][: max(1, n * 2 // 3)]
    rest = [c for s, c in decorated if c not in focus]
    random.shuffle(rest)
    picked = focus + rest
    return picked[:n] if picked else cards[:n]


def _first_sentences(text: str, n: int = 2, limit: int = 220) -> str:
    raw = EXAM_FILLER.sub(" ", text or "")
    raw = re.sub(r"\s+", " ", raw).strip()
    if not raw:
        return ""
    parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+", raw) if p.strip()]
    parts = [p for p in parts if not META_SENT.search(p)]
    if not parts:
        return ""
    out = " ".join(parts[:n]).strip()
    if len(out) > limit:
        out = out[: limit - 1].rsplit(" ", 1)[0] + "…"
    return out


def _codes(text: str) -> list[str]:
    found = []
    for m in CODE_RE.finditer(text or ""):
        bit = next((g for g in m.groups() if g), m.group(0))
        bit = (bit or "").strip("` ")
        if bit and bit not in found:
            found.append(bit)
    return found


def _display_term(term: str) -> str:
    return re.sub(r"\s*\([^)]*\)\s*", " ", term or "").strip()


def _interesting_code(code: str) -> bool:
    c = (code or "").strip()
    if not c:
        return False
    if re.match(r"^[A-Za-z_]\w*\(\)$", c):
        return False
    if any(ch in c for ch in "[]:+="):
        return True
    return False


def _pretty_term(term: str) -> str:
    t = _display_term(term)
    if not t:
        return t
    if re.search(r"[\[\]()=:`]", t) or t.isupper() or re.search(r"Error$", t):
        return t
    if t.istitle() or re.match(r"^[A-Z][a-z]+(\s+[A-Z][a-z]+)+$", t):
        return t.lower()
    if re.match(r"^[A-Z][a-z]+$", t):
        return t.lower()
    return t


def _indefinite(term: str) -> str:
    t = _pretty_term(term)
    if not t:
        return t
    if re.search(r"[\[\]()=:`]", t) or t[:1].isupper():
        return t
    first = t.split()[0]
    art = "an" if first[:1].lower() in "aeiou" else "a"
    return f"{art} {t}"


def _keys_from(gold: str, extra: str = "") -> list[str]:
    blob = f"{gold} {extra}"
    keys: list[str] = []
    for code in _codes(blob):
        keys.append(code.lower())
    for m in re.finditer(r"\b[a-z][a-z0-9]*(?:-[a-z0-9]+)+\b", (gold or "").lower()):
        keys.append(m.group(0))
    for w in _tokens(gold):
        if w in KEY_STOP or len(w) < 4:
            continue
        keys.append(w)
    out: list[str] = []
    seen = set()
    for k in keys:
        if k in seen:
            continue
        seen.add(k)
        out.append(k)
        if len(out) >= 6:
            break
    return out


def _skip_term(term: str) -> bool:
    t = _display_term(term).strip().lower()
    if len(t) < 3 or len(t) > 48:
        return True
    try:
        from .cortex import GENERIC_HUBS

        if t in GENERIC_HUBS:
            return True
    except Exception:
        pass
    return False


def _skip_heading(heading: str) -> bool:
    h = (heading or "").strip()
    if len(h) < 3 or len(h) > 72:
        return True
    if FLUFF_HEAD.search(h):
        return True
    if h.lower().startswith(("this ", "the lecture", "example setup")):
        return True
    return False


def _term_question(term: str, definition: str, source: str) -> dict | None:
    if _skip_term(term) or len((definition or "").strip()) < 24:
        return None
    gold = _first_sentences(definition, 2, 200)
    if len(gold) < 24:
        return None
    shown = _pretty_term(term)
    if _codes(shown) or re.search(r"[\[\]+=]", shown):
        prompt = (
            f"What does `{shown}` mean in Python? "
            f"Say what each part does — one or two sentences."
        )
    else:
        prompt = f"What is {_indefinite(shown)}? One or two sentences, in your own words."
    keys = _keys_from(gold, shown)
    if len(keys) < 2 and not _codes(shown):
        return None
    return {
        "kind": "term",
        "prompt": prompt,
        "answer": gold,
        "source": source,
        "timestamp": "",
        "concept": shown,
        "keys": keys,
    }


def _already_question(text: str) -> str | None:
    h = (text or "").strip()
    if not h:
        return None
    if h.endswith("?"):
        return h
    if re.match(r"(?i)^(what|why|how|when|where|which)\b", h):
        return h.rstrip(".") + "?"
    return None


def _moment_question(heading: str, insight: str, source: str, timestamp: str) -> dict | None:
    if _skip_heading(heading):
        return None
    gold = _first_sentences(insight, 2, 200)
    if len(gold) < 24:
        if re.search(r"(?i)\b(must|always|never|inclusive|exclusive|first parameter)\b", heading):
            gold = heading.rstrip(".").strip() + "."
        else:
            return None
    codes = [c for c in _codes(heading) if _interesting_code(c)]
    low = heading.lower()
    asked = _already_question(heading)
    if re.search(r"(?i)self.*first parameter", heading):
        prompt = "In a Python instance method, where must `self` go in the parameter list?"
        gold = "`self` must be the first parameter of the method."
    elif asked:
        prompt = asked
    elif codes:
        prompt = (
            f"What does `{codes[0]}` do? Name the result (or the gotcha) from lecture — "
            f"one or two sentences."
        )
    elif "+=" in heading or "concat" in low:
        prompt = (
            "What does `s += t` do? Write the long form (`s = …`) and what happens to the string."
        )
    elif "acquire" in low:
        prompt = (
            "When do you acquire a lock/mutex, and what goes wrong if you touch "
            "shared state first? One or two sentences."
        )
    elif "index" in low:
        prompt = (
            "Which index is the first character of a string or list, and what counting "
            "mistake do exams trap?"
        )
    else:
        prompt = (
            f"{heading} — what is the actual rule, in one sentence?"
        )
    keys = _keys_from(gold, heading)
    if len(keys) < 1:
        return None
    return {
        "kind": "moment",
        "prompt": prompt,
        "answer": gold,
        "source": source,
        "timestamp": timestamp,
        "concept": heading,
        "keys": keys,
    }


def _notes_question(heading: str, content: str, source: str) -> dict | None:
    if _skip_heading(heading) or len((content or "").strip()) < 40:
        return None
    gold = _first_sentences(content, 2, 220)
    if len(gold) < 40:
        return None
    asked = _already_question(heading)
    shown = _pretty_term(heading)
    if asked:
        prompt = asked
    else:
        prompt = (
            f"In one or two sentences, explain {shown}. "
            f"State the rule — a tiny example is fine."
        )
    keys = _keys_from(gold, heading)
    if len(keys) < 2:
        return None
    return {
        "kind": "notes",
        "prompt": prompt,
        "answer": gold,
        "source": source,
        "timestamp": "",
        "concept": heading,
        "keys": keys,
    }


def _study_question(item: str, source: str) -> dict | None:
    text = re.sub(r"\s+", " ", (item or "").strip())
    if "?" not in text and not re.match(r"(?i)^(given |what |if |predict |trace )", text):
        return None
    if len(text) > 220 or len(text) < 24:
        return None
    # Keep the question the lecture already wrote; gold is the question itself
    # so auto-grade looks for numbers/code the prompt mentioned.
    prompt = text.split(" This ")[0].strip()
    return {
        "kind": "study",
        "prompt": prompt if prompt.endswith("?") else prompt,
        "answer": prompt,
        "source": source,
        "timestamp": "",
        "concept": prompt[:60],
        "keys": _keys_from(prompt),
        "ungraded_ok": True,
    }


def _expand_tokens(tokens: set[str]) -> set[str]:
    out = set(tokens)
    for w in list(tokens):
        out.add(w + "s")
        if w.endswith("s") and len(w) > 3:
            out.add(w[:-1])
        if w.endswith("es") and len(w) > 4:
            out.add(w[:-2])
        compact = w.replace("-", "")
        if compact != w:
            out.add(compact)
    for group in SYNONYM_GROUPS:
        if out & group:
            out |= group
    return out


def _norm_blob(text: str) -> str:
    s = (text or "").lower()
    s = s.replace("+=", " plus-equals ")
    s = s.replace("zero-based", " zerobased zero based ")
    s = re.sub(r"[`'\"]", " ", s)
    return " " + re.sub(r"\s+", " ", s) + " "


def _key_hit(key: str, blob: str, got: set[str]) -> bool:
    k = (key or "").strip().lower()
    if not k:
        return False
    if k in blob or k.replace(" ", "") in blob.replace(" ", ""):
        return True
    parts = [p for p in re.findall(r"[a-z0-9]+", k) if p not in KEY_STOP]
    if parts and all(p in got for p in parts):
        return True
    return False


def build_exam(
    records: list[dict],
    count: int = 8,
    rng: random.Random | None = None,
    brain: str | None = None,
    prefer: list[str] | None = None,
) -> list[dict]:
    """Build short, specific questions from recaps. No network."""
    rng = rng or random.Random()
    pool: list[dict] = []
    seen = set()

    def add(q: dict | None):
        if not q:
            return
        key = (q.get("concept") or q["prompt"]).strip().lower()
        if not q["prompt"].strip() or not q["answer"].strip() or key in seen:
            return
        seen.add(key)
        pool.append(q)

    for rec in records:
        analysis = rec.get("analysis") or {}
        title = rec.get("title") or rec.get("source") or "recap"
        for term, definition in library._terms_from(rec):
            if definition.startswith("(from the study"):
                continue
            add(_term_question(term, definition, title))
        for bm in analysis.get("bookmarks") or []:
            if not isinstance(bm, dict):
                continue
            add(_moment_question(
                str(bm.get("heading") or ""),
                str(bm.get("insight") or ""),
                title,
                str(bm.get("timestamp") or ""),
            ))
        for section in analysis.get("detailed_notes") or []:
            if isinstance(section, dict):
                add(_notes_question(
                    str(section.get("heading") or ""),
                    str(section.get("content") or ""),
                    title,
                ))
        for item in analysis.get("study") or []:
            add(_study_question(str(item), title))
    if not pool:
        return []

    prefer_l = [p.strip().lower() for p in (prefer or []) if p and p.strip()]
    weak = weakness_scores(brain) if brain else {}

    def weight(q: dict) -> float:
        key = concept_key(q)
        score = weak.get(key, 0.0)
        blob = f"{q.get('prompt')} {key}".lower()
        if any(p in blob for p in prefer_l):
            score += 5.0
        if q.get("kind") == "term":
            score += 0.4
        if q.get("kind") == "moment" and _codes(q.get("prompt") or ""):
            score += 0.5
        if q.get("kind") == "study":
            score -= 0.2
        return score

    n = max(1, count)
    ranked = sorted(pool, key=weight, reverse=True)
    focus_n = min(len(ranked), max(1, (n * 2 + 2) // 3)) if (weak or prefer_l) else 0
    focus = ranked[:focus_n] if focus_n else []
    by_kind: dict[str, list[dict]] = {"term": [], "moment": [], "notes": [], "study": []}
    for q in pool:
        if q in focus:
            continue
        by_kind.setdefault(q.get("kind") or "term", []).append(q)
    for kind in by_kind:
        rng.shuffle(by_kind[kind])
    quota = [
        ("term", max(1, n * 2 // 5)),
        ("moment", max(1, n * 2 // 5)),
        ("notes", max(0, n // 5)),
        ("study", max(0, n // 5)),
    ]
    picked: list[dict] = []
    seen_p: set[str] = set()

    def take(q: dict) -> bool:
        k = q["prompt"].lower()
        if k in seen_p:
            return False
        seen_p.add(k)
        picked.append(q)
        return True

    for q in focus:
        if len(picked) >= n:
            break
        take(q)
    for kind, want in quota:
        got = sum(1 for q in picked if q.get("kind") == kind)
        while got < want and by_kind.get(kind) and len(picked) < n:
            q = by_kind[kind].pop()
            if take(q):
                got += 1
    leftover = [q for qs in by_kind.values() for q in qs]
    rng.shuffle(leftover)
    for q in leftover:
        if len(picked) >= n:
            break
        take(q)
    rng.shuffle(picked)
    return picked[:n]


def _grade_offline(question: dict, typed: str) -> dict:
    expected_raw = question.get("answer") or ""
    typed_l = typed.strip().lower()
    blob = _norm_blob(typed)
    got = _expand_tokens(set(_tokens(typed)))
    if not typed.strip():
        return {"score": 0.0, "verdict": "blank", "overlap": 0, "because": "empty answer"}
    if not expected_raw.strip():
        return {"score": 0.5, "verdict": "ungraded", "overlap": 0, "because": ""}
    if typed_l in expected_raw.lower() or expected_raw.lower() in typed_l:
        return {"score": 1.0, "verdict": "pass", "overlap": 8, "because": "matches the lecture wording"}
    keys = [k for k in (question.get("keys") or _keys_from(expected_raw)) if k]
    if not keys:
        keys = [w for w in _tokens(expected_raw) if w not in KEY_STOP][:5]
    hits = [k for k in keys if _key_hit(k, blob, got)]
    strong = [k for k in hits if len(k) > 4 or any(ch in k for ch in "[]+=()")]
    denom = max(1, min(len(keys), 5))
    score = len(hits) / denom
    because = ""
    if hits:
        because = "you hit: " + ", ".join(hits[:4])
    missed = [k for k in keys if k not in hits][:3]
    if missed:
        because = (because + " · " if because else "") + "still needed: " + ", ".join(missed)
    if (len(strong) >= 2) or (score >= 0.45 and (strong or len(hits) >= 2)):
        verdict = "pass"
    elif score >= 0.25 or strong:
        verdict = "partial"
    elif question.get("ungraded_ok") and len(_tokens(typed)) >= 4:
        verdict = "partial"
        because = (because + " · " if because else "") + "practice item — check the gold"
    else:
        verdict = "miss"
    return {
        "score": round(score, 2),
        "verdict": verdict,
        "overlap": len(hits),
        "because": because.strip(" ·"),
    }


def _llm_grading_enabled() -> bool:
    raw = (os.environ.get("CATCHMEUP_EXAM_LLM") or "").strip().lower()
    if raw in {"0", "false", "no", "off"}:
        return False
    if raw in {"1", "true", "yes", "on"}:
        return True
    try:
        from .providers import active_provider, resolve_api_key

        p = active_provider()
        return bool(resolve_api_key(p)) or p == "ollama"
    except Exception:
        return False


def _grade_llm(question: dict, typed: str) -> dict | None:
    from .providers import complete_json

    prompt = (
        "Return ONLY JSON: {\"verdict\": \"pass|partial|miss\", \"score\": 0.0, "
        "\"because\": \"one short clause\"}\n"
        "You are grading a short student answer against a lecture gold answer. "
        "Accept paraphrases and synonyms. Pass if the student got the actual rule, "
        "even if wording differs. Partial if they got one key piece. Miss if they "
        "are off-topic or empty of the idea. Do not require memorized phrasing.\n\n"
        f"Question: {question.get('prompt')}\n"
        f"Gold: {question.get('answer')}\n"
        f"Student: {typed}"
    )
    data = complete_json(prompt, log=lambda *_: None, retries=1)
    verdict = str(data.get("verdict") or "").strip().lower()
    if verdict not in {"pass", "partial", "miss"}:
        return None
    try:
        score = float(data.get("score"))
    except (TypeError, ValueError):
        score = {"pass": 0.8, "partial": 0.4, "miss": 0.0}[verdict]
    return {
        "score": round(min(1.0, max(0.0, score)), 2),
        "verdict": verdict,
        "overlap": {"pass": 5, "partial": 2, "miss": 0}[verdict],
        "because": str(data.get("because") or "").strip()[:160],
    }


def grade_answer(question: dict, typed: str, use_llm: bool | None = False) -> dict:
    """Grade a short answer. Offline keys first; optional LLM for paraphrases."""
    offline = _grade_offline(question, typed)
    want_llm = _llm_grading_enabled() if use_llm is None else use_llm
    if not want_llm:
        return offline
    if offline["verdict"] == "pass" and offline["score"] >= 0.7:
        return offline
    if offline["verdict"] == "blank" or len(_tokens(typed or "")) < 3:
        return offline
    try:
        brains.load_env()
        llm = _grade_llm(question, typed)
    except Exception:
        llm = None
    return llm or offline


def format_exam(questions: list[dict], answers: bool = False) -> str:
    if not questions:
        return "No exam material yet. Recap a lecture into this brain first."
    lines = [f"CatchMeUp exam — {len(questions)} question(s)", ""]
    for i, q in enumerate(questions, 1):
        where = q.get("source") or ""
        ts = f"  [{q['timestamp']}]" if q.get("timestamp") else ""
        lines.append(f"{i}. {q['prompt']}")
        lines.append(f"    {where}{ts}")
        if answers:
            lines.append(f"    → {q['answer']}")
        lines.append("")
    if not answers:
        lines.append("Reveal answers:  ./catchup exam NAME --print --answers")
        lines.append("Take it live:    ./catchup exam NAME")
        lines.append("Tonight's misses: ./catchup drill NAME")
        lines.append("Hear a moment:   ./catchup clip NAME <words from the question>")
    return "\n".join(lines).rstrip() + "\n"


def _run_questions(questions: list[dict], brain: str | None, heading: str) -> None:
    print(f"{heading}  q = quit.\n")
    passed = 0
    attempted = 0
    missed: list[dict] = []
    from . import viz

    for i, q in enumerate(questions, 1):
        print(f"[{i}/{len(questions)}]  {q['prompt']}")
        src = q.get("source") or ""
        if src:
            print(f"         lecture: {src}")
        try:
            typed = input("         your answer: ").strip()
        except EOFError:
            print()
            break
        if typed.lower() in {"q", "quit"}:
            break
        attempted += 1
        result = grade_answer(q, typed, use_llm=_llm_grading_enabled())
        mark = viz.verdict_mark(result["verdict"])
        gold = (q.get("answer") or "")[:220]
        print(f"         {mark}  {gold}")
        because = (result.get("because") or "").strip()
        if because and result["verdict"] != "pass":
            print(f"         {because}")
        if brain:
            record_attempt(brain, q, result["verdict"], typed)
        if result["verdict"] == "pass":
            passed += 1
        else:
            missed.append(q)
        print()
    print(viz.exam_card(passed, attempted or 0, len(questions)))
    if brain:
        print(f"Drill misses: ./catchup drill {brain}")
        print(f"Go deeper:    ./catchup think {brain} <the one you missed>")
        print(f"Hear it:      ./catchup clip {brain} <term>")
        if missed:
            concept = concept_key(missed[0])
            print(f"Start here:   ./catchup clip {brain} {concept}")


def cmd_exam(brain: str | None, count: int, print_only: bool, show_answers: bool, drill: bool = False):
    if brain:
        brains.load_brain(brain)
    rows = _records(brain)
    if not rows:
        print("Nothing to examine. Recap a lecture first:")
        print("  ./catchup lecture FILE")
        print("  ./catchup into cs61a FILE")
        sys.exit(1)
    prefer = []
    heading = f"Exam — {count} questions from your recaps."
    if drill and brain:
        weak = weakest_concepts(brain, limit=max(4, count))
        prefer = [c for c, _, _ in weak]
        if not prefer:
            print("No misses saved yet. Take an exam first:")
            print(f"  ./catchup exam {brain}")
            sys.exit(1)
        print("Weak spots from earlier exams:\n")
        for concept, _score, n_miss in weak:
            print(f"  • {concept}  ({n_miss} miss/partial)")
        print()
        heading = f"Drill — {count} questions on what you missed."
    questions = build_exam(rows, count=count, brain=brain, prefer=prefer)
    if not questions:
        print("Recaps have no terms / study items / notes to examine yet.")
        sys.exit(1)
    if print_only:
        print(format_exam(questions, answers=show_answers))
        return
    _run_questions(questions, brain, heading)


def cmd_drill(brain: str, count: int = 6):
    cmd_exam(brain, count=count, print_only=False, show_answers=False, drill=True)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="catchup-exam")
    parser.add_argument("--brain")
    parser.add_argument("-n", "--count", type=int, default=8)
    parser.add_argument("--print", dest="print_only", action="store_true")
    parser.add_argument("--answers", action="store_true")
    parser.add_argument("--drill", action="store_true")
    args = parser.parse_args(argv)
    cmd_exam(args.brain, args.count, args.print_only, args.answers, drill=args.drill)


if __name__ == "__main__":
    main()
