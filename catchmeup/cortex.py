#!/usr/bin/env python3
"""Cortex: inspectable concept graph + multi-pass analysis.

This is not a trained neural net. It is the architecture brains actually use:
  episodes (recaps) → concepts (neurons) → weighted links (synapses)
  → spreading activation → multi-hop evidence → critique → synthesis.

The LLM is the inner voice. The graph is the memory.
"""
from __future__ import annotations

import json
import re
import sys
from collections import defaultdict, deque
from pathlib import Path

from . import brains
from .providers import complete_json, complete_text

CORTEX_FILE = "cortex.json"


def cortex_path(slug: str) -> Path:
    return brains.brain_dir(slug) / CORTEX_FILE


def _norm(name: str) -> str:
    s = re.sub(r"\s+", " ", (name or "").strip().lower())
    return s[:80]


NOTE_MARKER = "catchmeup-concept"
HUB_KINDS = {"term", "topic"}
NOTE_KINDS = {"term", "topic", "moment", "person", "study"}
EDGE_LABEL = {
    "with": "with",
    "heard-at": "heard at",
    "exam": "exam",
    "owns": "owns",
}
# Single-word hubs that show up in every CS lecture and drown the graph.
GENERIC_HUBS = {
    "class", "classes", "method", "methods", "function", "functions",
    "object", "objects", "variable", "variables", "value", "values",
    "code", "example", "examples", "python", "program", "programs",
    "data", "type", "types", "item", "items", "self", "none",
    "return", "print", "input", "output", "file", "files", "error",
    "errors", "test", "tests", "loop", "loops", "list", "lists",
    "string", "strings", "number", "numbers", "true", "false",
    "thing", "things", "way", "case", "cases", "part", "parts",
}
_QUESTION_HEAD = re.compile(
    r"^(what|why|how|when|where|explain|describe|discuss|compare)\b",
    re.I,
)


def empty_cortex() -> dict:
    return {"nodes": {}, "edges": {}, "aliases": {}}


def load_cortex(slug: str) -> dict:
    path = cortex_path(slug)
    if not path.is_file():
        return empty_cortex()
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        return empty_cortex()
    data.setdefault("nodes", {})
    data.setdefault("edges", {})
    data.setdefault("aliases", {})
    return data


def save_cortex(slug: str, cortex: dict) -> None:
    brains.brain_dir(slug).mkdir(parents=True, exist_ok=True)
    cortex_path(slug).write_text(json.dumps(cortex, indent=2) + "\n")


def _edge_key(a: str, b: str) -> str:
    x, y = sorted((_norm(a), _norm(b)))
    return f"{x}|{y}"


def _deplural(nid: str) -> str | None:
    if " " in nid:
        words = nid.split()
        last = _deplural(words[-1])
        if last:
            return " ".join(words[:-1] + [last])
        return None
    if nid.endswith("es") and len(nid) > 4:
        return nid[:-2]
    if nid.endswith("s") and not nid.endswith("ss") and len(nid) > 3:
        return nid[:-1]
    return None


def _remember_alias(node: dict, alias: str) -> None:
    if not alias or alias == node.get("id"):
        return
    als = node.setdefault("aliases", [])
    if alias not in als:
        als.append(alias)
        node["aliases"] = als[-8:]


def resolve_id(cortex: dict, name: str) -> str:
    """Map a raw label onto an existing neuron when it is clearly the same idea."""
    nid = _norm(name)
    aliases = cortex.setdefault("aliases", {})
    if not nid:
        return nid
    if nid in aliases and aliases[nid] in cortex.get("nodes", {}):
        return aliases[nid]
    if nid in cortex.get("nodes", {}):
        return nid
    parent = _deplural(nid)
    if parent and parent in cortex.get("nodes", {}):
        aliases[nid] = parent
        _remember_alias(cortex["nodes"][parent], nid)
        return parent
    for existing, node in cortex.get("nodes", {}).items():
        if _deplural(existing) == nid:
            aliases[nid] = existing
            _remember_alias(node, nid)
            return existing
    return nid


def _bump_node(
    cortex: dict,
    name: str,
    kind: str,
    definition: str,
    episode: str,
    when: str = "",
) -> str:
    nid = resolve_id(cortex, name)
    if not nid or len(nid) < 2:
        return ""
    node = cortex["nodes"].setdefault(
        nid,
        {
            "id": nid,
            "kind": kind,
            "definition": "",
            "weight": 0,
            "episodes": [],
            "aliases": [],
            "moments": [],
        },
    )
    node["weight"] = int(node.get("weight") or 0) + 1
    if definition and len(definition) > len(node.get("definition") or ""):
        node["definition"] = definition[:400]
    if episode and episode not in node["episodes"]:
        node["episodes"].append(episode)
        node["episodes"] = node["episodes"][-24:]
    if when:
        node.setdefault("first_seen", when)
        node["last_seen"] = when
    raw = _norm(name)
    if raw and raw != nid:
        cortex.setdefault("aliases", {})[raw] = nid
        _remember_alias(node, raw)
    return nid


def _bump_edge(
    cortex: dict,
    a: str,
    b: str,
    episode: str,
    kind: str = "with",
    when: str = "",
) -> None:
    a, b = _norm(a), _norm(b)
    if not a or not b or a == b:
        return
    if a not in cortex.get("nodes", {}) or b not in cortex.get("nodes", {}):
        return
    key = _edge_key(a, b)
    edge = cortex["edges"].setdefault(
        key,
        {
            "a": min(a, b),
            "b": max(a, b),
            "weight": 0,
            "episodes": [],
            "kind": kind,
            "kinds": {},
        },
    )
    edge["weight"] = int(edge.get("weight") or 0) + 1
    kinds = edge.setdefault("kinds", {})
    kinds[kind] = int(kinds.get(kind) or 0) + 1
    edge["kind"] = max(kinds, key=kinds.get)
    if episode and episode not in edge["episodes"]:
        edge["episodes"].append(episode)
        edge["episodes"] = edge["episodes"][-16:]
    if when:
        edge.setdefault("first_seen", when)
        edge["last_seen"] = when


def _add_moment(node: dict, timestamp: str, heading: str, episode: str, insight: str) -> None:
    if not node:
        return
    moments = node.setdefault("moments", [])
    ts = (timestamp or "").strip()
    head = (heading or "").strip()
    key = (ts, head, episode)
    if any((m.get("timestamp"), m.get("heading"), m.get("episode")) == key for m in moments):
        return
    moments.append({
        "timestamp": ts,
        "heading": head,
        "episode": episode,
        "insight": (insight or "")[:280],
    })
    node["moments"] = moments[-12:]


def is_generic_hub(nid: str) -> bool:
    return _norm(nid) in GENERIC_HUBS


def _keep_moment_node(heading: str) -> bool:
    """Bookmark titles become neurons only when they look like a concept name."""
    h = (heading or "").strip()
    if not h or len(h) > 48:
        return False
    words = h.split()
    if len(words) > 6 or h.endswith("?"):
        return False
    if _QUESTION_HEAD.match(h):
        return False
    return True


def _mentioned(text: str, term_ids: list[str]) -> list[str]:
    blob = _norm(text)
    if not blob:
        return []
    hits = []
    for tid in sorted(term_ids, key=len, reverse=True):
        if not tid:
            continue
        stem = _deplural(tid) or tid
        pattern = re.escape(tid)
        if stem != tid:
            pattern = rf"(?:{pattern}|{re.escape(stem)})"
        if re.search(rf"(?:^|\s){pattern}(?:es|s)?(?:\s|$)", blob):
            hits.append(tid)
    return hits


def _add_exam_prompt(node: dict, item: str) -> None:
    if not node:
        return
    text = re.sub(r"\s+", " ", str(item or "").strip())[:240]
    if not text:
        return
    prompts = node.setdefault("exam_prompts", [])
    if text not in prompts:
        prompts.append(text)
        node["exam_prompts"] = prompts[-8:]


def ingest_recap(slug: str, rec: dict) -> dict:
    """Update the cortex from one recap (Hebbian: fire together → wire together)."""
    cortex = load_cortex(slug)
    analysis = rec.get("analysis") or {}
    episode = rec.get("title") or rec.get("source") or "episode"
    when = rec.get("recorded_at") or rec.get("processed_at") or ""
    names: list[tuple[str, str, str]] = []  # name, kind, definition

    for term in analysis.get("terms") or []:
        if isinstance(term, dict) and term.get("term"):
            names.append((term["term"], "term", str(term.get("definition") or "")))
        elif term:
            names.append((str(term), "term", ""))
    for bm in analysis.get("bookmarks") or []:
        if isinstance(bm, dict) and bm.get("heading") and _keep_moment_node(str(bm["heading"])):
            names.append((bm["heading"], "moment", str(bm.get("insight") or "")))
    for section in analysis.get("detailed_notes") or []:
        if isinstance(section, dict) and section.get("heading"):
            names.append((section["heading"], "topic", str(section.get("content") or "")[:240]))
    for item in analysis.get("action_items") or []:
        names.append((str(item)[:80], "action", str(item)))
    for sp in analysis.get("speakers") or []:
        if isinstance(sp, dict):
            label = sp.get("name") or sp.get("label")
            if label and str(label).strip().lower() not in {"unknown", "n/a", "none", "?"}:
                names.append((str(label), "person", str(sp.get("said") or "")))
        elif sp:
            names.append((str(sp)[:80], "person", ""))

    seen: list[str] = []
    kinds_by_id: dict[str, str] = {}
    for name, kind, definition in names:
        nid = _bump_node(cortex, name, kind, definition, episode, when=when)
        if not nid or nid in seen:
            continue
        seen.append(nid)
        kinds_by_id[nid] = kind

    term_ids = [
        nid for nid in seen
        if (cortex["nodes"].get(nid) or {}).get("kind") == "term"
    ]

    for bm in analysis.get("bookmarks") or []:
        if not isinstance(bm, dict) or not bm.get("heading"):
            continue
        heading = str(bm.get("heading") or "")
        insight = str(bm.get("insight") or "")
        ts = str(bm.get("timestamp") or "")
        moment_id = resolve_id(cortex, heading)
        if moment_id in cortex["nodes"]:
            _add_moment(cortex["nodes"][moment_id], ts, heading, episode, insight)
        for tid in _mentioned(f"{heading} {insight}", term_ids):
            if tid in cortex["nodes"]:
                _add_moment(cortex["nodes"][tid], ts, heading, episode, insight)
            if moment_id:
                _bump_edge(cortex, moment_id, tid, episode, kind="heard-at", when=when)

    for item in analysis.get("study") or []:
        mentioned = _mentioned(str(item), term_ids)
        for tid in mentioned:
            if tid in cortex["nodes"]:
                _add_exam_prompt(cortex["nodes"][tid], str(item))
        for i, a in enumerate(mentioned):
            for b in mentioned[i + 1 :]:
                _bump_edge(cortex, a, b, episode, kind="exam", when=when)

    people = [nid for nid, k in kinds_by_id.items() if k == "person"]
    actions = [nid for nid, k in kinds_by_id.items() if k == "action"]
    for person in people:
        ptoks = set(brains._tokens(person))
        for action in actions:
            atoks = set(brains._tokens(action))
            if ptoks and ptoks & atoks:
                _bump_edge(cortex, person, action, episode, kind="owns", when=when)

    hubs = [
        nid for nid in seen
        if (cortex["nodes"].get(nid) or {}).get("kind") in HUB_KINDS
        and not is_generic_hub(nid)
    ][:10]
    for i, a in enumerate(hubs):
        for b in hubs[i + 1 :]:
            _bump_edge(cortex, a, b, episode, kind="with", when=when)

    save_cortex(slug, cortex)
    write_cortex_index(slug, cortex)
    write_concept_notes(slug, cortex)
    from . import graph as graph_mod
    graph_mod.write_graph(slug, cortex)
    return cortex


def rebuild(slug: str) -> dict:
    cortex = empty_cortex()
    save_cortex(slug, cortex)
    for rec in brains.iter_brain_records(slug):
        ingest_recap(slug, rec)
    cortex = load_cortex(slug)
    write_cortex_index(slug, cortex)
    write_concept_notes(slug, cortex)
    from . import graph as graph_mod
    graph_mod.write_graph(slug, cortex)
    return cortex


def neighbors(cortex: dict, node_id: str) -> list[tuple[str, int]]:
    nid = _norm(node_id)
    out = []
    for edge in cortex.get("edges", {}).values():
        if edge["a"] == nid:
            out.append((edge["b"], int(edge.get("weight") or 1)))
        elif edge["b"] == nid:
            out.append((edge["a"], int(edge.get("weight") or 1)))
    out.sort(key=lambda x: -x[1])
    return out


def synapses(cortex: dict, node_id: str, limit: int = 12) -> list[dict]:
    nid = resolve_id(cortex, node_id) or _norm(node_id)
    out = []
    nodes = cortex.get("nodes") or {}
    for edge in cortex.get("edges", {}).values():
        other = None
        if edge.get("a") == nid:
            other = edge.get("b")
        elif edge.get("b") == nid:
            other = edge.get("a")
        if not other:
            continue
        out.append({
            "id": other,
            "weight": int(edge.get("weight") or 1),
            "kind": edge.get("kind") or "with",
            "label": EDGE_LABEL.get(edge.get("kind") or "with", edge.get("kind") or "with"),
            "node_kind": (nodes.get(other) or {}).get("kind"),
            "episodes": edge.get("episodes") or [],
        })
    out.sort(key=lambda x: -x["weight"])
    return out[:limit]


def subgraph(cortex: dict, center: str, limit: int = 10) -> dict:
    center = resolve_id(cortex, center) or _norm(center)
    ids = {center}
    for syn in synapses(cortex, center, limit=limit):
        ids.add(syn["id"])
    return {
        "nodes": {k: v for k, v in (cortex.get("nodes") or {}).items() if k in ids},
        "edges": {
            k: e for k, e in (cortex.get("edges") or {}).items()
            if e.get("a") in ids and e.get("b") in ids
        },
        "aliases": cortex.get("aliases") or {},
    }


def find_node(cortex: dict, query: str) -> str | None:
    q = _norm(query)
    nodes = cortex.get("nodes") or {}
    if not q or not nodes:
        return None
    aliases = cortex.get("aliases") or {}
    if q in nodes:
        return q
    if q in aliases and aliases[q] in nodes:
        return aliases[q]
    resolved = resolve_id(cortex, query)
    if resolved in nodes:
        return resolved
    for nid in nodes:
        if q == nid or q in nid or nid in q:
            return nid
    qtoks = set(brains._tokens(query))
    if not qtoks:
        return None
    best, score = None, 0
    for nid, node in nodes.items():
        ntoks = set(brains._tokens(nid + " " + (node.get("definition") or "")))
        overlap = len(qtoks & ntoks)
        extra = 2 if any(t in nid for t in qtoks) else 0
        mag = overlap + extra
        if mag > score:
            best, score = nid, mag
    return best if score else None


def shortest_path(cortex: dict, src: str, dst: str) -> list[dict]:
    """BFS through synapses. Each hop is {from, to, kind, weight}."""
    src_id = find_node(cortex, src)
    dst_id = find_node(cortex, dst)
    if not src_id or not dst_id:
        return []
    if src_id == dst_id:
        return []
    adj: dict[str, list[tuple[str, dict]]] = defaultdict(list)
    for edge in (cortex.get("edges") or {}).values():
        a, b = edge.get("a"), edge.get("b")
        if a and b:
            adj[a].append((b, edge))
            adj[b].append((a, edge))
    q = deque([src_id])
    prev: dict[str, tuple[str, dict] | None] = {src_id: None}
    while q:
        cur = q.popleft()
        if cur == dst_id:
            break
        for nb, edge in adj.get(cur, []):
            if nb in prev:
                continue
            prev[nb] = (cur, edge)
            q.append(nb)
    if dst_id not in prev:
        return []
    hops = []
    cur = dst_id
    while cur != src_id:
        parent, edge = prev[cur]  # type: ignore[misc]
        hops.append({
            "from": parent,
            "to": cur,
            "kind": edge.get("kind") or "with",
            "weight": int(edge.get("weight") or 1),
            "label": EDGE_LABEL.get(edge.get("kind") or "with", "with"),
        })
        cur = parent
    hops.reverse()
    return hops


def activate(slug: str, query: str, hops: int = 2, top: int = 12) -> list[dict]:
    """Spreading activation: query lights up concepts, then their neighbors."""
    cortex = load_cortex(slug)
    nodes = cortex.get("nodes") or {}
    if not nodes:
        rebuild(slug)
        cortex = load_cortex(slug)
        nodes = cortex.get("nodes") or {}
    q = set(brains._tokens(query))
    energy: dict[str, float] = defaultdict(float)
    for nid, node in nodes.items():
        ntoks = set(brains._tokens(nid + " " + (node.get("definition") or "")))
        overlap = len(q & ntoks)
        if overlap:
            energy[nid] += overlap * (1 + 0.15 * int(node.get("weight") or 1))
    # spread
    for _ in range(max(1, hops)):
        extra = defaultdict(float)
        for nid, mag in list(energy.items()):
            if mag < 0.4:
                continue
            for nb, w in neighbors(cortex, nid)[:8]:
                extra[nb] += 0.45 * mag * (w ** 0.5)
        for nid, mag in extra.items():
            energy[nid] += mag
    ranked = sorted(energy.items(), key=lambda kv: -kv[1])[:top]
    fired = []
    for nid, mag in ranked:
        node = nodes.get(nid) or {"id": nid}
        fired.append({
            "id": nid,
            "kind": node.get("kind"),
            "definition": node.get("definition"),
            "weight": node.get("weight"),
            "activation": round(mag, 3),
            "episodes": node.get("episodes") or [],
            "neighbors": [n for n, _ in neighbors(cortex, nid)[:6]],
        })
    return fired


def _pack_activated(slug: str, question: str, fired: list[dict]) -> str:
    records = brains.evidence_records(slug)
    # Prefer recaps whose titles show up on fired concepts.
    episode_hits = []
    for node in fired:
        episode_hits.extend(node.get("episodes") or [])
    boosted = []
    rest = []
    for rec in records:
        title = rec.get("title") or rec.get("source") or ""
        if any(ep.lower() in title.lower() or title.lower() in ep.lower() for ep in episode_hits if ep):
            boosted.append(rec)
        else:
            rest.append(rec)
    ordered = boosted + rest
    hits = brains.retrieve(question, ordered, k=10)
    concept_block = "Activated concepts:\n"
    for node in fired:
        concept_block += (
            f"- {node['id']} ({node.get('kind')}, fire={node.get('activation')}) "
            f"episodes={', '.join(node.get('episodes')[:4])}\n"
            f"  {node.get('definition') or ''}\n"
            f"  linked: {', '.join(node.get('neighbors') or [])}\n"
        )
    if hits:
        evidence = brains.format_evidence(hits, budget=36000)
        return concept_block + "\nSources from episodes:\n" + evidence
    return concept_block + "\nSources from episodes:\n(none matched — do not invent)\n"


def think(slug: str, question: str, log=print, closed: bool | None = None) -> str:
    """Multi-pass analysis: decompose → activate → evidence → critique → synthesize."""
    brain = brains.load_brain(slug)
    records = brains.evidence_records(slug)
    if not records:
        return (
            f"Brain `{slug}` has no recaps yet. "
            f"Run: ./catchup into {slug} FILE"
        )
    if not load_cortex(slug).get("nodes"):
        log("Building cortex from recaps...")
        rebuild(slug)

    from . import viz

    closed = brains.want_closed(closed)
    if closed and not activate(slug, question, hops=2, top=8) and not brains.retrieve(question, records):
        return brains.not_in_notes(slug, question)

    log(viz.pass_line(1, 4, "decompose the task"))
    known = [
        n["id"]
        for n in sorted(
            (load_cortex(slug).get("nodes") or {}).values(),
            key=lambda node: -int(node.get("weight") or 0),
        )
    ][:80]
    if closed:
        decompose_extra = (
            "Prefer concept names from this brain's known list. Do not invent topics "
            "from general knowledge or another course. If the task is outside this brain, "
            "set task_type to other and say so in a subquestion.\n"
        )
        decompose_system = brains.CLOSED_BOOK_SYSTEM
    else:
        decompose_extra = (
            "Prefer concept names from this brain's known list for what the recordings "
            "cover. Extra concepts needed to teach a gap are allowed.\n"
        )
        decompose_system = brains.NOTES_FIRST_SYSTEM
    plan = complete_json(
        "Return ONLY JSON with this shape:\n"
        '{"task_type": "explain|compare|exam|decide|plan|other",'
        ' "subquestions": ["...", "..."],'
        ' "concepts": ["short concept names"]}\n'
        "Decompose this user task into 3-6 subquestions and the key concepts.\n"
        f"{decompose_extra}"
        f"Known concepts: {json.dumps(known)}\n"
        f"Task: {question}",
        log=log,
        system=decompose_system,
    )
    subqs = plan.get("subquestions") or [question]
    concepts = plan.get("concepts") or []
    task_type = plan.get("task_type") or "explain"

    seed = question + " " + " ".join(concepts) + " " + " ".join(subqs)
    fired = activate(slug, seed, hops=2, top=14)
    packed = _pack_activated(slug, seed, fired)
    panel = viz.activation_panel(fired)
    if panel:
        log(panel)

    log(viz.pass_line(2, 4, "gather cited claims"))
    evidence = complete_json(
        "Return ONLY JSON:\n"
        '{"claims": [{"claim": "...", "because": "...", "source": "recap title or timestamp", "confidence": "high|medium|low"}],'
        ' "missing": ["what the recordings do not cover"]}\n'
        f"You are {brain.get('name')} ({brain.get('kind')}). "
        "Extract concrete claims that answer the subquestions. "
        "Use ONLY the activated concepts and numbered sources. Do not invent. "
        "If a subquestion is not in the sources, put it in missing — do not answer from general knowledge.\n\n"
        f"Task type: {task_type}\nSubquestions: {json.dumps(subqs)}\n\n{packed}",
        log=log,
        system=brains.CLOSED_BOOK_SYSTEM,
    )

    log(viz.pass_line(3, 4, "critique contradictions and gaps"))
    critique = complete_json(
        "Return ONLY JSON:\n"
        '{"tensions": ["where claims disagree or evolved over time"],'
        ' "gaps": ["what we still cannot answer from these recordings"],'
        ' "exam_or_action": ["what to study, decide, or do next"]}\n'
        f"Persona: {brain.get('persona')}\n"
        f"Task: {question}\nClaims: {json.dumps(evidence)}\n"
        "Critique only these claims. Do not introduce facts that are not in Claims.",
        log=log,
        system=brains.CLOSED_BOOK_SYSTEM,
    )

    log(viz.pass_line(4, 4, "synthesize the deep answer"))
    if closed:
        shape = (
            "1. Direct answer\n"
            "2. How the ideas connect in this brain (use the activated concepts)\n"
            "3. Evidence from specific recaps / timestamps\n"
            "4. Tensions, open loops, or likely exam angles\n"
            "5. What to do next\n"
            "If something is not in the recordings, say so plainly. "
            "Do not fill gaps from general knowledge."
        )
        synth_system = brains.CLOSED_BOOK_SYSTEM
    else:
        shape = (
            "1. Direct answer from the recordings\n"
            "2. How the ideas connect in this brain (use the activated concepts)\n"
            "3. Evidence from specific recaps / timestamps\n"
            "4. Tensions, open loops, or likely exam angles\n"
            "5. What to do next\n"
            "6. Beyond the recordings — teach anything in Critique.gaps / Claims.missing. "
            "Label this section. Do not mix it into 1–5."
        )
        synth_system = brains.NOTES_FIRST_SYSTEM
    synthesis = complete_text(
        f"{brain.get('persona')}\n\n"
        f"You are the cortical specialist for **{brain.get('name')}**. "
        f"Write an in-depth analysis the user can act on. Structure it as:\n{shape}\n\n"
        f"User task: {question}\n"
        f"Task type: {task_type}\n"
        f"Activated concepts: {json.dumps([{k: n[k] for k in ('id','kind','activation','neighbors') if k in n} for n in fired], indent=2)}\n"
        f"Claims: {json.dumps(evidence, indent=2)}\n"
        f"Critique: {json.dumps(critique, indent=2)}\n",
        log=log,
        system=synth_system,
    )
    return synthesis.strip()


def format_cortex(slug: str, limit: int = 30, query: str | None = None) -> str:
    cortex = load_cortex(slug)
    nodes = sorted(
        (cortex.get("nodes") or {}).values(),
        key=lambda n: -int(n.get("weight") or 0),
    )
    if not nodes:
        return f"Cortex for `{slug}` is empty. File recaps, then: ./catchup cortex {slug}"
    from . import viz

    fired = activate(slug, query, hops=2, top=min(14, limit)) if query else []
    fired_ids = {n["id"] for n in fired}
    chunks = [viz.cortex_map(cortex, slug=slug, fired_ids=fired_ids, limit=min(12, limit))]
    if query:
        chunks.append("")
        chunks.append(viz.activation_panel(fired))
    chunks.append("")
    chunks.append(f"Cortex `{slug}` — {len(nodes)} concepts, {len(cortex.get('edges') or {})} links")
    for node in nodes[:limit]:
        nbs = ", ".join(n for n, _ in neighbors(cortex, node["id"])[:5])
        mark = viz.glyphs()["fire"] if node["id"] in fired_ids else " "
        chunks.append(
            f"  {mark} {viz.cell(node['id'], 24)} {viz.cell(str(node.get('kind') or '?'), 8)} "
            f"w={node.get('weight')}  → {viz.ellipsize(nbs, 40)}"
        )
    if query:
        chunks.append("")
        chunks.append(f"Highlighted for {query!r}.")
        chunks.append(f"Walk it:  ./catchup walk {slug} {query}")
        chunks.append(f"Think:    ./catchup think {slug} {query}")
    return "\n".join(chunks)


def _should_note(node: dict) -> bool:
    nid = node.get("id") or ""
    kind = node.get("kind") or ""
    if kind not in NOTE_KINDS:
        return False
    if is_generic_hub(nid):
        return False
    if len(nid) < 2 or len(nid) > 60:
        return False
    return True


def note_filename(nid: str) -> str:
    safe = re.sub(r"[/\\]+", "-", nid).strip() or "concept"
    return f"{safe[:80]}.md"


def render_concept_note(slug: str, nid: str, cortex: dict) -> str:
    node = (cortex.get("nodes") or {}).get(nid) or {"id": nid}
    links = synapses(cortex, nid, limit=16)
    moments = node.get("moments") or []
    aliases = node.get("aliases") or []
    lines = [
        f"<!-- {NOTE_MARKER} -->",
        f"# {nid}",
        "",
        f"_{node.get('kind') or '?'}_ · w={node.get('weight') or 0}"
        + (f" · first {node['first_seen']}" if node.get("first_seen") else "")
        + (f" · last {node['last_seen']}" if node.get("last_seen") else ""),
        "",
    ]
    definition = (node.get("definition") or "").strip()
    if definition:
        lines += [definition, ""]
    if aliases:
        lines += ["Aliases: " + ", ".join(f"`{a}`" for a in aliases), ""]
    lines += ["## Synapses", ""]
    if links:
        for syn in links:
            label = syn.get("label") or syn.get("kind") or "with"
            lines.append(
                f"- {syn['id']} — {label} · w={syn['weight']}"
            )
    else:
        lines.append("_None yet._")
    lines.append("")
    if moments:
        lines += ["## Heard", ""]
        for m in moments:
            ts = m.get("timestamp") or "?"
            ep = m.get("episode") or ""
            heading = m.get("heading") or nid
            lines.append(f"- **[{ts}] {heading}** — {ep}")
            if m.get("insight"):
                lines.append(f"  {m['insight']}")
        lines.append("")
    exam_prompts = node.get("exam_prompts") or []
    if exam_prompts:
        lines += ["## Exam", ""]
        for prompt in exam_prompts:
            lines.append(f"- {prompt}")
        lines.append("")
    episodes = node.get("episodes") or []
    if episodes:
        lines += ["## Episodes", ""]
        for ep in episodes:
            lines.append(f"- {ep}")
        lines.append("")
    lines += [
        "## Jump",
        "",
        f"- Walk: `./catchup walk {slug} {nid}`",
        f"- Graph: `./catchup graph {slug}`",
        f"- Clip: `./catchup clip {slug} {nid}`",
        f"- Think: `./catchup think {slug} {nid}`",
        "",
    ]
    return "\n".join(lines)


def write_concept_notes(slug: str, cortex: dict | None = None) -> list[Path]:
    """One CatchMeUp page per neuron (read with ./catchup walk / graph)."""
    cortex = cortex or load_cortex(slug)
    notes = brains.notes_dir(slug)
    notes.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    keep = set()
    for nid, node in (cortex.get("nodes") or {}).items():
        if not _should_note(node):
            continue
        path = notes / note_filename(nid)
        path.write_text(render_concept_note(slug, nid, cortex))
        keep.add(path.name)
        written.append(path)
    for path in notes.glob("*.md"):
        if path.name in keep or path.name == "_cortex.md" or path.name.endswith("_notes.md"):
            continue
        try:
            head = path.read_text()[:80]
        except OSError:
            continue
        if NOTE_MARKER in head:
            path.unlink()
    return written


def format_walk(slug: str, query: str | None = None) -> str:
    cortex = load_cortex(slug)
    nodes = cortex.get("nodes") or {}
    if not nodes:
        return f"Cortex for `{slug}` is empty. File recaps, then: ./catchup walk {slug} <concept>"
    if not (query or "").strip():
        from . import viz
        top = sorted(nodes.values(), key=lambda n: -int(n.get("weight") or 0))[:12]
        lines = [f"Walk `{slug}` — pick a neuron:", ""]
        for node in top:
            lines.append(
                f"  {viz.cell(node['id'], 28)} {viz.cell(str(node.get('kind', '?')), 8)} w={node.get('weight')}"
            )
        lines += ["", f"  ./catchup walk {slug} {top[0]['id']}" if top else ""]
        lines.append(f"  ./catchup graph {slug}")
        return "\n".join(lines).rstrip() + "\n"
    nid = find_node(cortex, query)
    if not nid:
        return (
            f"Nothing in `{slug}` matched {query!r}.\n"
            f"  ./catchup cortex {slug}\n"
            f"  ./catchup walk {slug}\n"
        )
    from . import viz

    node = nodes[nid]
    links = synapses(cortex, nid)
    fired = {nid, *(s["id"] for s in links[:8])}
    chunks = [
        viz.cortex_map(subgraph(cortex, nid), slug=slug, fired_ids=fired, limit=10),
        "",
        viz.walk_card(node, links, slug),
    ]
    exam_prompts = node.get("exam_prompts") or []
    if exam_prompts:
        chunks.append("")
        chunks.append("exam")
        for prompt in exam_prompts[:4]:
            chunks.append(f"  • {prompt}")
    moments = node.get("moments") or []
    if moments:
        chunks.append("")
        chunks.append(viz.timeline([
            {"timestamp": m.get("timestamp"), "heading": m.get("heading") or nid}
            for m in moments
        ]))
    chunks.append("")
    if links:
        chunks.append(viz.hop_list(links))
        chunks.append("")
    chunks.append(f"  ./catchup clip {slug} {nid}")
    chunks.append(f"  ./catchup think {slug} {nid}")
    chunks.append(f"  ./catchup graph {slug} {nid}")
    return "\n".join(chunks)


def format_trace(slug: str, src: str, dst: str) -> str:
    cortex = load_cortex(slug)
    if not cortex.get("nodes"):
        return f"Cortex for `{slug}` is empty."
    a = find_node(cortex, src)
    b = find_node(cortex, dst)
    if not a:
        return f"No neuron matched {src!r}."
    if not b:
        return f"No neuron matched {dst!r}."
    if a == b:
        return f"`{a}` is already that neuron. ./catchup walk {slug} {a}"
    hops = shortest_path(cortex, a, b)
    if not hops:
        return (
            f"No path from `{a}` to `{b}` in `{slug}`.\n"
            f"They have not fired together yet."
        )
    from . import viz
    return viz.trace_path(hops, slug)


def format_notes(slug: str) -> str:
    """In-app notes index — this is the reader, not another app."""
    cortex = load_cortex(slug)
    nodes = sorted(
        (cortex.get("nodes") or {}).values(),
        key=lambda n: -int(n.get("weight") or 0),
    )
    if not nodes:
        return f"No notes in `{slug}` yet. Recap into this brain first."
    from . import viz

    return viz.notes_table(
        slug,
        nodes,
        len(cortex.get("edges") or {}),
        synapses_of=lambda nid: len(synapses(cortex, nid, limit=20)),
    )


def _interactive() -> bool:
    return sys.stdin.isatty() and sys.stdout.isatty()


def run_walk(slug: str, start: str | None = None) -> None:
    """Stay in CatchMeUp: hop neurons, clip, open the graph. No other app."""
    current = (start or "").strip() or None
    history: list[str] = []
    while True:
        print(format_walk(slug, current))
        if not _interactive():
            return
        cortex = load_cortex(slug)
        links = synapses(cortex, current) if current else []
        if current:
            print("  name or 1–9 to hop · clip · graph · back · notes · q")
        else:
            print("  type a concept · graph · q")
        try:
            raw = input(f"{current or slug}> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not raw or raw.lower() in {"q", "quit", "exit"}:
            return
        low = raw.lower()
        if low in {"graph", "map"}:
            from . import graph as graph_mod
            path = graph_mod.open_graph(slug, current)
            print(f"  opened {path}" if graph_mod.should_open() else f"  wrote {path}")
            continue
        if low in {"notes", "ls", "list"}:
            if current:
                history.append(current)
            current = None
            continue
        if low in {"back", "b", ".."}:
            if history:
                current = history.pop()
            continue
        if low == "clip" and current:
            from . import library
            library.cmd_clip(current, None, brain=slug)
            continue
        if raw.isdigit() and current:
            idx = int(raw) - 1
            if 0 <= idx < len(links):
                history.append(current)
                current = links[idx]["id"]
            else:
                print(f"  no hop {raw}")
            continue
        nxt = find_node(cortex, raw)
        if nxt:
            if current:
                history.append(current)
            current = nxt
        else:
            print(f"  no neuron matched {raw!r}")


def export_obsidian(slug: str, dest: Path | None = None) -> Path:
    """Optional vault dump. CatchMeUp itself does not need Obsidian."""
    cortex = load_cortex(slug)
    dest = Path(dest) if dest else brains.brain_dir(slug) / "obsidian"
    dest.mkdir(parents=True, exist_ok=True)
    nodes = sorted(
        (cortex.get("nodes") or {}).values(),
        key=lambda n: -int(n.get("weight") or 0),
    )
    index = [
        f"# {slug}",
        "",
        f"{len(nodes)} concepts. Optional Obsidian export from CatchMeUp.",
        f"Read in-app instead: `./catchup walk {slug}` · `./catchup graph {slug}`",
        "",
    ]
    for node in nodes[:80]:
        if not _should_note(node):
            continue
        nid = node["id"]
        links = synapses(cortex, nid, limit=16)
        body = [
            f"# {nid}",
            "",
            f"_{node.get('kind')}_ · w={node.get('weight')}",
            "",
            (node.get("definition") or "").strip(),
            "",
            "## Synapses",
            "",
        ]
        for syn in links:
            body.append(f"- [[{syn['id']}]] — {syn.get('label') or syn.get('kind')} · w={syn['weight']}")
        body.append("")
        (dest / note_filename(nid)).write_text("\n".join(body).strip() + "\n")
        index.append(f"- [[{nid}]] _{node.get('kind')}_")
    (dest / "_cortex.md").write_text("\n".join(index).strip() + "\n")
    return dest


def write_cortex_index(slug: str, cortex: dict | None = None) -> Path:
    """Plain index CatchMeUp reads; not an Obsidian vault."""
    cortex = cortex or load_cortex(slug)
    notes = brains.notes_dir(slug)
    notes.mkdir(parents=True, exist_ok=True)
    nodes = sorted(
        (cortex.get("nodes") or {}).values(),
        key=lambda n: -int(n.get("weight") or 0),
    )
    lines = [
        f"# Cortex — {slug}",
        "",
        f"{len(nodes)} concepts, {len(cortex.get('edges') or {})} links. "
        f"Read here: `./catchup walk {slug}` · `./catchup graph {slug}`.",
        "",
        "## Concepts",
        "",
    ]
    if not nodes:
        lines.append("_Empty. File recaps into this brain, then run `./catchup cortex "
                     f"{slug} --rebuild`._")
    for node in nodes[:80]:
        syns = synapses(cortex, node["id"], limit=8)
        nbs = ", ".join(
            s["id"] + (f" ({s['kind']})" if s.get("kind") and s["kind"] != "with" else "")
            for s in syns
        )
        kind = node.get("kind") or "?"
        lines.append(f"- {node['id']} _{kind}_ w={node.get('weight')}  {nbs}".rstrip())
        definition = (node.get("definition") or "").strip()
        if definition:
            lines.append(f"  {definition[:220]}")
    path = notes / "_cortex.md"
    path.write_text("\n".join(lines).strip() + "\n")
    return path
