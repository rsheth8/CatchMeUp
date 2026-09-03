#!/usr/bin/env python3
"""CatchMeUp MCP server — expose folder brains to Cursor / Claude Desktop.

Each brain is a specialist agent over one subject's recaps (RAG, local files).

Run:  ./catchup mcp
Or add mcp.json.example to Cursor MCP settings.
"""
from __future__ import annotations

import json
import sys

from . import brains
from . import library

PROTOCOL = "2024-11-05"
SERVER = {"name": "catchmeup", "version": "1.0.0"}

TOOLS = [
    {
        "name": "list_brains",
        "description": (
            "List CatchMeUp specialist agents. Each brain is a folder of recaps "
            "(lectures or meetings) with its own persona. Use this before ask_brain."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "ask_brain",
        "description": (
            "Ask a CatchMeUp specialist a question. It RAG-searches that brain's "
            "transcripts and notes, answers from those first, then may add a labeled "
            "'Beyond the recordings' section. Set closed=true for exam mode "
            "(notes only, no general knowledge). Use list_brains if you don't know the slug."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "brain": {
                    "type": "string",
                    "description": "Brain slug, e.g. cs61a or acme-client",
                },
                "question": {"type": "string"},
                "closed": {
                    "type": "boolean",
                    "description": (
                        "If true, answer only from recaps (exam mode). "
                        "Default false: notes first, then labeled general help."
                    ),
                },
            },
            "required": ["brain", "question"],
        },
    },
    {
        "name": "search_brain",
        "description": "Keyword search inside one brain's recaps (titles, notes, transcripts).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "brain": {"type": "string"},
                "query": {"type": "string"},
            },
            "required": ["brain", "query"],
        },
    },
    {
        "name": "think_brain",
        "description": (
            "Deep multi-pass analysis in a CatchMeUp brain: decompose the task, "
            "activate related concepts in the cortex graph, gather cited evidence, "
            "critique gaps, then synthesize. Notes-first by default; set closed=true "
            "to stay inside the recordings. Use ask_brain for a one-line lookup."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "brain": {"type": "string"},
                "question": {"type": "string", "description": "Question or task"},
                "closed": {
                    "type": "boolean",
                    "description": "If true, stay inside the recaps (exam mode).",
                },
            },
            "required": ["brain", "question"],
        },
    },
    {
        "name": "list_recaps",
        "description": (
            "List recaps in one brain (pass brain) or the whole CatchMeUp library."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "brain": {
                    "type": "string",
                    "description": "Optional brain slug. Omit to list the whole library.",
                },
            },
        },
    },
    {
        "name": "diff_brain",
        "description": (
            "Compare the two latest recaps in a brain: terms, action items, "
            "and topics that appeared or disappeared. Use to see what changed "
            "since last lecture or meeting."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "brain": {"type": "string"},
            },
            "required": ["brain"],
        },
    },
    {
        "name": "walk_brain",
        "description": (
            "Open one concept in a CatchMeUp brain as a neuron: definition, "
            "typed synapses, timestamps, and the markdown note path. "
            "Omit concept to list the strongest neurons."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "brain": {"type": "string"},
                "concept": {
                    "type": "string",
                    "description": "Concept to open, e.g. mutex. Omit to list neurons.",
                },
            },
            "required": ["brain"],
        },
    },
    {
        "name": "trace_brain",
        "description": (
            "Shortest path between two concepts in a brain's cortex "
            "(synapses formed when ideas co-occurred or were heard together)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "brain": {"type": "string"},
                "from": {"type": "string"},
                "to": {"type": "string"},
            },
            "required": ["brain", "from", "to"],
        },
    },
    {
        "name": "grade_work",
        "description": (
            "Grade a student's homework, code, or written answer using ONLY that "
            "brain's recaps. Cite timestamps. Use for problem sets and 'does this "
            "match lecture 3?' — not for a lookup (use ask_brain)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "brain": {"type": "string"},
                "work": {
                    "type": "string",
                    "description": "The student's code, proof, or written answer.",
                },
                "assignment": {
                    "type": "string",
                    "description": "Optional prompt or filename for the assignment.",
                },
            },
            "required": ["brain", "work"],
        },
    },
]


def _read_message():
    header_line = sys.stdin.buffer.readline()
    if not header_line:
        return None
    if header_line.lstrip().startswith(b"{"):
        return json.loads(header_line.decode())
    headers = {}
    line = header_line
    while line not in (b"\r\n", b"\n", b""):
        key, _, val = line.decode("utf-8", "replace").partition(":")
        headers[key.strip().lower()] = val.strip()
        line = sys.stdin.buffer.readline()
        if not line:
            break
    n = int(headers.get("content-length") or 0)
    body = sys.stdin.buffer.read(n) if n else b""
    if not body:
        return None
    return json.loads(body.decode())


def _write_message(obj: dict) -> None:
    data = json.dumps(obj, ensure_ascii=False).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
    sys.stdout.buffer.flush()


def _result_text(text: str) -> dict:
    return {"content": [{"type": "text", "text": text}]}


def _handle_tool(name: str, args: dict) -> dict:
    library.load_env()
    args = args or {}
    if name == "list_brains":
        rows = brains.list_brains()
        if not rows:
            return _result_text(
                "No brains yet. Create one with: ./catchup brain new cs61a --lecture"
            )
        lines = []
        for b in rows:
            lines.append(
                f"- **{b.get('name')}** (`{b['slug']}`) · {b.get('kind')} · "
                f"{b.get('recap_count', 0)} recaps\n  {b.get('persona', '')[:180]}"
            )
        return _result_text("CatchMeUp brains:\n" + "\n".join(lines))
    if name == "ask_brain":
        slug = (args.get("brain") or "").strip()
        question = (args.get("question") or "").strip()
        if not slug or not question:
            return _result_text("Need brain slug and question.")
        try:
            closed = args.get("closed")
            if isinstance(closed, str):
                closed = closed.strip().lower() in {"1", "true", "yes", "on"}
            elif closed is not None:
                closed = bool(closed)
            answer = brains.ask_brain(slug, question, log=lambda *_: None, closed=closed)
        except FileNotFoundError as e:
            return _result_text(str(e))
        return _result_text(answer)
    if name == "think_brain":
        slug = (args.get("brain") or "").strip()
        question = (args.get("question") or "").strip()
        if not slug or not question:
            return _result_text("Need brain slug and question.")
        from . import cortex
        try:
            closed = args.get("closed")
            if isinstance(closed, str):
                closed = closed.strip().lower() in {"1", "true", "yes", "on"}
            elif closed is not None:
                closed = bool(closed)
            answer = cortex.think(slug, question, log=lambda *_: None, closed=closed)
        except FileNotFoundError as e:
            return _result_text(str(e))
        return _result_text(answer)
    if name == "search_brain":
        slug = (args.get("brain") or "").strip()
        query = (args.get("query") or "").strip()
        if not slug or not query:
            return _result_text("Need brain slug and query.")
        records = list(brains.iter_brain_records(slug))
        hits = library.search_records(query, mode=None, records=records)
        if not hits:
            return _result_text(f"No hits for {query!r} in `{slug}`.")
        lines = [f"{len(hits)} hit(s) in `{slug}` for {query!r}:"]
        for rec in hits[:15]:
            lines.append(f"- [{rec.get('mode')}] {rec.get('title') or rec.get('source')}")
        return _result_text("\n".join(lines))
    if name == "list_recaps":
        slug = (args.get("brain") or "").strip()
        records = list(brains.iter_brain_records(slug)) if slug else library.list_records()
        if not records:
            return _result_text("No recaps yet.")
        lines = []
        for rec in records[:40]:
            lines.append(
                f"- {rec.get('processed_at') or rec.get('recorded_at')} · "
                f"{rec.get('brain') or 'library'} · {rec.get('title') or rec.get('source')}"
            )
        return _result_text("\n".join(lines))
    if name == "diff_brain":
        slug = (args.get("brain") or "").strip()
        if not slug:
            return _result_text("Need brain slug.")
        rows = list(brains.iter_brain_records(slug))
        if len(rows) < 2:
            return _result_text(f"Need at least two recaps in `{slug}` to diff.")
        return _result_text(library.format_diff(library.diff_recaps(rows[0], rows[1])))
    if name == "walk_brain":
        slug = (args.get("brain") or "").strip()
        concept = (args.get("concept") or "").strip()
        if not slug:
            return _result_text("Need brain slug.")
        from . import cortex
        try:
            brains.load_brain(slug)
        except FileNotFoundError as e:
            return _result_text(str(e))
        return _result_text(cortex.format_walk(slug, concept or None))
    if name == "trace_brain":
        slug = (args.get("brain") or "").strip()
        src = (args.get("from") or "").strip()
        dst = (args.get("to") or "").strip()
        if not slug or not src or not dst:
            return _result_text("Need brain, from, and to.")
        from . import cortex
        try:
            brains.load_brain(slug)
        except FileNotFoundError as e:
            return _result_text(str(e))
        return _result_text(cortex.format_trace(slug, src, dst))
    if name == "grade_work":
        slug = (args.get("brain") or "").strip()
        work = (args.get("work") or "").strip()
        assignment = (args.get("assignment") or "").strip()
        if not slug or not work:
            return _result_text("Need brain slug and the student's work.")
        try:
            answer = brains.grade_work(slug, work, assignment=assignment, log=lambda *_: None)
        except FileNotFoundError as e:
            return _result_text(str(e))
        return _result_text(answer)
    return _result_text(f"Unknown tool: {name}")


def handle(msg: dict) -> dict | None:
    method = msg.get("method")
    msg_id = msg.get("id")
    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "protocolVersion": PROTOCOL,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": SERVER,
            },
        }
    if method == "notifications/initialized" or method == "initialized":
        return None
    if method == "ping":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        arguments = params.get("arguments") or {}
        try:
            result = _handle_tool(name, arguments)
        except Exception as e:
            result = _result_text(f"Error: {e}")
            result["isError"] = True
        return {"jsonrpc": "2.0", "id": msg_id, "result": result}
    if msg_id is None:
        return None
    return {
        "jsonrpc": "2.0",
        "id": msg_id,
        "error": {"code": -32601, "message": f"Unknown method {method}"},
    }


def main() -> None:
    library.load_env()
    while True:
        try:
            msg = _read_message()
        except json.JSONDecodeError:
            continue
        if msg is None:
            break
        reply = handle(msg)
        if reply is not None:
            _write_message(reply)


if __name__ == "__main__":
    main()
