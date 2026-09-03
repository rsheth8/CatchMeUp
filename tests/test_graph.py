#!/usr/bin/env python3
from __future__ import annotations

from catchmeup import graph
from catchmeup import viz
from tests.support import IsolatedHome


class GraphPayloadTests(IsolatedHome):
    def test_demo_html_has_motion_ui(self):
        html = graph.render_graph_html("demo", viz.demo_cortex(), demo=True)
        self.assertIn('id="hud"', html)
        self.assertIn('id="tip"', html)
        self.assertIn('id="coach"', html)
        self.assertIn("function Spring", html)
        self.assertIn("panel-enter", html)
        self.assertIn("mutex", html)
        self.assertIn('class="is-demo"', html)

    def test_payload_keeps_focus_when_capped(self):
        self.seed_lecture("cs61a")
        data = graph.graph_payload("cs61a", limit=3, focus="mutex")
        ids = {n["id"] for n in data["nodes"]}
        self.assertIn("mutex", ids)
        self.assertIn("kind_counts", data)
        self.assertGreater(data["totals"]["nodes"], 0)
        self.assertTrue(any(n.get("degree", 0) >= 0 for n in data["nodes"]))

    def test_write_graph_embeds_brain(self):
        self.seed_lecture("cs61a")
        path = graph.write_graph("cs61a")
        text = path.read_text()
        self.assertIn("mutex", text.lower())
        self.assertIn("find a concept", text)
        self.assertIn("btn-fit", text)
        self.assertIn("freezeNodes", text)
        self.assertIn("paused = true", text)
        self.assertIn("seedBySynapses", text)
        self.assertIn("wakeLinks", text)
        self.assertIn("isoHold", text)
        self.assertIn("golden", text)
