#!/usr/bin/env python3
from __future__ import annotations

import os
import unittest

from catchmeup import cortex
from catchmeup import viz
from tests.support import IsolatedHome, LECTURE_ANALYSIS


class VizUnitTests(unittest.TestCase):
    def setUp(self):
        os.environ["CATCHMEUP_PLAIN"] = "1"
        os.environ.pop("CATCHMEUP_COLOR", None)
        os.environ.pop("FORCE_COLOR", None)
        os.environ.pop("NO_COLOR", None)

    def tearDown(self):
        os.environ.pop("CATCHMEUP_PLAIN", None)
        os.environ.pop("CATCHMEUP_COLOR", None)

    def test_banner_names_the_app(self):
        text = viz.banner()
        self.assertIn("CatchMeUp", text)
        self.assertIn("notes", text.lower())

    def test_waveform_length(self):
        self.assertEqual(len(viz.waveform(24)), 24)
        self.assertGreater(len(set(viz.waveform(32, phase=1.2))), 1)

    def test_pipeline_track_advances(self):
        early = viz.pipeline_track("audio")
        late = viz.pipeline_track("llm")
        done = viz.pipeline_track("done")
        self.assertIn("whisper", early)
        self.assertIn("llm", late)
        self.assertIn("notes", done)

    def test_rec_frame_and_exam_card(self):
        frame = viz.rec_frame(12.4)
        self.assertIn("REC", frame)
        self.assertIn("0:12", frame)
        card = viz.exam_card(6, 8, 8)
        self.assertIn("6/8", card)
        self.assertIn("B", card)
        blank = viz.exam_card(0, 0, 8)
        self.assertIn("quit", blank.lower())

    def test_timeline_places_bookmarks(self):
        track = viz.timeline([
            {"timestamp": "00:00:00", "heading": "start"},
            {"timestamp": "00:12:40", "heading": "mutex"},
            {"timestamp": "00:31:00", "heading": "exam"},
        ])
        self.assertIn("mutex", track)
        self.assertTrue(any(ch in track for ch in "*●"))

    def test_recap_card(self):
        card = viz.recap_card(LECTURE_ANALYSIS, "lecture", md_path="week3.md")
        self.assertIn("Mutex", card)
        self.assertIn("lecture recap", card)

    def test_plain_has_no_ansi(self):
        self.assertNotIn("\033[", viz.banner())
        self.assertNotIn("\033[", viz.pipeline_track("whisper"))

    def test_color_when_forced(self):
        os.environ.pop("CATCHMEUP_PLAIN", None)
        os.environ["CATCHMEUP_COLOR"] = "1"
        self.assertIn("\033[", viz.paint("cyan", "hello"))

    def test_walk_card_and_trace_path(self):
        card = viz.walk_card(
            {"id": "mutex", "kind": "term", "weight": 3, "definition": "a lock"},
            [{"id": "acquire", "label": "heard at", "weight": 2}],
            slug="cs61a",
        )
        self.assertIn("mutex", card)
        self.assertIn("acquire", card)
        traced = viz.trace_path(
            [{"from": "mutex", "to": "heaps", "label": "with", "weight": 1}],
            slug="cs61a",
        )
        self.assertIn("mutex", traced)
        self.assertIn("heaps", traced)
        sheet = viz.demo_sheet()
        self.assertIn("CatchMeUp", sheet)
        self.assertIn("mutex", sheet.lower())
        self.assertIn("spreading activation", sheet.lower())
        self.assertIn("score", sheet.lower())
        self.assertIn("demo --web", sheet)

    def test_box_never_exceeds_width(self):
        card = viz._box("neuron", ["A lock " * 40, "→ exam  " + "explain frames " * 20], width=60)
        for line in card.splitlines():
            self.assertLessEqual(viz._visible_len(line), 60, line)
        wide = viz.walk_card(
            {
                "id": "recursion",
                "kind": "term",
                "weight": 1,
                "definition": "A problem-solving approach where a function solves a problem by reducing it to simpler instances.",
            },
            [
                {
                    "id": "explain what a frame is in the context of recursion and how each call works",
                    "label": "exam",
                    "weight": 1,
                }
            ],
            slug="mit-60001",
        )
        cap = viz.term_width()
        for line in wide.splitlines():
            self.assertLessEqual(viz._visible_len(line), cap)

    def test_notes_table_aligns_long_names(self):
        text = viz.notes_table(
            "mit-60001",
            [
                {
                    "id": "method resolution order (mro)",
                    "kind": "term",
                    "weight": 4,
                    "moments": [{"timestamp": "00:02:31"}],
                },
                {"id": "class", "kind": "term", "weight": 5},
            ],
            12,
            synapses_of=lambda _nid: 20,
            limit=24,
        )
        self.assertIn("class", text)
        self.assertIn("method resolution order...", text)
        self.assertIn("2:31", text)
        table_row = next(ln for ln in text.splitlines() if "term" in ln and "4" in ln)
        self.assertLessEqual(len(table_row), 84)


class VizCortexTests(IsolatedHome):
    def test_cortex_map_from_seed(self):
        os.environ["CATCHMEUP_PLAIN"] = "1"
        self.addCleanup(lambda: os.environ.pop("CATCHMEUP_PLAIN", None))
        self.seed_lecture("cs61a")
        graph = cortex.load_cortex("cs61a")
        mapped = viz.cortex_map(graph, slug="cs61a")
        self.assertIn("mutex", mapped.lower())
        self.assertIn("cs61a", mapped)
        formatted = cortex.format_cortex("cs61a", query="mutex")
        self.assertIn("mutex", formatted.lower())
        self.assertIn("spreading activation", formatted.lower())


if __name__ == "__main__":
    unittest.main()
