#!/usr/bin/env python3
from __future__ import annotations

from unittest.mock import patch

from catchmeup import chunking
from catchmeup import pipeline
from tests.support import IsolatedHome


def _long_transcript(n: int = 400) -> str:
    lines = []
    for i in range(n):
        h, rem = divmod(i * 9, 3600)
        m, s = divmod(rem, 60)
        lines.append(f"[{h:02d}:{m:02d}:{s:02d}] Line number {i} of the transcript.")
    return "\n".join(lines)


class ChunkingTests(IsolatedHome):
    def test_short_transcript_is_not_split(self):
        text = "[00:00:00] Hello.\n[00:00:18] Goodbye."
        self.assertEqual(chunking.transcript_chunks(text, max_characters=5_000), [text])

    def test_empty_produces_no_chunks(self):
        self.assertEqual(chunking.transcript_chunks("", max_characters=5_000), [])

    def test_every_line_survives(self):
        text = _long_transcript()
        self.assertGreater(len(text), 9_000)
        chunks = chunking.transcript_chunks(text, max_characters=5_000)
        self.assertGreater(len(chunks), 1)
        combined = "\n".join(chunks)
        for line in text.split("\n"):
            self.assertIn(line, combined)

    def test_chunks_overlap_at_the_seam(self):
        text = _long_transcript(200)
        chunks = chunking.transcript_chunks(text, max_characters=2_000)
        self.assertGreater(len(chunks), 2)
        first_last = chunks[0].split("\n")[-1]
        self.assertIn(first_last, chunks[1].split("\n"))

    def test_oversized_single_line_terminates(self):
        monster = "[00:00:00] " + ("word " * 3_000)
        text = monster + "\n[01:00:00] The end."
        chunks = chunking.transcript_chunks(text, max_characters=1_000)
        self.assertTrue(chunks)
        self.assertIn("The end.", "\n".join(chunks))

    def test_merge_single_part_is_unchanged(self):
        only = {"title": "Only", "tldr": ["a", "a"]}
        self.assertEqual(chunking.merge_analyses([only])["tldr"], ["a", "a"])

    def test_merge_title_from_first_nonempty(self):
        merged = chunking.merge_analyses(
            [{"title": "", "tldr": ["x"]}, {"title": "Lecture 12", "tldr": ["y"]}]
        )
        self.assertEqual(merged["title"], "Lecture 12")

    def test_merge_collapses_duplicate_bullets(self):
        merged = chunking.merge_analyses([
            {"tldr": ["Slicing uses start:stop:step", "Strings are immutable"]},
            {"tldr": ["Strings are immutable!", "Loops can walk a string"]},
        ])
        self.assertEqual(len(merged["tldr"]), 3)

    def test_merge_same_heading_becomes_one_section(self):
        merged = chunking.merge_analyses([
            {"detailed_notes": [{"heading": "Slicing", "content": "First half."}]},
            {"detailed_notes": [{"heading": "Slicing", "content": "Second half."}]},
        ])
        self.assertEqual(len(merged["detailed_notes"]), 1)
        self.assertIn("First half.", merged["detailed_notes"][0]["content"])
        self.assertIn("Second half.", merged["detailed_notes"][0]["content"])

    def test_merge_bookmarks_in_time_order(self):
        merged = chunking.merge_analyses([
            {"bookmarks": [{"timestamp": "00:40:00", "heading": "Late", "insight": "l"}]},
            {"bookmarks": [{"timestamp": "00:02:00", "heading": "Early", "insight": "e"}]},
        ])
        self.assertEqual([b["heading"] for b in merged["bookmarks"]], ["Early", "Late"])

    def test_merge_speaker_names_propagate(self):
        merged = chunking.merge_analyses([
            {"speakers": [{"label": "Speaker 1", "name": "", "said": "opened"}]},
            {"speakers": [{"label": "Speaker 1", "name": "Jordan", "said": ""}]},
        ])
        self.assertEqual(len(merged["speakers"]), 1)
        self.assertEqual(merged["speakers"][0]["name"], "Jordan")
        self.assertEqual(merged["speakers"][0]["said"], "opened")

    def test_call_llm_one_pass_when_short(self):
        calls = []

        def fake(prompt, log=None, **kwargs):
            calls.append(prompt)
            return {"title": "One", "tldr": ["hello"]}

        with patch("catchmeup.providers.complete_json", fake):
            out = pipeline.call_llm("[00:00:00] Hello there.", "lecture")
        self.assertEqual(len(calls), 1)
        self.assertEqual(out["title"], "One")
        self.assertNotIn("part 1 of", calls[0])

    def test_call_llm_multiple_passes_then_merges(self):
        text = _long_transcript(80)
        calls = []

        def fake(prompt, log=None, **kwargs):
            calls.append(prompt)
            n = len(calls)
            return {
                "title": f"Part {n}" if n == 1 else "",
                "tldr": [f"fact {n}"],
                "bookmarks": [
                    {"timestamp": f"00:0{n}:00", "heading": f"H{n}", "insight": "x"}
                ],
            }

        with patch("catchmeup.providers.complete_json", fake):
            with patch.dict("os.environ", {"CATCHMEUP_CHUNK_CHARS": "800"}):
                out = pipeline.call_llm(text, "lecture")
        self.assertGreater(len(calls), 1)
        self.assertIn("part 1 of", calls[0].lower())
        self.assertEqual(out["title"], "Part 1")
        self.assertGreaterEqual(len(out["tldr"]), 2)
        self.assertEqual(out["bookmarks"][0]["heading"], "H1")


if __name__ == "__main__":
    import unittest
    unittest.main()
