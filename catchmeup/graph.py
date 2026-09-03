#!/usr/bin/env python3
"""CatchMeUp's own concept graph — a single HTML file, no other app."""
from __future__ import annotations

import json
import os
import sys
import webbrowser
from collections import Counter
from pathlib import Path

from . import brains
from . import cortex as cortex_mod
from .paths import output_root

GRAPH_FILE = "cortex.html"
GRAPH_LIMIT = 120
FOCUS_BONUS = 40


def graph_path(slug: str) -> Path:
    return brains.brain_dir(slug) / GRAPH_FILE


def _esc_html(s: str) -> str:
    return (
        (s or "")
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def graph_payload(
    slug: str,
    cortex: dict | None = None,
    focus: str | None = None,
    limit: int | None = None,
) -> dict:
    cortex = cortex or cortex_mod.load_cortex(slug)
    cap = GRAPH_LIMIT if limit is None else max(1, int(limit))
    nodes_map = cortex.get("nodes") or {}
    edges_map = cortex.get("edges") or {}
    degree: Counter[str] = Counter()
    for edge in edges_map.values():
        a, b = edge.get("a"), edge.get("b")
        if a:
            degree[a] += 1
        if b:
            degree[b] += 1

    def score(node: dict) -> int:
        nid = node.get("id") or ""
        kind = node.get("kind") or ""
        s = int(node.get("weight") or 0) * 4 + int(degree.get(nid) or 0)
        if kind == "term":
            s += 8
        elif kind == "topic":
            s += 4
        elif kind == "person":
            s += 3
        elif kind in {"moment", "study", "action", "episode"}:
            s -= 8
        if getattr(cortex_mod, "is_generic_hub", None) and cortex_mod.is_generic_hub(nid):
            s = int(s * 0.22)
        return s

    def include(node: dict, extra: set[str]) -> bool:
        nid = node.get("id") or ""
        if nid in extra:
            return True
        kind = node.get("kind") or ""
        w = int(node.get("weight") or 0)
        deg = int(degree.get(nid) or 0)
        if kind in {"action", "episode"}:
            return False
        if kind in {"moment", "study"} and w < 2 and deg < 4:
            return False
        return True

    ranked = sorted(nodes_map.values(), key=score, reverse=True)
    kind_counts = Counter((n.get("kind") or "term") for n in nodes_map.values())
    keep: set[str] = set()
    focus_id = ""
    if focus:
        focus_id = cortex_mod.find_node(cortex, focus) or ""
        if focus_id and focus_id in nodes_map:
            keep.add(focus_id)
            neigh = []
            for edge in edges_map.values():
                a, b = edge.get("a"), edge.get("b")
                other = b if a == focus_id else a if b == focus_id else ""
                if other and other in nodes_map:
                    neigh.append((int(edge.get("weight") or 1), other))
            neigh.sort(reverse=True)
            for _, other in neigh:
                if len(keep) >= cap + FOCUS_BONUS:
                    break
                keep.add(other)
    for node in ranked:
        if len(keep) >= cap:
            break
        nid = node.get("id")
        if nid and include(node, keep):
            keep.add(nid)

    packed = []
    for node in ranked:
        nid = node.get("id")
        if nid not in keep:
            continue
        packed.append({
            "id": nid,
            "kind": node.get("kind") or "term",
            "weight": int(node.get("weight") or 1),
            "degree": int(degree.get(nid) or 0),
            "definition": (node.get("definition") or "")[:280],
            "aliases": (node.get("aliases") or [])[:8],
            "episodes": (node.get("episodes") or [])[:6],
            "moments": (node.get("moments") or [])[:6],
            "first_seen": node.get("first_seen") or "",
            "last_seen": node.get("last_seen") or "",
        })
    if focus_id and focus_id in nodes_map and focus_id not in {n["id"] for n in packed}:
        node = nodes_map[focus_id]
        packed.insert(0, {
            "id": focus_id,
            "kind": node.get("kind") or "term",
            "weight": int(node.get("weight") or 1),
            "degree": int(degree.get(focus_id) or 0),
            "definition": (node.get("definition") or "")[:280],
            "aliases": (node.get("aliases") or [])[:8],
            "episodes": (node.get("episodes") or [])[:6],
            "moments": (node.get("moments") or [])[:6],
            "first_seen": node.get("first_seen") or "",
            "last_seen": node.get("last_seen") or "",
        })

    keep_ids = {n["id"] for n in packed}
    edges = []
    for edge in edges_map.values():
        a, b = edge.get("a"), edge.get("b")
        if a in keep_ids and b in keep_ids:
            edges.append({
                "a": a,
                "b": b,
                "weight": int(edge.get("weight") or 1),
                "kind": edge.get("kind") or "with",
            })
    max_weight = max((n["weight"] for n in packed), default=1)
    return {
        "slug": slug,
        "focus": focus_id,
        "nodes": packed,
        "edges": edges,
        "totals": {"nodes": len(nodes_map), "edges": len(edges_map)},
        "kind_counts": dict(kind_counts),
        "max_weight": max_weight,
    }


def render_graph_html(
    slug: str,
    cortex: dict | None = None,
    demo: bool = False,
    focus: str | None = None,
) -> str:
    data = json.dumps(graph_payload(slug, cortex, focus=focus), ensure_ascii=False)
    data = data.replace("<", "\\u003c").replace("</", "<\\/")
    return (
        _TEMPLATE.replace("__DATA__", data)
        .replace("__SLUG__", _esc_html(slug))
        .replace("__BODY_CLASS__", "is-demo" if demo else "")
        .replace("__HUD__", _DEMO_HUD if demo else "")
        .replace("__DEMO_JS__", _DEMO_JS if demo else "")
    )


def write_graph(slug: str, cortex: dict | None = None, focus: str | None = None) -> Path:
    brains.load_brain(slug)
    cortex = cortex or cortex_mod.load_cortex(slug)
    path = graph_path(slug)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render_graph_html(slug, cortex, focus=focus), encoding="utf-8")
    return path


def should_open() -> bool:
    if (os.environ.get("CATCHMEUP_NO_OPEN") or "").strip() in {"1", "true", "yes"}:
        return False
    return sys.stdout.isatty()


def open_graph(slug: str, focus: str | None = None) -> Path:
    path = write_graph(slug, focus=focus)
    uri = path.resolve().as_uri()
    if focus:
        nid = cortex_mod.find_node(cortex_mod.load_cortex(slug), focus)
        if nid:
            uri += "#" + nid.replace(" ", "%20")
    if should_open():
        webbrowser.open(uri)
    return path


def demo_html_path() -> Path:
    out = output_root()
    out.mkdir(parents=True, exist_ok=True)
    return out / "demo.html"


def write_demo() -> Path:
    from . import viz
    path = demo_html_path()
    path.write_text(render_graph_html("demo", viz.demo_cortex(), demo=True), encoding="utf-8")
    return path


def open_demo() -> Path:
    path = write_demo()
    if should_open():
        webbrowser.open(path.resolve().as_uri())
    return path


_DEMO_HUD = """
<section id="hud">
  <div class="rec"><span class="dot">●</span> REC  <span id="clock">0:00</span>  <span id="vu">▁▂▃▄▅</span></div>
  <div class="pipe" id="pipe"></div>
  <div class="blurb" id="blurb">capturing the lecture…</div>
</section>
"""

_DEMO_JS = r"""
(function demoTour() {
  const stages = [
    { name: "audio", hint: "capturing the lecture…" },
    { name: "whisper", hint: "transcribing on-device…" },
    { name: "llm", hint: "writing the recap…" },
    { name: "notes", hint: "linking concepts into the cortex…" },
    { name: "done", hint: "cortex updated — click around" }
  ];
  const order = ["audio", "whisper", "llm", "notes"];
  const clock = document.getElementById("clock");
  const vu = document.getElementById("vu");
  const pipe = document.getElementById("pipe");
  const blurb = document.getElementById("blurb");
  const blocks = "▁▂▃▄▅▆▇█▇▆▅▄▃▂▁";
  let t0 = Date.now();
  let stage = 0;
  const tour = ["mutex", "acquire", "environment diagrams", "heaps", "exam"];
  let ti = 0;

  function renderPipe() {
    const cur = stages[Math.min(stage, stages.length - 1)];
    const parts = order.map((name, i) => {
      const cls = cur.name === "done" || i < stage ? "done" : (i === stage ? "on" : "");
      const mark = cls ? "●" : "○";
      return '<span class="' + cls + '">' + mark + " " + name + "</span>";
    });
    pipe.innerHTML = parts.join(" ── ");
    blurb.textContent = cur.hint;
  }
  renderPipe();

  setInterval(() => {
    const elapsed = (Date.now() - t0) / 1000;
    const mins = Math.floor(elapsed / 60);
    const secs = Math.floor(elapsed % 60);
    if (clock) clock.textContent = mins + ":" + String(secs).padStart(2, "0");
    if (vu) {
      const i = Math.floor(elapsed * 12) % blocks.length;
      let s = "";
      for (let k = 0; k < 18; k++) s += blocks[(i + k * 2) % blocks.length];
      vu.textContent = s;
    }
  }, 80);

  setInterval(() => {
    if (stage < stages.length - 1) {
      stage += 1;
      renderPipe();
    }
  }, 1600);

  setInterval(() => {
    const id = tour[ti % tour.length];
    if (byId[id]) select(byId[id], { isolate: false });
    ti += 1;
  }, 2600);
})();
"""


_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CatchMeUp · __SLUG__</title>
<style>
  :root {
    --bg: #070a10;
    --panel: rgba(12, 17, 24, 0.92);
    --ink: #e8eef7;
    --dim: #8090a8;
    --line: #243044;
    --cyan: #6ee7f5;
    --magenta: #e879f9;
    --green: #86efac;
    --amber: #fbbf24;
    --blue: #93c5fd;
    --orange: #fdba74;
    --glass: rgba(14, 20, 28, 0.78);
    --ease: cubic-bezier(0.16, 1, 0.3, 1);
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--ink);
    font: 14px/1.45 ui-sans-serif, system-ui, -apple-system, sans-serif; }
  body { display: flex; flex-direction: column; }
  header {
    display: flex; align-items: center; gap: 14px; flex-wrap: wrap;
    padding: 10px 16px 8px; border-bottom: 1px solid var(--line);
    background: linear-gradient(180deg, #101820 0%, #0c1218 100%);
    z-index: 5;
    animation: drop-in .6s var(--ease) both;
  }
  .brand-wrap { display: flex; align-items: baseline; gap: 10px; min-width: 10em; }
  .brand { font-weight: 700; letter-spacing: .06em; color: var(--cyan); font-size: 13px; text-transform: uppercase; }
  .wave { color: var(--cyan); letter-spacing: -1px; font-size: 12px; opacity: .85;
    font-variant-numeric: tabular-nums; min-width: 5.5em; display: inline-block; }
  .meta { color: var(--dim); font-size: 13px; }
  .meta b { color: var(--ink); font-weight: 600; }
  .search-wrap { position: relative; margin-left: auto; }
  header input {
    background: #0a0e14; border: 1px solid var(--line); color: var(--ink);
    padding: 8px 12px 8px 32px; border-radius: 8px; min-width: 240px; width: min(36vw, 340px);
    transition: border-color .2s var(--ease), box-shadow .25s var(--ease), transform .25s var(--ease);
  }
  .search-wrap::before {
    content: "/"; position: absolute; left: 11px; top: 50%; transform: translateY(-50%);
    color: var(--dim); font: 12px ui-monospace, Menlo, monospace; pointer-events: none;
  }
  header input:focus { outline: none; border-color: var(--cyan);
    box-shadow: 0 0 0 4px rgba(110,231,245,.12); transform: translateY(-1px); }
  #suggest {
    position: absolute; left: 0; right: 0; top: calc(100% + 4px);
    background: #121820; border: 1px solid var(--line); border-radius: 8px;
    max-height: 280px; overflow: auto; z-index: 20;
    box-shadow: 0 18px 40px rgba(0,0,0,.45);
    transform-origin: top center;
    animation: pop .28s var(--ease) both;
  }
  #suggest[hidden] { display: none; }
  #suggest button {
    display: flex; align-items: center; gap: 8px; width: 100%;
    background: none; border: 0; color: var(--ink); text-align: left;
    padding: 8px 12px; cursor: pointer; font: inherit;
  }
  #suggest button:hover, #suggest button.active { background: #1a2430; }
  #suggest .dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
  #suggest em { margin-left: auto; color: var(--dim); font-style: normal; font-size: 11px; }
  .chips { display: flex; flex-wrap: wrap; gap: 6px; width: 100%; padding: 2px 0 4px; }
  .chip {
    display: inline-flex; align-items: center; gap: 6px; cursor: pointer;
    border: 1px solid var(--line); background: #0c1218; color: var(--dim);
    border-radius: 999px; padding: 3px 9px; font-size: 12px; user-select: none;
    transition: transform .2s var(--ease), opacity .2s, background .2s, color .2s, border-color .2s;
  }
  .chip:hover { transform: translateY(-1px) scale(1.03); }
  .chip .swatch { width: 7px; height: 7px; border-radius: 50%; }
  .chip.on { color: var(--ink); border-color: #3a4a60; background: #141c26; }
  .chip.off { opacity: .4; }
  #hud {
    display: flex; flex-wrap: wrap; gap: 10px 22px; align-items: center;
    padding: 8px 16px; border-bottom: 1px solid var(--line);
    font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
    background: #0b1016;
  }
  #hud .rec { color: #f87171; font-weight: 700; }
  #hud .rec .dot { animation: blink 1s step-end infinite; }
  #hud .pipe { color: var(--dim); }
  #hud .pipe .on { color: var(--cyan); }
  #hud .pipe .done { color: var(--green); }
  #hud .blurb { color: var(--dim); }
  @keyframes blink { 50% { opacity: 0; } }
  main { display: grid; grid-template-columns: 1fr minmax(280px, 340px); flex: 1; min-height: 0; }
  .stage { position: relative; min-width: 0; min-height: 0; overflow: hidden;
    background:
      radial-gradient(ellipse at 28% 18%, rgba(110,231,245,0.08), transparent 42%),
      radial-gradient(ellipse at 82% 86%, rgba(232,121,249,0.06), transparent 40%),
      #070a10; }
  .stage::before {
    content: ""; position: absolute; inset: 0; pointer-events: none; z-index: 0;
    background-image:
      linear-gradient(rgba(110,231,245,0.03) 1px, transparent 1px),
      linear-gradient(90deg, rgba(110,231,245,0.03) 1px, transparent 1px);
    background-size: 52px 52px;
    mask-image: radial-gradient(ellipse at center, #000 20%, transparent 78%);
  }
  canvas { position: relative; z-index: 1; width: 100%; height: 100%; display: block;
    background: transparent; touch-action: none; cursor: grab; }
  canvas.grabbing { cursor: grabbing; }
  .float {
    position: absolute; z-index: 2; display: flex; gap: 6px; flex-wrap: wrap;
  }
  .toolbar { left: 12px; bottom: 12px; }
  .hint-keys { right: 12px; bottom: 12px; max-width: 46%;
    color: var(--dim); font-size: 11px; pointer-events: none; text-align: right;
    text-shadow: 0 1px 8px #070a10; }
  .float button {
    background: var(--glass); color: var(--ink); border: 1px solid var(--line);
    border-radius: 8px; padding: 6px 10px; font: 12px/1 system-ui, sans-serif;
    cursor: pointer; backdrop-filter: blur(8px);
    transition: transform .18s var(--ease), border-color .18s, color .18s, box-shadow .18s;
  }
  .float button:hover { border-color: var(--cyan); color: var(--cyan); transform: translateY(-1px); }
  .float button:active { transform: scale(0.96); }
  .float button.on { border-color: var(--cyan); color: var(--cyan);
    box-shadow: 0 0 0 1px rgba(110,231,245,.2) inset, 0 8px 20px rgba(110,231,245,.08); }
  aside {
    border-left: 1px solid var(--line); background: var(--panel);
    padding: 18px 18px 28px; overflow: auto; backdrop-filter: blur(16px);
  }
  .panel-enter { animation: rise .48s var(--ease) both; }
  .rise { animation: rise .5s var(--ease) both; animation-delay: calc(var(--i, 0) * 42ms); }
  aside h2 { margin: 0 0 4px; font-size: 20px; letter-spacing: -0.02em; line-height: 1.25; }
  aside .lede { color: var(--dim); margin: 0 0 14px; }
  aside p { margin: 0 0 12px; }
  aside h3 { font-size: 10px; text-transform: uppercase; letter-spacing: .12em;
    color: var(--dim); margin: 18px 0 8px; }
  .kicker { color: var(--cyan); font-size: 10px; letter-spacing: .14em; text-transform: uppercase;
    font-weight: 700; margin-bottom: 4px; }
  .badge {
    display: inline-flex; align-items: center; gap: 6px;
    border-radius: 999px; padding: 2px 8px; font-size: 11px;
    border: 1px solid var(--line); color: var(--dim); margin-right: 6px;
  }
  .badge .swatch { width: 7px; height: 7px; border-radius: 50%; }
  .meter { height: 6px; background: #1a2430; border-radius: 99px; overflow: hidden; margin: 8px 0 14px; }
  .meter > span { display: block; height: 100%; width: 0; background: linear-gradient(90deg, var(--cyan), var(--magenta));
    border-radius: 99px; transition: width .8s var(--ease); }
  .stats { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin: 12px 0 4px; }
  .stats div { background: #0c1218; border: 1px solid var(--line); border-radius: 8px; padding: 8px 10px; }
  .stats b { display: block; font-size: 16px; color: var(--ink); }
  .stats span { color: var(--dim); font-size: 11px; }
  .syn { display: flex; align-items: center; gap: 8px; padding: 7px 0; color: var(--ink); cursor: pointer;
    border: 0; border-bottom: 1px solid var(--line); text-decoration: none; font: inherit; font-size: 13px;
    background: none; width: 100%; text-align: left;
    transition: color .15s, padding-left .2s var(--ease); }
  .syn:hover { color: var(--cyan); padding-left: 4px; }
  .syn .dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
  .syn .idx { color: var(--dim); font: 11px ui-monospace, Menlo, monospace; width: 1.2em; }
  .syn em { color: var(--magenta); font-style: normal; font-size: 11px; margin-left: auto; white-space: nowrap; }
  .chips-inline { display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 12px; }
  .alias { background: #141c26; border: 1px solid var(--line); border-radius: 6px;
    padding: 2px 7px; font-size: 11px; color: var(--dim); }
  .moment { color: var(--dim); font-size: 12px; padding: 4px 0; border-bottom: 1px solid var(--line); }
  .moment b { color: var(--cyan); font-weight: 600; font-variant-numeric: tabular-nums; margin-right: 6px; }
  .empty { color: var(--dim); }
  .hint, .cli { color: var(--dim); font-size: 12px; margin-top: 16px; }
  .cli code { display: block; background: #0a0e14; border: 1px solid var(--line); border-radius: 6px;
    padding: 8px 10px; margin-top: 6px; color: var(--cyan); font: 11px/1.45 ui-monospace, Menlo, monospace; }
  .back { background: none; border: 0; color: var(--dim); cursor: pointer; font: 12px system-ui;
    padding: 0; margin-bottom: 8px; transition: color .15s, transform .2s var(--ease); }
  .back:hover { color: var(--cyan); transform: translateX(-2px); }
  .tip {
    position: absolute; z-index: 4; pointer-events: none; width: min(260px, 70%);
    background: rgba(12,18,26,.94); border: 1px solid var(--line); border-radius: 12px;
    padding: 10px 12px; box-shadow: 0 18px 50px rgba(0,0,0,.45); backdrop-filter: blur(14px);
    opacity: 0; left: 0; top: 0; will-change: transform, opacity;
  }
  .tip strong { display: block; font-size: 13px; margin-top: 2px; }
  .tip p { margin: 6px 0 0; color: var(--dim); font-size: 12px; }
  .coach {
    position: absolute; z-index: 3; left: 50%; top: 18px; transform: translateX(-50%);
    background: var(--glass); border: 1px solid var(--line); color: var(--ink);
    border-radius: 999px; padding: 8px 14px; font-size: 12px; backdrop-filter: blur(10px);
    box-shadow: 0 10px 30px rgba(0,0,0,.25); animation: drop-in .7s var(--ease) .15s both;
    pointer-events: none; white-space: nowrap;
  }
  .coach.hide { animation: fade-out .4s var(--ease) both; }
  @keyframes rise {
    from { opacity: 0; transform: translateY(14px); }
    to { opacity: 1; transform: none; }
  }
  @keyframes pop {
    from { opacity: 0; transform: translateY(-8px) scale(0.96); }
    to { opacity: 1; transform: none; }
  }
  @keyframes drop-in {
    from { opacity: 0; transform: translateY(-10px); }
    to { opacity: 1; transform: none; }
  }
  @keyframes fade-out {
    to { opacity: 0; transform: translate(-50%, -8px); }
  }
  @media (prefers-reduced-motion: reduce) {
    #hud .rec .dot, header, .panel-enter, .rise, #suggest, .coach { animation: none !important; }
    .meter > span, header input, .chip, .float button, .syn { transition: none !important; }
  }
  @media (max-width: 840px) {
    main { grid-template-columns: 1fr; grid-template-rows: 58% 42%; }
    aside { border-left: 0; border-top: 1px solid var(--line); }
    .search-wrap, header input { width: 100%; min-width: 0; margin-left: 0; }
    .hint-keys { display: none; }
  }
</style>
</head>
<body class="__BODY_CLASS__">
<header>
  <span class="wave">▁▂▃▅▇</span>
  <div class="brand-wrap">
    <span class="brand">CatchMeUp</span>
    <span class="meta" id="meta">__SLUG__</span>
  </div>
  <div class="search-wrap">
    <input id="q" type="search" placeholder="find a concept" autocomplete="off" spellcheck="false">
    <div id="suggest" hidden></div>
  </div>
  <div class="chips" id="chips"></div>
</header>
__HUD__
<main>
  <div class="stage">
    <canvas id="c"></canvas>
    <div class="float toolbar">
      <button type="button" id="btn-fit" title="Fit graph (F)">Fit</button>
      <button type="button" id="btn-iso" title="Isolate neighborhood (I)">Isolate</button>
      <button type="button" id="btn-labels" title="Show more labels (L)">Labels</button>
      <button type="button" id="btn-phys" title="Let synapses pull (Space)">Physics</button>
    </div>
    <div class="hint-keys">drag to pan · scroll to zoom · click a concept</div>
    <div class="coach" id="coach">Click a concept to open it · drag the canvas to look around</div>
    <div class="tip" id="tip" hidden>
      <div class="kicker" id="tip-kind"></div>
      <strong id="tip-title"></strong>
      <p id="tip-def"></p>
    </div>
  </div>
  <aside id="panel"></aside>
</main>
<script>
const DATA = __DATA__;
const KIND_META = {
  term: { color: "#6ee7f5", label: "term" },
  topic: { color: "#93c5fd", label: "topic" },
  moment: { color: "#e879f9", label: "moment" },
  person: { color: "#fbbf24", label: "person" },
  study: { color: "#86efac", label: "study" },
  action: { color: "#fdba74", label: "action" },
  episode: { color: "#8b9bb4", label: "episode" }
};
const EDGE_TINT = {
  with: "rgba(110,231,245,0.22)",
  "heard-at": "rgba(232,121,249,0.32)",
  exam: "rgba(134,239,172,0.28)",
  owns: "rgba(251,191,36,0.28)"
};
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const canvas = document.getElementById("c");
const ctx = canvas.getContext("2d");
const panel = document.getElementById("panel");
const q = document.getElementById("q");
const suggest = document.getElementById("suggest");
const chipsEl = document.getElementById("chips");
const tip = document.getElementById("tip");
const coach = document.getElementById("coach");
const totals = DATA.totals || { nodes: DATA.nodes.length, edges: DATA.edges.length };

function esc(s) {
  return String(s || "").replace(/[&<>"']/g, c => ({
    "&":"&amp;","<":"&lt;",">":"&gt;","\u0022":"&quot;","'":"&#39;"
  }[c]));
}
function fmt(n) { return Number(n || 0).toLocaleString(); }
function kindColor(kind) { return (KIND_META[kind] || KIND_META.term).color; }
function rgba(hex, a) {
  const n = parseInt(String(hex).slice(1), 16);
  return "rgba(" + ((n >> 16) & 255) + "," + ((n >> 8) & 255) + "," + (n & 255) + "," + a + ")";
}
function outBack(t) {
  const c = 1.70158, x = t - 1;
  return x * x * ((c + 1) * x + c) + 1;
}
function Spring(value, k, d) {
  this.value = value; this.target = value; this.vel = 0; this.k = k; this.d = d;
}
Spring.prototype.goto = function(v) { this.target = v; return this; };
Spring.prototype.snap = function(v) { this.value = this.target = v; this.vel = 0; return this; };
Spring.prototype.nudge = function(dv) { this.value += dv; this.target = this.value; this.vel = 0; };
Spring.prototype.step = function(dt) {
  dt = Math.min(0.033, dt);
  if (reduceMotion) { this.value = this.target; this.vel = 0; return this.value; }
  this.vel += ((this.target - this.value) * this.k - this.vel * this.d) * dt;
  this.value += this.vel * dt;
  if (Math.abs(this.vel) < 0.002 && Math.abs(this.value - this.target) < 0.002) {
    this.value = this.target; this.vel = 0;
  }
  return this.value;
};

document.getElementById("meta").innerHTML =
  "<b>" + esc(DATA.slug) + "</b> · " + fmt(DATA.nodes.length) +
  (DATA.nodes.length !== totals.nodes ? " of " + fmt(totals.nodes) : "") +
  " concepts · " + fmt(DATA.edges.length) + " synapses";

let W = 0, H = 0, scale = 1, ox = 0, oy = 0;
const camS = new Spring(0.85, 140, 18);
const camX = new Spring(0, 88, 16);
const camY = new Spring(0, 88, 16);
const tipX = new Spring(24, 260, 26);
const tipY = new Spring(24, 260, 26);
const tipA = new Spring(0, 240, 24);
const kindOff = new Set();
const kindOrder = Object.keys(KIND_META);
const presentKinds = kindOrder.filter(k => DATA.nodes.some(n => n.kind === k));
const nodes = DATA.nodes.map((n, i) => Object.assign({}, n, {
  x: 0, y: 0, tx: 0, ty: 0,
  vx: 0, vy: 0,
  r: 4.2 + Math.min(11, Math.sqrt(n.weight || 1) * 2.6),
  pop: 0, popDelay: (i % 24) * 0.012,
  al: 0, hs: 1, punch: 0
}));
const byId = Object.fromEntries(nodes.map(n => [n.id, n]));
const edges = DATA.edges.map(e => ({...e, a: byId[e.a], b: byId[e.b]})).filter(e => e.a && e.b);
const neighborsOf = new Map();
for (const e of edges) {
  if (!neighborsOf.has(e.a)) neighborsOf.set(e.a, new Set());
  if (!neighborsOf.has(e.b)) neighborsOf.set(e.b, new Set());
  neighborsOf.get(e.a).add(e.b);
  neighborsOf.get(e.b).add(e.a);
}
function seedBySynapses() {
  const golden = Math.PI * (3 - Math.sqrt(5));
  const order = nodes.slice().sort((a, b) => (b.degree - a.degree) || (b.weight - a.weight));
  const placed = new Set();
  for (let i = 0; i < order.length; i++) {
    const n = order[i];
    let ax = 0, ay = 0, wsum = 0;
    const nb = neighborsOf.get(n);
    if (nb) {
      for (const o of nb) {
        if (!placed.has(o)) continue;
        const w = 1 + (o.weight || 1);
        ax += o.x * w; ay += o.y * w; wsum += w;
      }
    }
    const a = i * golden;
    if (wsum) {
      const rad = 42 + 16 * Math.sqrt(1 + (n.degree || 1));
      n.x = ax / wsum + Math.cos(a) * rad;
      n.y = ay / wsum + Math.sin(a) * rad * 0.92;
    } else {
      const r = 40 + Math.sqrt(placed.size + 1) * 38;
      n.x = Math.cos(a) * r;
      n.y = Math.sin(a) * r * 0.92;
    }
    n.tx = n.x; n.ty = n.y;
    n.popDelay = Math.hypot(n.x, n.y) / 520 + (i % 24) * 0.012;
    placed.add(n);
  }
}
seedBySynapses();
const autoLabel = new Set(
  nodes.slice().sort((a, b) => b.weight - a.weight || b.degree - a.degree).slice(0, 14)
);
let selected = null, hovered = null, dragged = null, isolate = false, labelsOn = false, paused = true;
let filter = "", sugIndex = -1, born = 0;
let isoHold = null;
let panning = false, moved = 0, lastX = 0, lastY = 0, panDx = 0, panDy = 0, lastDt = 0.016;
const ripples = [];

function resize() {
  const dpr = window.devicePixelRatio || 1;
  W = canvas.clientWidth; H = canvas.clientHeight;
  canvas.width = Math.max(1, W * dpr); canvas.height = Math.max(1, H * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
}
window.addEventListener("resize", resize);
resize();

function blob(n) {
  if (!n._blob) n._blob = (n.id + " " + (n.definition || "") + " " + (n.aliases || []).join(" ")).toLowerCase();
  return n._blob;
}
function nameBlob(n) {
  if (!n._name) n._name = (n.id + " " + (n.aliases || []).join(" ")).toLowerCase();
  return n._name;
}
function normalizeQuery(raw) {
  let s = String(raw || "").trim().toLowerCase();
  if (s === "/" || s === "?") return "";
  if (s.charAt(0) === "/") s = s.slice(1).trim();
  return s;
}
function matchesQuery(n, query) {
  if (!query) return true;
  if (nameBlob(n).includes(query)) return true;
  if (query.length >= 3 && blob(n).includes(query)) return true;
  return false;
}
function isOn(n) {
  if (kindOff.has(n.kind)) return false;
  if (filter && !matchesQuery(n, filter)) return false;
  if (isolate && selected) {
    if (n === selected) return true;
    return !!(neighborsOf.get(selected) && neighborsOf.get(selected).has(n));
  }
  return true;
}
function hopList(n) {
  return edges.filter(e => e.a === n || e.b === n)
    .sort((x, y) => y.weight - x.weight);
}

function bboxOf(list) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity, count = 0;
  for (const n of list) {
    minX = Math.min(minX, n.x); maxX = Math.max(maxX, n.x);
    minY = Math.min(minY, n.y); maxY = Math.max(maxY, n.y);
    count += 1;
  }
  if (!count) return null;
  return { minX, minY, maxX, maxY, cx: (minX + maxX) / 2, cy: (minY + maxY) / 2 };
}
function cameraTo(list, pad) {
  const box = bboxOf(list);
  if (!box) return;
  const bw = Math.max(90, box.maxX - box.minX + (pad || 160));
  const bh = Math.max(90, box.maxY - box.minY + (pad || 140));
  const next = Math.min(2.6, Math.max(0.22, Math.min((W || 800) / bw, (H || 500) / bh) * 0.86));
  camS.goto(next);
  camX.goto(-box.cx * next);
  camY.goto(-box.cy * next);
}
function visibleList() { return nodes.filter(isOn); }
function centroidOf(list) {
  if (!list || !list.length) return null;
  let x = 0, y = 0;
  for (const n of list) { x += n.x; y += n.y; }
  return { x: x / list.length, y: y / list.length };
}
function captureHold(list) {
  isoHold = centroidOf(list || visibleList());
}
function freezeNodes() {
  for (const n of nodes) { n.vx = 0; n.vy = 0; }
}

function tick() {
  if (paused) return;
  const live = nodes.filter(isOn);
  if (!live.length) return;
  for (const e of edges) {
    if (!isOn(e.a) || !isOn(e.b)) continue;
    const dx = e.b.x - e.a.x, dy = e.b.y - e.a.y;
    const dist = Math.sqrt(dx * dx + dy * dy) || 0.01;
    const deg = Math.sqrt((e.a.degree || 1) * (e.b.degree || 1));
    const rest = 82 + 4.5 * Math.sqrt((e.a.degree || 1) + (e.b.degree || 1));
    const strength = 0.12 / Math.max(1.2, deg);
    const f = strength * (dist - rest);
    const fx = f * dx / dist, fy = f * dy / dist;
    if (e.a !== dragged) { e.a.vx += fx; e.a.vy += fy; }
    if (e.b !== dragged) { e.b.vx -= fx; e.b.vy -= fy; }
  }
  const kr = 3200;
  for (let i = 0; i < live.length; i++) {
    const n = live[i];
    if (n === dragged) continue;
    for (let j = 0; j < live.length; j++) {
      if (j === i) continue;
      const o = live[j];
      let dx = n.x - o.x, dy = n.y - o.y;
      let d2 = dx * dx + dy * dy;
      if (d2 < 0.4) {
        d2 = 0.4;
        dx = ((i * 13 + j) % 7) - 3 || 1;
        dy = ((i * 7 + j) % 5) - 2 || 1;
      }
      const d = Math.sqrt(d2);
      const minSep = n.r + o.r + 24;
      let f = kr / d2;
      if (d < minSep) f += (minSep - d) * 0.65;
      f = Math.min(10, f);
      n.vx += dx / d * f;
      n.vy += dy / d * f;
    }
  }
  const home = isolate && isoHold ? isoHold : { x: 0, y: 0 };
  for (const n of live) {
    if (n === dragged) { n.vx = 0; n.vy = 0; continue; }
    n.vx += -(n.x - home.x) * 0.001;
    n.vy += -(n.y - home.y) * 0.001;
    n.vx *= 0.8; n.vy *= 0.8;
    const sp2 = n.vx * n.vx + n.vy * n.vy;
    if (sp2 < 0.012) { n.vx = 0; n.vy = 0; continue; }
    n.vx = Math.max(-6, Math.min(6, n.vx));
    n.vy = Math.max(-6, Math.min(6, n.vy));
    n.x += n.vx; n.y += n.vy;
  }
  if (isolate && isoHold && !dragged) {
    const c = centroidOf(live);
    if (c) {
      const dx = (isoHold.x - c.x) * 0.28;
      const dy = (isoHold.y - c.y) * 0.28;
      if (dx * dx + dy * dy > 1e-6) {
        for (const n of live) { n.x += dx; n.y += dy; }
      }
    }
  }
}

function wakeLinks(amount) {
  const amp = amount || 0.06;
  for (const e of edges) {
    if (!isOn(e.a) || !isOn(e.b)) continue;
    const dx = e.b.x - e.a.x, dy = e.b.y - e.a.y;
    const dist = Math.hypot(dx, dy) || 1;
    const pull = (dist - 70) * amp;
    if (e.a !== dragged) { e.a.vx += dx / dist * pull; e.a.vy += dy / dist * pull; }
    if (e.b !== dragged) { e.b.vx -= dx / dist * pull; e.b.vy -= dy / dist * pull; }
  }
}

function toScreen(n) {
  return { x: n.x * scale + W / 2 + ox, y: n.y * scale + H / 2 + oy };
}
function fromScreen(sx, sy) {
  return { x: (sx - W / 2 - ox) / scale, y: (sy - H / 2 - oy) / scale };
}
function hit(sx, sy) {
  let best = null, bestD = 18;
  for (const n of nodes) {
    if (!isOn(n)) continue;
    const p = toScreen(n);
    const d = Math.hypot(p.x - sx, p.y - sy);
    const rad = n.r * Math.min(1.35, Math.max(0.65, scale)) + 8;
    if (d < rad && d < bestD + n.r) { best = n; bestD = d; }
  }
  return best;
}

function wantLabel(n) {
  if (n === selected || n === hovered) return true;
  if (filter && matchesQuery(n, filter)) return true;
  if (selected && neighborsOf.get(selected) && neighborsOf.get(selected).has(n)) return scale > 0.5;
  if (labelsOn) return scale > 0.55 || autoLabel.has(n);
  return autoLabel.has(n) && scale > 0.42;
}

function draw() {
  ctx.clearRect(0, 0, W, H);
  const pulse = reduceMotion ? 1 : 1 + 0.1 * Math.sin(born * 6);
  const nb = selected && neighborsOf.get(selected);
  for (let i = ripples.length - 1; i >= 0; i--) {
    const rp = ripples[i];
    const p = toScreen(rp);
    const life = rp.t / 0.7;
    if (life >= 1) { ripples.splice(i, 1); continue; }
    ctx.beginPath(); ctx.arc(p.x, p.y, 8 + life * 52, 0, Math.PI * 2);
    ctx.strokeStyle = rgba(rp.color, 0.55 * (1 - life));
    ctx.lineWidth = 2 * (1 - life);
    ctx.stroke();
  }
  for (const e of edges) {
    const aOn = isOn(e.a), bOn = isOn(e.b);
    if ((!aOn && e.a.al < 0.04) || (!bOn && e.b.al < 0.04)) continue;
    const hot = selected && (e.a === selected || e.b === selected);
    const a = toScreen(e.a), b = toScreen(e.b);
    if ((a.x < -50 && b.x < -50) || (a.x > W + 50 && b.x > W + 50)) continue;
    if ((a.y < -50 && b.y < -50) || (a.y > H + 50 && b.y > H + 50)) continue;
    const stretch = Math.min(1, Math.hypot(e.b.x - e.a.x, e.b.y - e.a.y) / 160);
    const dim = selected && !hot && paused;
    ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y);
    ctx.globalAlpha = Math.min(e.a.al, e.b.al) * (hot ? 1 : (dim ? 0.16 : 0.42 + stretch * 0.2));
    ctx.strokeStyle = hot ? "rgba(232,121,249,0.95)" : (EDGE_TINT[e.kind] || EDGE_TINT.with);
    ctx.lineWidth = hot ? 2.15 : Math.min(2.7, 0.5 + e.weight * 0.34);
    ctx.stroke();
    ctx.globalAlpha = 1;
  }
  const labelQueue = [];
  for (const n of nodes) {
    if (n.al < 0.02 && !isOn(n)) continue;
    const p = toScreen(n);
    if (p.x < -40 || p.y < -40 || p.x > W + 40 || p.y > H + 40) continue;
    const related = !selected || n === selected || (nb && nb.has(n));
    const pop = reduceMotion ? 1 : outBack(n.pop);
    const rad = n.r * (scale > 1.15 ? 1 : Math.max(0.55, scale)) * pop * n.hs * (1 + n.punch);
    ctx.globalAlpha = n.al;
    ctx.beginPath(); ctx.arc(p.x, p.y, rad * 2.4, 0, Math.PI * 2);
    ctx.fillStyle = rgba(kindColor(n.kind), n === selected ? 0.32 : 0.13);
    ctx.fill();
    ctx.beginPath(); ctx.arc(p.x, p.y, rad * (n === selected ? pulse : 1), 0, Math.PI * 2);
    ctx.fillStyle = kindColor(n.kind);
    ctx.fill();
    if (n === selected || n === hovered) {
      ctx.strokeStyle = "#fff"; ctx.lineWidth = n === selected ? 2 : 1.2; ctx.stroke();
    }
    ctx.globalAlpha = 1;
    if (wantLabel(n) && n.pop >= 0.55) labelQueue.push(n);
  }
  labelQueue.sort((a, b) => (b.weight - a.weight) || (b.degree - a.degree));
  const taken = [];
  for (const n of labelQueue) {
    const p = toScreen(n);
    const related = !selected || n === selected || (nb && nb.has(n));
    if (n !== selected && n !== hovered) {
      let clash = false;
      for (const t of taken) {
        if (Math.abs(t.x - p.x) < 78 && Math.abs(t.y - p.y) < 13) { clash = true; break; }
      }
      if (clash) continue;
    }
    taken.push(p);
    ctx.globalAlpha = n.al;
    ctx.fillStyle = related ? "#e8eef7" : "rgba(232,238,247,0.45)";
    ctx.font = (n === selected || n === hovered ? "600 " : "") + "12px ui-sans-serif, system-ui";
    ctx.fillText(n.id, p.x + 10, p.y + 4);
    ctx.globalAlpha = 1;
  }
}

function overviewHTML() {
  const counts = DATA.kind_counts || {};
  let stats = "";
  for (const k of presentKinds) {
    stats += '<div><b>' + fmt(counts[k] || 0) + "</b><span>" + esc((KIND_META[k] || {}).label || k) + "s</span></div>";
  }
  const top = nodes.slice().sort((a, b) => b.weight - a.weight || b.degree - a.degree).slice(0, 12);
  let hits = "";
  top.forEach((n, i) => {
    hits += '<button type="button" class="syn rise" style="--i:' + i + '" data-id="' + esc(n.id) + '"><span class="dot" style="background:' +
      kindColor(n.kind) + '"></span>' + esc(n.id) + "<em>w=" + n.weight + "</em></button>";
  });
  const clipped = DATA.nodes.length !== totals.nodes
    ? "<p class='lede rise' style='--i:2'>Showing the " + fmt(DATA.nodes.length) + " loudest of " + fmt(totals.nodes) + " concepts.</p>"
    : "";
  return '<div class="panel-enter"><div class="kicker">cortex</div><h2>' + esc(DATA.slug) + "</h2>" +
    "<p class='lede'>" + fmt(totals.nodes) + " concepts linked by " + fmt(totals.edges) +
    " synapses. Click a neuron, or press / to search.</p>" + clipped +
    '<div class="stats">' + stats + "</div><h3>Loudest</h3>" + hits +
    '<p class="hint">Drag to pan · scroll to zoom · press I to isolate a neighborhood · 1–9 hop</p></div>';
}

function renderPanel(n) {
  if (!n) {
    panel.innerHTML = overviewHTML();
    bindHops(panel);
    return;
  }
  const syns = hopList(n);
  const maxW = DATA.max_weight || n.weight || 1;
  let html = '<div class="panel-enter"><button class="back" id="back" type="button">← all concepts</button>';
  html += '<div class="kicker">neuron</div><h2>' + esc(n.id) + "</h2>";
  html += '<div><span class="badge"><span class="swatch" style="background:' + kindColor(n.kind) +
    '"></span>' + esc(n.kind) + "</span>";
  html += '<span class="badge">w=' + n.weight + "</span><span class='badge'>" + n.degree + " synapses</span></div>";
  html += '<div class="meter"><span data-w="' + Math.round(100 * n.weight / maxW) + '"></span></div>';
  if (n.first_seen) html += '<p class="lede">first ' + esc(n.first_seen) + (n.last_seen ? " · last " + esc(n.last_seen) : "") + "</p>";
  if (n.definition) html += "<p>" + esc(n.definition) + "</p>";
  if (n.aliases && n.aliases.length) {
    html += '<div class="chips-inline">' + n.aliases.map(a => '<span class="alias">' + esc(a) + "</span>").join("") + "</div>";
  }
  html += "<h3>Synapses</h3>";
  if (!syns.length) html += '<div class="empty">none yet</div>';
  syns.forEach((e, i) => {
    const other = e.a === n ? e.b : e.a;
    const num = i < 9 ? String(i + 1) : "";
    html += '<button type="button" class="syn rise" style="--i:' + i + '" data-id="' + esc(other.id) + '"><span class="idx">' + num +
      '</span><span class="dot" style="background:' + kindColor(other.kind) + '"></span>' +
      esc(other.id) + "<em>" + esc(e.kind) + " · w=" + e.weight + "</em></button>";
  });
  if (n.moments && n.moments.length) {
    html += "<h3>Heard</h3>";
    for (const m of n.moments) {
      html += '<div class="moment"><b>' + esc(m.timestamp || "?") + "</b>" +
        esc(m.heading || "") + (m.episode ? " — " + esc(m.episode) : "") + "</div>";
    }
  }
  if (n.episodes && n.episodes.length) {
    html += "<h3>Episodes</h3><div class='lede'>" + n.episodes.map(esc).join("<br>") + "</div>";
  }
  html += '<div class="cli">In the terminal<code>./catchup walk ' + esc(DATA.slug) + " " + esc(n.id) +
    "<br>./catchup clip " + esc(DATA.slug) + " " + esc(n.id) + "</code></div></div>";
  panel.innerHTML = html;
  const back = document.getElementById("back");
  if (back) back.addEventListener("click", () => select(null));
  bindHops(panel);
  const bar = panel.querySelector(".meter > span");
  if (bar) {
    const w = bar.getAttribute("data-w");
    requestAnimationFrame(() => { bar.style.width = w + "%"; });
  }
}
function bindHops(root) {
  root.querySelectorAll(".syn").forEach(el => {
    el.addEventListener("click", () => {
      const n = byId[el.getAttribute("data-id")];
      if (n) select(n);
    });
  });
}
function setHash(id) {
  try {
    if (id) history.replaceState(null, "", "#" + encodeURIComponent(id));
    else if (location.hash) history.replaceState(null, "", location.pathname + location.search);
  } catch (err) {}
}
function hideCoach() {
  if (coach && !coach.classList.contains("hide")) coach.classList.add("hide");
}

function select(n, opts) {
  selected = n || null;
  setHash(n ? n.id : "");
  renderPanel(n);
  if (n) {
    n.punch = opts && opts.quiet ? 0.2 : 0.38;
    if (!(opts && opts.quiet)) ripples.push({ x: n.x, y: n.y, t: 0, color: kindColor(n.kind) });
    hideCoach();
    if (!(opts && opts.quiet)) {
      const nb = neighborsOf.get(n);
      const focus = nb && nb.size ? [n, ...nb] : [n];
      cameraTo(focus, 120);
      if (isolate) captureHold(focus);
      if (!paused && nb) {
        for (const o of nb) {
          const dx = o.x - n.x, dy = o.y - n.y;
          const d = Math.hypot(dx, dy) || 1;
          o.vx += dx / d * 2.2;
          o.vy += dy / d * 2.2;
        }
      }
    }
  }
}

function renderChips() {
  chipsEl.innerHTML = presentKinds.map(k => {
    const on = !kindOff.has(k);
    return '<button type="button" class="chip ' + (on ? "on" : "off") + '" data-kind="' + k +
      '"><span class="swatch" style="background:' + kindColor(k) + '"></span>' +
      esc((KIND_META[k] || {}).label || k) + " " + fmt((DATA.kind_counts || {})[k] || 0) + "</button>";
  }).join("");
  chipsEl.querySelectorAll(".chip").forEach(el => {
    el.addEventListener("click", ev => {
      const k = el.getAttribute("data-kind");
      if (ev.shiftKey) {
        const only = kindOff.size === presentKinds.length - 1 && !kindOff.has(k);
        kindOff.clear();
        if (!only) presentKinds.forEach(x => { if (x !== k) kindOff.add(x); });
      } else if (kindOff.has(k)) kindOff.delete(k);
      else kindOff.add(k);
      renderChips();
      cameraTo(visibleList(), 140);
    });
  });
}
renderChips();
renderPanel(null);

function renderSuggest() {
  const query = normalizeQuery(q.value);
  if (!query) { suggest.hidden = true; sugIndex = -1; return; }
  const hits = nodes.filter(n => !kindOff.has(n.kind) && matchesQuery(n, query)).slice(0, 10);
  if (!hits.length) { suggest.hidden = true; sugIndex = -1; return; }
  suggest.hidden = false;
  suggest.innerHTML = hits.map((n, i) =>
    '<button type="button" data-id="' + esc(n.id) + '" class="' + (i === sugIndex ? "active" : "") +
    '"><span class="dot" style="background:' + kindColor(n.kind) + '"></span>' +
    esc(n.id) + "<em>" + esc(n.kind) + "</em></button>"
  ).join("");
  suggest.querySelectorAll("button").forEach(btn => {
    btn.addEventListener("mousedown", ev => ev.preventDefault());
    btn.addEventListener("click", () => {
      const n = byId[btn.getAttribute("data-id")];
      q.value = n.id; filter = normalizeQuery(n.id);
      suggest.hidden = true; select(n);
    });
  });
}

q.addEventListener("input", () => {
  if (q.value.trim() === "/") q.value = "";
  filter = normalizeQuery(q.value);
  sugIndex = 0;
  renderSuggest();
});
q.addEventListener("keydown", ev => {
  if (ev.key === "/" && !q.value) { ev.preventDefault(); return; }
  const buttons = [...suggest.querySelectorAll("button")];
  if (ev.key === "ArrowDown" && buttons.length) {
    ev.preventDefault(); sugIndex = Math.min(buttons.length - 1, sugIndex + 1); renderSuggest();
  } else if (ev.key === "ArrowUp" && buttons.length) {
    ev.preventDefault(); sugIndex = Math.max(0, sugIndex - 1); renderSuggest();
  } else if (ev.key === "Enter") {
    const pick = buttons[Math.max(0, sugIndex)] || buttons[0];
    if (pick && !suggest.hidden) { pick.click(); ev.preventDefault(); }
  } else if (ev.key === "Escape") {
    suggest.hidden = true; q.blur();
  }
});

function canvasPoint(ev) {
  const r = canvas.getBoundingClientRect();
  return { x: ev.clientX - r.left, y: ev.clientY - r.top };
}
function updateTip(n, p) {
  if (!tip) return;
  if (!n || panning || dragged) { tipA.goto(0); return; }
  document.getElementById("tip-kind").textContent = n.kind;
  document.getElementById("tip-title").textContent = n.id;
  document.getElementById("tip-def").textContent = n.definition || (n.degree + " synapses · w=" + n.weight);
  const tw = tip.offsetWidth || 220, th = tip.offsetHeight || 72;
  let x = p.x + 18, y = p.y + 16;
  if (x + tw > W - 10) x = p.x - tw - 14;
  if (y + th > H - 10) y = p.y - th - 14;
  if (tip.hidden || tipA.value < 0.05) { tipX.snap(x); tipY.snap(y); }
  else { tipX.goto(x); tipY.goto(y); }
  tip.hidden = false;
  tipA.goto(1);
}
canvas.addEventListener("mousedown", ev => {
  const p = canvasPoint(ev);
  const n = hit(p.x, p.y);
  moved = 0; lastX = p.x; lastY = p.y; panDx = 0; panDy = 0;
  hideCoach();
  if (n) { dragged = n; select(n, { quiet: true }); }
  else { panning = true; canvas.classList.add("grabbing"); }
});
window.addEventListener("mouseup", () => {
  if (panning) {
    camX.vel = panDx / Math.max(lastDt, 0.008);
    camY.vel = panDy / Math.max(lastDt, 0.008);
  }
  dragged = null; panning = false; canvas.classList.remove("grabbing");
});
canvas.addEventListener("mousemove", ev => {
  const p = canvasPoint(ev);
  const dx = p.x - lastX, dy = p.y - lastY;
  moved += Math.hypot(dx, dy);
  lastX = p.x; lastY = p.y;
  if (panning) {
    camX.nudge(dx); camY.nudge(dy); panDx = dx; panDy = dy;
    return;
  }
  if (dragged) {
    const w = fromScreen(p.x, p.y);
    dragged.x = w.x; dragged.y = w.y; dragged.vx = 0; dragged.vy = 0;
    return;
  }
  const n = hit(p.x, p.y);
  hovered = n;
  canvas.style.cursor = n ? "pointer" : "grab";
  updateTip(n, p);
});
canvas.addEventListener("mouseleave", () => { hovered = null; tipA.goto(0); });
canvas.addEventListener("wheel", ev => {
  ev.preventDefault();
  const p = canvasPoint(ev);
  const world = fromScreen(p.x, p.y);
  let dy = ev.deltaY;
  if (ev.deltaMode === 1) dy *= 16;
  else if (ev.deltaMode === 2) dy *= H || 400;
  const factor = Math.min(1.045, Math.max(0.957, Math.exp(-dy * 0.00085)));
  const next = Math.min(3.2, Math.max(0.18, camS.target * factor));
  camS.goto(next);
  camX.goto(p.x - W / 2 - world.x * next);
  camY.goto(p.y - H / 2 - world.y * next);
}, { passive: false });
canvas.addEventListener("dblclick", ev => {
  const p = canvasPoint(ev);
  const n = hit(p.x, p.y);
  if (n) { select(n); setIsolate(true); }
  else fitNow();
});
canvas.addEventListener("click", ev => {
  if (moved > 6) return;
  const p = canvasPoint(ev);
  const n = hit(p.x, p.y);
  if (n) select(n);
  else select(null);
});

function setIsolate(on) {
  isolate = !!on;
  document.getElementById("btn-iso").classList.toggle("on", isolate);
  const vis = visibleList();
  captureHold(vis);
  cameraTo(vis, 140);
}
function fitNow() {
  cameraTo(visibleList());
}
document.getElementById("btn-fit").addEventListener("click", fitNow);
document.getElementById("btn-iso").addEventListener("click", () => setIsolate(!isolate));
document.getElementById("btn-labels").addEventListener("click", () => {
  labelsOn = !labelsOn;
  document.getElementById("btn-labels").classList.toggle("on", labelsOn);
});
document.getElementById("btn-phys").addEventListener("click", () => {
  paused = !paused;
  document.getElementById("btn-phys").classList.toggle("on", !paused);
  const hint = document.querySelector(".hint-keys");
  if (paused) {
    freezeNodes();
    if (hint) hint.textContent = "drag to pan · scroll to zoom · click a concept";
  } else {
    if (isolate) captureHold();
    wakeLinks(0.07);
    if (hint) hint.textContent = "drag a concept — synapses tug neighbors";
  }
});

document.addEventListener("keydown", ev => {
  const typing = ev.target === q || ev.target.tagName === "INPUT" || ev.target.tagName === "TEXTAREA";
  if (ev.key === "/") {
    ev.preventDefault();
    q.focus();
    q.select();
    return;
  }
  if (ev.key === "Escape") {
    if (!suggest.hidden) { suggest.hidden = true; return; }
    if (q.value) { q.value = ""; filter = ""; renderSuggest(); return; }
    if (isolate) { setIsolate(false); return; }
    select(null); return;
  }
  if (typing) return;
  if (ev.key === "f" || ev.key === "F") fitNow();
  if (ev.key === "i" || ev.key === "I") setIsolate(!isolate);
  if (ev.key === "l" || ev.key === "L") document.getElementById("btn-labels").click();
  if (ev.key === " ") { ev.preventDefault(); document.getElementById("btn-phys").click(); }
  if (selected && /^[1-9]$/.test(ev.key)) {
    const syns = hopList(selected);
    const other = syns[Number(ev.key) - 1];
    if (other) select(other.a === selected ? other.b : other.a);
  }
});

paused = false;
for (let i = 0; i < 520; i++) tick();
(function unpack() {
  const box = bboxOf(nodes);
  if (!box) return;
  const span = Math.max(box.maxX - box.minX, box.maxY - box.minY, 1);
  if (span < 320) {
    const s = 360 / span;
    for (const n of nodes) { n.x *= s; n.y *= s; }
  }
})();
for (const n of nodes) n.pop = 1;
freezeNodes();
paused = true;
cameraTo(nodes, 150);
camS.snap(camS.target); camX.snap(camX.target); camY.snap(camY.target);
scale = camS.value; ox = camX.value; oy = camY.value;

const hash = decodeURIComponent((location.hash || "#").slice(1));
if (hash && byId[hash]) select(byId[hash]);
else if (DATA.focus && byId[DATA.focus]) select(byId[DATA.focus]);

function stepMotion(dt) {
  born += dt;
  lastDt = dt;
  const nb = selected && neighborsOf.get(selected);
  for (const n of nodes) {
    if (born > n.popDelay) n.pop = Math.min(1, n.pop + dt * 3.5);
    const related = !selected || n === selected || (nb && nb.has(n));
    const want = isOn(n) ? (related ? 1 : 0.2) : 0;
    n.al += (want - n.al) * (reduceMotion ? 1 : 0.16);
    const hsWant = (n === hovered || n === selected) ? 1.2 : 1;
    n.hs += (hsWant - n.hs) * (reduceMotion ? 1 : 0.22);
    n.punch *= 0.86;
  }
  for (const rp of ripples) rp.t += dt;
  camS.step(dt); camX.step(dt); camY.step(dt);
  tipX.step(dt); tipY.step(dt); tipA.step(dt);
  scale = camS.value; ox = camX.value; oy = camY.value;
  if (tip) {
    tip.style.transform = "translate(" + tipX.value + "px," + tipY.value + "px)";
    tip.style.opacity = String(Math.max(0, tipA.value));
    if (tipA.value < 0.03 && !hovered) tip.hidden = true;
  }
}

let lastNow = performance.now();
function loop(now) {
  const dt = Math.min(0.033, Math.max(0.008, (now - lastNow) / 1000)) || 0.016;
  lastNow = now;
  tick();
  stepMotion(dt);
  draw();
  requestAnimationFrame(loop);
}
requestAnimationFrame(loop);

(function animateWave() {
  const el = document.querySelector(".wave");
  if (!el || reduceMotion) return;
  const blocks = "▁▂▃▄▅▆▇█▇▆▅▄▃▂";
  let i = 0;
  setInterval(() => {
    i = (i + 1) % blocks.length;
    let s = "";
    for (let k = 0; k < 7; k++) s += blocks[(i + k) % blocks.length];
    el.textContent = s;
  }, 90);
})();
__DEMO_JS__
</script>
</body>
</html>
"""
