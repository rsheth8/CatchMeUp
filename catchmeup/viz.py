#!/usr/bin/env python3
"""Terminal chrome for CatchMeUp — waveform identity, cortex maps, live meters.

No third-party deps. Art degrades cleanly when stdout is not a TTY, NO_COLOR
is set, or CATCHMEUP_PLAIN=1 (ASCII-only).
"""
from __future__ import annotations

import math
import os
import re
import shutil
import sys
import time

BLOCKS = "▁▂▃▄▅▆▇█"
BLOCKS_ASCII = " .:-=+*#"
STAGES = ("audio", "whisper", "llm", "notes")
KIND_MARK = {
    "term": "t",
    "moment": "m",
    "topic": "o",
    "action": "a",
    "study": "s",
    "person": "p",
    "episode": "e",
}


def plain() -> bool:
    return (os.environ.get("CATCHMEUP_PLAIN") or "").strip().lower() in {"1", "true", "yes", "on"}


def use_tty() -> bool:
    return sys.stdout.isatty() and not plain()


def use_color() -> bool:
    if plain() or os.environ.get("NO_COLOR"):
        return False
    forced = (os.environ.get("FORCE_COLOR") or os.environ.get("CATCHMEUP_COLOR") or "").strip()
    if forced in {"1", "true", "yes", "on"}:
        return True
    if forced in {"0", "false", "no", "off"}:
        return False
    return sys.stdout.isatty()


def use_unicode() -> bool:
    if plain():
        return False
    enc = (getattr(sys.stdout, "encoding", None) or "utf-8").lower()
    return "utf" in enc or enc in {"cp65001", ""}


def term_width(fallback: int = 80) -> int:
    try:
        cols = shutil.get_terminal_size(fallback=(fallback, 24)).columns
    except OSError:
        cols = fallback
    return max(56, min(cols, 84))


def paint(style: str, text: str) -> str:
    if not use_color() or not text:
        return text
    codes = {
        "reset": "0",
        "bold": "1",
        "dim": "2",
        "italic": "3",
        "red": "31",
        "green": "32",
        "yellow": "33",
        "blue": "34",
        "magenta": "35",
        "cyan": "36",
        "white": "37",
        "bright": "97",
        "bgred": "41",
    }
    picked = [codes[s] for s in style.replace(",", " ").split() if s in codes]
    if not picked:
        return text
    return f"\033[{';'.join(picked)}m{text}\033[0m"


def glyphs() -> dict[str, str]:
    if use_unicode():
        return {
            "dot": "●",
            "open": "○",
            "fire": "◉",
            "rec": "●",
            "tl": "╭",
            "tr": "╮",
            "bl": "╰",
            "br": "╯",
            "h": "─",
            "v": "│",
            "tee": "├",
            "cross": "┼",
            "diag": "╱",
            "back": "╲",
            "x": "╳",
            "arrow": "→",
            "plus": "+",
            "minus": "−",
            "bar": "█",
            "half": "░",
            "wave": BLOCKS,
        }
    return {
        "dot": "*",
        "open": "o",
        "fire": "@",
        "rec": "*",
        "tl": "+",
        "tr": "+",
        "bl": "+",
        "br": "+",
        "h": "-",
        "v": "|",
        "tee": "+",
        "cross": "+",
        "diag": "/",
        "back": "\\",
        "x": "x",
        "arrow": "->",
        "plus": "+",
        "minus": "-",
        "bar": "#",
        "half": ".",
        "wave": BLOCKS_ASCII,
    }


def waveform(n: int = 40, phase: float = 0.0, packets: int = 2) -> str:
    """Two packets of energy — looks like a clipped lecture waveform."""
    g = glyphs()
    blocks = g["wave"]
    last = len(blocks) - 1
    chars = []
    for i in range(max(4, n)):
        t = i / max(1, n - 1)
        env = abs(math.sin(math.pi * t * packets)) ** 0.85
        sig = 0.5 + 0.5 * math.sin(phase + i * 0.52)
        val = env * (0.25 + 0.75 * sig)
        chars.append(blocks[max(0, min(last, int(val * last)))])
    return "".join(chars)


def bar(value: float, ceiling: float, width: int = 16) -> str:
    g = glyphs()
    if ceiling <= 0:
        ceiling = 1.0
    filled = max(0, min(width, int(round((value / ceiling) * width))))
    return g["bar"] * filled + g["half"] * (width - filled)


_ANSI_RE = re.compile(r"\033\[[0-9;]*m")


def _visible_len(text: str) -> int:
    return len(_ANSI_RE.sub("", text))


def _plain(text: str) -> str:
    return _ANSI_RE.sub("", text or "")


def _ellipsis() -> str:
    return "…" if use_unicode() else "..."


def ellipsize(text: str, n: int) -> str:
    raw = _plain(text)
    if n <= 0:
        return ""
    if len(raw) <= n:
        return raw
    dots = _ellipsis()
    keep = n - len(dots)
    if keep <= 0:
        return dots[:n]
    return raw[:keep] + dots


def cell(text: str, n: int, align: str = "<") -> str:
    s = ellipsize(text, n)
    pad = max(0, n - len(s))
    if align == ">":
        return (" " * pad) + s
    return s + (" " * pad)


def _wrap_line(text: str, width: int) -> list[str]:
    width = max(8, width)
    raw = _plain(text)
    if len(raw) <= width:
        return [text]
    words = raw.split(" ")
    lines: list[str] = []
    cur = ""
    for word in words:
        pieces = [word] if len(word) <= width else [word[i : i + width] for i in range(0, len(word), width)]
        for piece in pieces:
            if not cur:
                cur = piece
            elif len(cur) + 1 + len(piece) <= width:
                cur = f"{cur} {piece}"
            else:
                lines.append(cur)
                cur = piece
    if cur:
        lines.append(cur)
    return lines or [""]


def _box(title: str, lines: list[str], width: int | None = None, wrap: bool = True) -> str:
    """Card that never exceeds `width` (default: terminal). Long lines wrap or clip."""
    g = glyphs()
    cap = max(40, width or term_width())
    inner = cap - 3
    title_s = title if _visible_len(title) <= inner - 2 else ellipsize(_plain(title), inner - 2)
    body: list[str] = []
    for ln in lines:
        if ln == "":
            body.append("")
            continue
        if wrap:
            body.extend(_wrap_line(ln, inner))
        else:
            vis = _plain(ln)
            body.append(ln if len(vis) <= inner else ellipsize(vis, inner))
    needed = max(
        40,
        6 + _visible_len(title_s),
        *[3 + _visible_len(ln) for ln in body if ln] or [0],
    )
    w = min(cap, needed)
    rest = max(1, w - 5 - _visible_len(title_s))
    top = f"{g['tl']}{g['h']} {title_s} {g['h'] * rest}{g['tr']}"
    out = [top]
    for ln in body:
        spaces = max(0, w - 3 - _visible_len(ln))
        out.append(f"{g['v']} {ln}{' ' * spaces}{g['v']}")
    out.append(f"{g['bl']}{g['h'] * (w - 2)}{g['br']}")
    return "\n".join(out)


def banner() -> str:
    g = glyphs()
    wave = paint("cyan", waveform(44, phase=0.8, packets=2))
    box = _box(
        paint("bold cyan", "CatchMeUp"),
        [
            paint("dim", "missed the Zoom · missed lecture"),
            paint("dim", "still got the notes"),
            paint("dim", f"rec {g['arrow']} whisper {g['arrow']} your LLM {g['arrow']} notes"),
        ],
    )
    return f"  {wave}\n" + "\n".join(f"  {ln}" for ln in box.splitlines())


def ok_wave() -> str:
    return "  " + paint("green", waveform(36, phase=1.2, packets=3))


def header_line(title: str) -> str:
    wave = paint("cyan", waveform(9, phase=0.4, packets=1))
    return f"{wave}  {paint('bold', title)}  {wave}"


def pipeline_track(current: str, hint: str = "") -> str:
    g = glyphs()
    order = list(STAGES)
    if current == "done":
        active = len(order)
    elif current in order:
        active = order.index(current)
    else:
        active = 0
    parts = []
    for i, name in enumerate(order):
        if i < active or current == "done":
            mark = paint("green", g["dot"])
            label = paint("green", name)
        elif i == active:
            mark = paint("cyan", g["dot"])
            label = paint("bold cyan", name)
        else:
            mark = paint("dim", g["open"])
            label = paint("dim", name)
        parts.append(f"{mark} {label}")
    joiner = paint("dim", f" {g['h'] * 3} ")
    line = joiner.join(parts)
    if hint:
        line += f"\n  {paint('dim', hint)}"
    return f"  {line}"


def recap_card(analysis: dict, mode: str, md_path=None, docx_path=None) -> str:
    title = (analysis.get("title") or "recap").strip()
    n_bm = len(analysis.get("bookmarks") or [])
    n_terms = len(analysis.get("terms") or [])
    n_study = len(analysis.get("study") or [])
    n_act = len(analysis.get("action_items") or [])
    if mode == "lecture":
        bits = f"{n_bm} moments · {n_terms} terms · {n_study} study"
    else:
        bits = f"{n_bm} bookmarks · {n_act} action items"
    files = []
    if docx_path:
        files.append(str(getattr(docx_path, "name", docx_path)))
    if md_path:
        files.append(str(getattr(md_path, "name", md_path)))
    body = [paint("bold", title), bits]
    if files:
        body.append(paint("dim", " · ".join(files)))
    return _box(f"{mode} recap", body)


def walk_card(node: dict, links: list[dict], slug: str = "") -> str:
    g = glyphs()
    nid = node.get("id") or "concept"
    kind = node.get("kind") or "?"
    definition = (node.get("definition") or "").strip()
    meta = f"{kind} · w={node.get('weight') or 0}"
    if node.get("first_seen"):
        meta += f" · first {node['first_seen']}"
    body = [paint("bold magenta", nid), paint("dim", meta)]
    if definition:
        body.append(definition)
    aliases = node.get("aliases") or []
    if aliases:
        body.append(paint("dim", "also " + ", ".join(str(a) for a in aliases)))
    if links:
        body.append("")
        name_w = max(18, term_width() - 22)
        for syn in links[:9]:
            label = syn.get("label") or syn.get("kind") or "with"
            body.append(
                f"{g['arrow']} {cell(label, 9)} {ellipsize(str(syn.get('id') or ''), name_w)}  "
                f"w={syn.get('weight')}"
            )
    else:
        body.append(paint("dim", "no synapses yet"))
    title = f"neuron {slug}".strip() if slug else "neuron"
    return _box(title, body)


def hop_list(links: list[dict], limit: int = 9) -> str:
    if not links:
        return ""
    lines = [paint("dim", "  hop")]
    name_w = max(16, term_width() - 18)
    for i, syn in enumerate(links[:limit], 1):
        label = syn.get("label") or syn.get("kind") or "with"
        lines.append(
            f"  {paint('cyan', f'{i}.')} {cell(label, 9)} {ellipsize(str(syn.get('id') or ''), name_w)}"
        )
    return "\n".join(lines)


def notes_table(
    slug: str,
    nodes: list[dict],
    n_edges: int,
    synapses_of,
    limit: int = 24,
) -> str:
    total = len(nodes)
    shown = nodes[:limit]
    name_w = 26
    lines = [
        f"Notes `{slug}` — {total} concepts · {n_edges} synapses",
        "",
        paint("dim", f"  {cell('concept', name_w)}  {cell('kind', 8)}  {cell('w', 3, '>')}  {cell('syn', 4, '>')}  heard"),
    ]
    for node in shown:
        n_syn = 0
        try:
            n_syn = int(synapses_of(node["id"]))
        except (TypeError, ValueError):
            n_syn = 0
        ts = ""
        moments = node.get("moments") or []
        if moments and moments[0].get("timestamp"):
            ts = _fmt_clock(parse_seconds(str(moments[0]["timestamp"])))
        lines.append(
            f"  {cell(node.get('id') or '', name_w)}  "
            f"{cell(str(node.get('kind') or '?'), 8)}  "
            f"{cell(str(node.get('weight') or 0), 3, '>')}  "
            f"{cell(str(n_syn), 4, '>')}  {ts}"
        )
    if total > len(shown):
        lines.append(paint("dim", f"  … {total - len(shown)} more"))
    top = shown[0]["id"] if shown else ""
    lines += [
        "",
        f"  ./catchup walk {slug} {top}".rstrip(),
        f"  ./catchup graph {slug}",
    ]
    return "\n".join(lines) + "\n"


def trace_path(hops: list[dict], slug: str = "") -> str:
    g = glyphs()
    if not hops:
        return ""
    heading = paint("bold", f"trace `{slug}`") if slug else paint("bold", "trace")
    lines = [heading, "", f"  {hops[0].get('from')}"]
    for hop in hops:
        label = hop.get("label") or hop.get("kind") or "with"
        lines.append(
            paint("dim", f"    {g['h'] * 3} {label} w={hop.get('weight')} {g['arrow']}")
        )
        lines.append(f"  {hop.get('to')}")
    return "\n".join(lines)


def rec_frame(elapsed: float, width: int = 28) -> str:
    g = glyphs()
    mins, secs = divmod(max(0, int(elapsed)), 60)
    clock = f"{mins}:{secs:02d}"
    wave = waveform(width, phase=elapsed * 7.2, packets=3)
    rec = paint("red", g["rec"] + " REC")
    hint = paint("dim", "Ctrl-C stops")
    return f"  {rec}  {paint('bold', clock)}  {paint('cyan', wave)}  {hint}"


def pass_line(i: int, n: int, label: str) -> str:
    g = glyphs()
    dots = paint("cyan", g["dot"] * i) + paint("dim", g["open"] * max(0, n - i))
    return f"  {dots}  pass {i}/{n}  {label}"


def _plot_line(grid: list[list[str]], x0: int, y0: int, x1: int, y1: int) -> None:
    g = glyphs()
    h, w = len(grid), len(grid[0]) if grid else 0
    dx, dy = abs(x1 - x0), abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx - dy
    x, y = x0, y0
    while True:
        if (x, y) != (x0, y0) and (x, y) != (x1, y1) and 0 <= y < h and 0 <= x < w:
            if dx > dy * 2:
                ch = g["h"]
            elif dy > dx * 2:
                ch = g["v"]
            elif sx == sy:
                ch = g["back"]
            else:
                ch = g["diag"]
            existing = grid[y][x]
            if existing in (g["dot"], g["fire"], "@", "*"):
                pass
            elif existing in (g["h"], g["v"]) and ch != existing:
                grid[y][x] = g["cross"]
            elif existing in (g["diag"], g["back"]) and ch != existing:
                grid[y][x] = g["x"]
            elif existing == " ":
                grid[y][x] = ch
        if x == x1 and y == y1:
            break
        e2 = 2 * err
        if e2 > -dy:
            err -= dy
            x += sx
        if e2 < dx:
            err += dx
            y += sy


def _write(grid: list[list[str]], x: int, y: int, text: str) -> None:
    h, w = len(grid), len(grid[0]) if grid else 0
    g = glyphs()
    blocked = {g["dot"], g["fire"], "*", "@"}
    for i, ch in enumerate(text):
        xx = x + i
        if 0 <= y < h and 0 <= xx < w and grid[y][xx] not in blocked:
            grid[y][xx] = ch


def cortex_map(
    cortex: dict,
    slug: str = "",
    fired_ids: set[str] | None = None,
    limit: int = 10,
    width: int | None = None,
    height: int = 11,
) -> str:
    """Circular concept graph + weight bars. The screenshot feature."""
    g = glyphs()
    fired_ids = fired_ids or set()
    nodes = sorted(
        (cortex.get("nodes") or {}).values(),
        key=lambda n: -int(n.get("weight") or 0),
    )
    if not nodes:
        return ""
    shown = nodes[: max(3, min(limit, 12))]
    width = width or min(term_width(), 72)
    inner_w = max(36, width - 4)
    inner_h = height
    grid = [[" " for _ in range(inner_w)] for _ in range(inner_h)]
    cx, cy = inner_w // 2, inner_h // 2
    rx, ry = max(8, inner_w // 2 - 6), max(3, inner_h // 2 - 1)
    pos: dict[str, tuple[int, int]] = {}
    n = len(shown)
    for i, node in enumerate(shown):
        angle = -math.pi / 2 + (2 * math.pi * i / n)
        x = int(round(cx + rx * math.cos(angle)))
        y = int(round(cy + ry * math.sin(angle)))
        x = max(2, min(inner_w - 3, x))
        y = max(0, min(inner_h - 1, y))
        pos[node["id"]] = (x, y)

    shown_ids = {n["id"] for n in shown}
    for edge in (cortex.get("edges") or {}).values():
        a, b = edge.get("a"), edge.get("b")
        if a in pos and b in pos and a in shown_ids and b in shown_ids:
            x0, y0 = pos[a]
            x1, y1 = pos[b]
            _plot_line(grid, x0, y0, x1, y1)

    for i, node in enumerate(shown, 1):
        x, y = pos[node["id"]]
        mark = g["fire"] if node["id"] in fired_ids else g["dot"]
        if 0 <= y < inner_h and 0 <= x < inner_w:
            grid[y][x] = mark
        tag = str(i)
        if x >= cx:
            _write(grid, x + 2, y, tag)
        else:
            _write(grid, x - len(tag) - 1, y, tag)

    n_nodes = len(cortex.get("nodes") or {})
    n_edges = len(cortex.get("edges") or {})
    title = f"cortex {slug}".strip() + f"  {n_nodes} concepts · {n_edges} links"
    map_lines = ["".join(row).rstrip() for row in grid]
    while map_lines and not map_lines[0].strip():
        map_lines.pop(0)
    while map_lines and not map_lines[-1].strip():
        map_lines.pop()
    ceiling = max(int(n.get("weight") or 1) for n in shown)
    bars = []
    for i, node in enumerate(shown, 1):
        nid = node["id"]
        mark = g["fire"] if nid in fired_ids else g["dot"]
        kind = KIND_MARK.get(node.get("kind") or "", "?")
        name = ellipsize(nid, 22)
        row = f"{mark} {i:<2} {kind}  {cell(name, 22)} {bar(int(node.get('weight') or 0), ceiling, 8)}  w={node.get('weight')}"
        if nid in fired_ids:
            row = paint("magenta", row)
        bars.append(row)
    body = map_lines + [""] + bars
    return _box(title, body, width=inner_w + 3, wrap=False)


def activation_panel(fired: list[dict]) -> str:
    if not fired:
        return paint("dim", "  no concepts lit up — try a more specific question")
    g = glyphs()
    ceiling = max((float(n.get("activation") or 0) for n in fired), default=1.0) or 1.0
    lines = [paint("bold magenta", f"  {g['fire']} spreading activation")]
    for node in fired[:12]:
        mag = float(node.get("activation") or 0)
        mark = g["fire"] if mag >= ceiling * 0.45 else g["dot"]
        nbs = ", ".join((node.get("neighbors") or [])[:4])
        row = f"  {mark} {cell(str(node.get('id') or ''), 22)} {bar(mag, ceiling, 12)}  {mag:.2f}"
        lines.append(paint("magenta", row) if mark == g["fire"] else row)
        if nbs:
            lines.append(paint("dim", f"       {g['h']} {ellipsize(nbs, term_width() - 12)}"))
    return "\n".join(lines)


def parse_seconds(ts: str) -> float:
    raw = (ts or "").strip()
    if not raw:
        return 0.0
    try:
        parts = [float(p) for p in raw.split(":")]
    except ValueError:
        return 0.0
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    return parts[0]


def timeline(bookmarks: list, width: int | None = None) -> str:
    """Horizontal timestamp track — the 'you can jump back in' picture."""
    g = glyphs()
    marks = []
    for bm in bookmarks or []:
        if not isinstance(bm, dict):
            continue
        heading = (bm.get("heading") or "").strip()
        ts = str(bm.get("timestamp") or "")
        if not heading and not ts:
            continue
        marks.append((parse_seconds(ts), ts or "?", ellipsize(heading, 12) if heading else ""))
    if not marks:
        return ""
    width = max(28, (width or min(term_width() - 8, 64)))
    hi = max(t for t, _, _ in marks) or 1.0
    axis = [g["h"]] * width
    placed: list[tuple[int, str]] = []
    for t, ts, heading in marks:
        x = int(round((t / hi) * (width - 1))) if hi else 0
        x = max(0, min(width - 1, x))
        axis[x] = g["dot"]
        placed.append((x, heading or ts))
    start_lab = "0:00"
    end_lab = _fmt_clock(hi)
    axis_s = paint("cyan", "".join(axis))
    label_rows = [[" "] * width, [" "] * width]
    used = [set(), set()]
    for x, heading in placed:
        start = max(0, min(width - len(heading), x - len(heading) // 2))
        row = 0 if not any(i in used[0] for i in range(start, start + len(heading))) else 1
        if any(i in used[row] for i in range(start, start + len(heading))):
            continue
        for i, ch in enumerate(heading):
            label_rows[row][start + i] = ch
            used[row].add(start + i)
    extra = "\n        " + "".join(label_rows[1]).rstrip() if any(ch != " " for ch in label_rows[1]) else ""
    return (
        f"  {paint('dim', start_lab):<6}{axis_s} {paint('dim', end_lab)}\n"
        f"        {''.join(label_rows[0]).rstrip()}{extra}"
    )


def _fmt_clock(seconds: float) -> str:
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h:
        return f"{h}:{m:02d}:{sec:02d}"
    return f"{m}:{sec:02d}"


def exam_card(passed: int, attempted: int, total: int) -> str:
    denom = attempted or total or 1
    pct = passed / denom if denom else 0
    letter, blurb = _grade(pct, attempted, total)
    meter = bar(passed, denom, 18)
    body = [
        f"{paint('bold', f'{passed}/{denom}')}   {meter}   {paint('bold', letter)}",
        paint("dim", blurb),
    ]
    return _box("score", body)


def _grade(pct: float, attempted: int, total: int) -> tuple[str, str]:
    if attempted == 0:
        return "—", "quit before the first question"
    if pct >= 0.95:
        return "S", "you didn't miss class. you time-traveled."
    if pct >= 0.8:
        return "A", "clip the misses and you're exam-ready"
    if pct >= 0.6:
        return "B", "the cortex knows the rest — ./catchup think"
    if pct >= 0.4:
        return "C", "replay the moments: ./catchup clip <term>"
    return "D", "re-read the recap, then quiz again"


def verdict_mark(verdict: str) -> str:
    raw = {"pass": "✓", "partial": "~", "miss": "✗", "blank": "✗"}.get(verdict, "?")
    if not use_unicode() and raw == "✓":
        raw = "+"
    if not use_unicode() and raw == "✗":
        raw = "x"
    colors = {"pass": "green", "partial": "yellow", "miss": "red", "blank": "red"}
    return paint(colors.get(verdict, "dim"), raw)


def flashcard(i: int, n: int, term: str, title: str) -> str:
    return _box(f"{i}/{n}", [paint("bold", term), paint("dim", str(title or ""))])


def demo_cortex() -> dict:
    return {
        "nodes": {
            "mutex": {"id": "mutex", "kind": "term", "weight": 4, "definition": "A lock only one thread can hold."},
            "environment diagrams": {"id": "environment diagrams", "kind": "topic", "weight": 3},
            "heaps": {"id": "heaps", "kind": "term", "weight": 2},
            "acquire": {"id": "acquire", "kind": "moment", "weight": 2},
            "billing": {"id": "billing", "kind": "action", "weight": 1},
            "exam": {"id": "exam", "kind": "study", "weight": 2},
        },
        "edges": {
            "acquire|mutex": {"a": "acquire", "b": "mutex", "weight": 2, "kind": "heard-at"},
            "environment diagrams|mutex": {"a": "environment diagrams", "b": "mutex", "weight": 2, "kind": "with"},
            "heaps|mutex": {"a": "heaps", "b": "mutex", "weight": 1, "kind": "with"},
            "exam|mutex": {"a": "exam", "b": "mutex", "weight": 1, "kind": "exam"},
            "acquire|environment diagrams": {"a": "acquire", "b": "environment diagrams", "weight": 1, "kind": "with"},
            "billing|heaps": {"a": "billing", "b": "heaps", "weight": 1, "kind": "with"},
        },
    }


def demo_fired() -> list[dict]:
    return [
        {"id": "mutex", "activation": 4.2, "neighbors": ["acquire", "heaps", "exam"]},
        {"id": "acquire", "activation": 2.1, "neighbors": ["mutex"]},
        {"id": "environment diagrams", "activation": 1.4, "neighbors": ["mutex"]},
        {"id": "heaps", "activation": 0.7, "neighbors": ["mutex"]},
    ]


def demo_bookmarks() -> list[dict]:
    return [
        {"timestamp": "00:04:10", "heading": "roll call"},
        {"timestamp": "00:12:40", "heading": "mutex acquire"},
        {"timestamp": "00:18:02", "heading": "env diagrams"},
        {"timestamp": "00:31:55", "heading": "this is on the exam"},
    ]


def demo_sheet() -> str:
    """Static gallery so `./catchup demo` is a screenshot in one command."""
    bookmarks = demo_bookmarks()
    chunks = [
        banner(),
        "",
        pipeline_track("whisper", "transcribing on-device…"),
        "",
        rec_frame(12.4),
        "",
        cortex_map(demo_cortex(), slug="cs61a", fired_ids={"mutex", "acquire"}),
        "",
        activation_panel(demo_fired()),
        "",
        timeline(bookmarks),
        "",
        walk_card(
            {"id": "mutex", "kind": "term", "weight": 4, "definition": "A lock only one thread can hold.", "first_seen": "2026-02-10"},
            [
                {"id": "acquire", "label": "heard at", "weight": 2},
                {"id": "environment diagrams", "label": "with", "weight": 2},
                {"id": "heaps", "label": "with", "weight": 1},
            ],
            slug="cs61a",
        ),
        "",
        trace_path(
            [
                {"from": "mutex", "to": "acquire", "label": "heard at", "weight": 2},
                {"from": "acquire", "to": "heaps", "label": "with", "weight": 1},
            ],
            slug="cs61a",
        ),
        "",
        recap_card(
            {"title": "Week 3: Mutexes", "bookmarks": bookmarks, "terms": [1, 2, 3], "study": [1, 2]},
            "lecture",
            md_path="week3_lecture_notes.md",
            docx_path="week3_lecture_notes.docx",
        ),
        "",
        exam_card(6, 8, 8),
        "",
        paint("dim", "  live:  ./catchup demo --web   ·  ./catchup walk NAME idea   ·  ./catchup rec"),
    ]
    return "\n".join(chunks)


def _play_frames(frames: list[str], delay: float) -> None:
    """Rewrite a block in place so the terminal actually moves."""
    if not frames:
        return
    height = max(len(f.splitlines() or [""]) for f in frames)
    padded = []
    for block in frames:
        lines = block.splitlines() or [""]
        padded.append(lines + [""] * (height - len(lines)))
    for i, lines in enumerate(padded):
        if i:
            sys.stdout.write(f"\033[{height}A")
        for line in lines:
            sys.stdout.write("\033[2K" + line + "\n")
        sys.stdout.flush()
        time.sleep(delay)


def _demo_delay(seconds: float) -> float:
    raw = (os.environ.get("CATCHMEUP_DEMO_FAST") or "").strip()
    if raw in {"1", "true", "yes", "on"}:
        return min(0.02, seconds)
    return seconds


def animate_banner(frames: int = 14, delay: float = 0.045) -> None:
    if not use_tty():
        print(banner())
        return
    width = min(term_width(), 56)
    n = max(28, width - 6)
    delay = _demo_delay(delay)
    for i in range(frames):
        wave = paint("cyan", waveform(n, phase=0.4 + i * 0.35, packets=2))
        sys.stdout.write(f"\r  {wave}")
        sys.stdout.flush()
        time.sleep(delay)
    sys.stdout.write("\r\033[K")
    print(banner())


def play_demo() -> None:
    """Live terminal play-through: wave, rec meter, pipeline, cortex lighting up."""
    if not use_tty():
        print(demo_sheet())
        return
    animate_banner(frames=18, delay=0.04)
    print()
    rec_frames = [rec_frame(i * 0.45) for i in range(22)]
    _play_frames(rec_frames, _demo_delay(0.055))
    print()
    pipe = [
        ("audio", "capturing the lecture…"),
        ("whisper", "transcribing on-device…"),
        ("llm", "writing the recap…"),
        ("notes", "linking concepts into the cortex…"),
        ("done", "cortex updated"),
    ]
    _play_frames([pipeline_track(stage, hint) for stage, hint in pipe], _demo_delay(0.38))
    print()
    sample = demo_cortex()
    fire_seq = [set(), {"mutex"}, {"mutex", "acquire"}, {"mutex", "acquire", "exam"}]
    _play_frames(
        [cortex_map(sample, slug="cs61a", fired_ids=fired) for fired in fire_seq],
        _demo_delay(0.55),
    )
    print()
    print(activation_panel(demo_fired()))
    print()
    print(timeline(demo_bookmarks()))
    print()
    print(
        walk_card(
            {
                "id": "mutex",
                "kind": "term",
                "weight": 4,
                "definition": "A lock only one thread can hold.",
                "first_seen": "2026-02-10",
            },
            [
                {"id": "acquire", "label": "heard at", "weight": 2},
                {"id": "environment diagrams", "label": "with", "weight": 2},
                {"id": "heaps", "label": "with", "weight": 1},
            ],
            slug="cs61a",
        )
    )
    print()
    print(
        trace_path(
            [
                {"from": "mutex", "to": "acquire", "label": "heard at", "weight": 2},
                {"from": "acquire", "to": "heaps", "label": "with", "weight": 1},
            ],
            slug="cs61a",
        )
    )
    print()
    print(
        recap_card(
            {"title": "Week 3: Mutexes", "bookmarks": demo_bookmarks(), "terms": [1, 2, 3], "study": [1, 2]},
            "lecture",
            md_path="week3_lecture_notes.md",
            docx_path="week3_lecture_notes.docx",
        )
    )
    print()
    print(exam_card(6, 8, 8))
    print()
    print(paint("dim", "  clickable graph:  ./catchup demo --web"))
    print(paint("dim", "  real brain:       ./catchup graph NAME   ·  ./catchup rec"))


def main(argv=None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] in {"--web", "web", "--graph"}:
        from . import graph
        print(graph.open_demo())
        return
    if args and args[0] in {"--animate", "animate"}:
        play_demo()
        return
    print(demo_sheet())


if __name__ == "__main__":
    main()
