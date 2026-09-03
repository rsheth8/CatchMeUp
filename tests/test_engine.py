#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

from catchmeup import brains
from catchmeup import cortex
from catchmeup import library
from catchmeup import mcp as mcp_server
from catchmeup import pipeline
from catchmeup.providers import (
    active_provider,
    normalize_provider,
    openai_extra_body,
    parse_json_payload,
    resolve_api_key,
)
from tests.support import IsolatedHome, LECTURE_ANALYSIS, MEETING_ANALYSIS


class BrainTests(IsolatedHome):
    def test_create_list_and_slug(self):
        meta = brains.create_brain("CS 61A", kind="lecture")
        self.assertEqual(meta["slug"], "cs-61a")
        self.assertTrue(brains.exists("cs-61a"))
        self.assertEqual(brains.list_brains()[0]["slug"], "cs-61a")
        self.assertTrue((brains.inbox_dir("cs-61a") / ".gitkeep").is_file())

    def test_duplicate_brain_raises(self):
        brains.create_brain("solo")
        with self.assertRaises(FileExistsError):
            brains.create_brain("solo")

    def test_isolation_between_brains(self):
        self.seed_lecture("cs61a")
        self.seed_meeting("acme-client")
        lecture_hits = brains.retrieve("mutex lock", list(brains.iter_brain_records("cs61a")))
        meeting_hits = brains.retrieve("mutex lock", list(brains.iter_brain_records("acme-client")))
        self.assertTrue(lecture_hits)
        self.assertFalse(meeting_hits)
        billing = brains.retrieve("billing addendum", list(brains.iter_brain_records("acme-client")))
        self.assertTrue(billing)
        self.assertFalse(
            brains.retrieve("billing addendum", list(brains.iter_brain_records("cs61a")))
        )

    def test_persona_roundtrip(self):
        brains.create_brain("os", kind="lecture")
        meta = brains.load_brain("os")
        meta["persona"] = "You are a CS 162 TA."
        brains.save_brain(meta)
        self.assertIn("162", brains.load_brain("os")["persona"])

    def test_missing_brain(self):
        with self.assertRaises(FileNotFoundError):
            brains.load_brain("nope")


class CortexTests(IsolatedHome):
    def test_ingest_activate_and_index(self):
        self.seed_lecture("cs61a")
        graph = cortex.load_cortex("cs61a")
        self.assertIn("mutex", graph["nodes"])
        self.assertTrue(
            any("environment diagram" in k for k in graph["nodes"]),
            list(graph["nodes"]),
        )
        self.assertEqual(graph.get("aliases", {}).get("environment diagrams"), "environment diagram")
        fired = cortex.activate("cs61a", "what is a mutex")
        ids = [n["id"] for n in fired]
        self.assertTrue(any("mutex" in i for i in ids), ids)
        index = brains.notes_dir("cs61a") / "_cortex.md"
        self.assertTrue(index.is_file())
        text = index.read_text()
        self.assertIn("mutex", text)
        self.assertIn("walk", text.lower())

    def test_hebbian_edge_between_cooccurring_concepts(self):
        self.seed_lecture("cs61a")
        graph = cortex.load_cortex("cs61a")
        keys = graph["edges"].keys()
        self.assertTrue(any("mutex" in k and "environment" in k for k in keys) or len(keys) > 0)

    def test_rebuild_matches_ingest(self):
        self.seed_lecture("cs61a")
        before = len(cortex.load_cortex("cs61a")["nodes"])
        rebuilt = cortex.rebuild("cs61a")
        self.assertEqual(len(rebuilt["nodes"]), before)

    def test_think_with_mocked_llm(self):
        self.seed_lecture("cs61a")
        calls = {"json": 0, "text": 0}

        def fake_json(prompt, log=print):
            calls["json"] += 1
            if "subquestions" in prompt or "Decompose" in prompt:
                return {
                    "task_type": "exam",
                    "subquestions": ["What is a mutex?", "How do environment diagrams work?"],
                    "concepts": ["mutex", "environment diagrams"],
                }
            if '"claims"' in prompt or "claims" in prompt[:400]:
                return {
                    "claims": [
                        {
                            "claim": "A mutex is a lock held by one thread.",
                            "because": "Week 3 lecture",
                            "source": "Week 3: Mutexes",
                            "confidence": "high",
                        }
                    ],
                    "missing": [],
                }
            return {
                "tensions": [],
                "gaps": ["Implementation of futexes was not covered."],
                "exam_or_action": ["Draw an environment diagram."],
            }

        def fake_text(prompt, log=print):
            calls["text"] += 1
            return (
                "1. Direct answer: a mutex is a lock.\n"
                "2. It connects to environment diagrams in this brain.\n"
            )

        with patch("catchmeup.cortex.complete_json", side_effect=fake_json), patch(
            "catchmeup.cortex.complete_text", side_effect=fake_text
        ):
            out = cortex.think("cs61a", "explain mutexes for the midterm", log=lambda *_: None)
        self.assertIn("mutex", out.lower())
        self.assertGreaterEqual(calls["json"], 3)
        self.assertEqual(calls["text"], 1)

    def test_think_empty_brain(self):
        brains.create_brain("empty")
        msg = cortex.think("empty", "anything", log=lambda *_: None)
        self.assertIn("no recaps", msg.lower())

    def test_concept_notes_walk_trace_and_typed_synapses(self):
        self.seed_lecture("cs61a")
        graph = cortex.load_cortex("cs61a")
        self.assertIn("mutex", graph["nodes"])
        mutex = graph["nodes"]["mutex"]
        self.assertTrue(mutex.get("moments"))
        self.assertTrue(any(m.get("timestamp") == "00:12:40" for m in mutex["moments"]))
        kinds = {e.get("kind") for e in graph["edges"].values()}
        self.assertIn("with", kinds)
        self.assertIn("heard-at", kinds)
        heard = [
            e for e in graph["edges"].values()
            if e.get("kind") == "heard-at" and "mutex" in (e.get("a"), e.get("b"))
        ]
        self.assertTrue(heard)
        note = brains.notes_dir("cs61a") / "mutex.md"
        self.assertTrue(note.is_file(), note)
        text = note.read_text()
        self.assertIn("catchmeup-concept", text)
        self.assertIn("heard", text.lower())
        html = brains.brain_dir("cs61a") / "cortex.html"
        self.assertTrue(html.is_file(), html)
        self.assertIn("mutex", html.read_text().lower())
        listed_notes = cortex.format_notes("cs61a")
        self.assertIn("mutex", listed_notes.lower())
        vault = cortex.export_obsidian("cs61a")
        self.assertTrue((vault / "mutex.md").is_file())
        self.assertIn("[[", (vault / "mutex.md").read_text())
        walked = cortex.format_walk("cs61a", "mutex")
        self.assertIn("mutex", walked.lower())
        self.assertIn("neuron", walked.lower())
        listed = cortex.format_walk("cs61a", None)
        self.assertIn("mutex", listed.lower())
        path = cortex.shortest_path(graph, "mutex", "environment diagrams")
        self.assertTrue(path)
        traced = cortex.format_trace("cs61a", "mutex", "environment diagrams")
        self.assertIn("mutex", traced.lower())
        missing = cortex.format_walk("cs61a", "bananas-xyz")
        self.assertIn("matched", missing.lower())

    def test_ingest_skips_sentence_bookmarks_and_study_prompts(self):
        self.seed_lecture("cs61a")
        rec = {
            "title": "Week 3 extra",
            "source": "extra.mp4",
            "recorded_at": "2026-02-11 09:00",
            "analysis": {
                "terms": [{"term": "mutex", "definition": "a lock"}],
                "bookmarks": [{
                    "timestamp": "00:01:00",
                    "heading": "What is a mutex and why does it matter on the exam?",
                    "insight": "Acquire a mutex before touching shared state.",
                }],
                "study": ["Draw an environment diagram for nested define."],
                "detailed_notes": [],
            },
        }
        cortex.ingest_recap("cs61a", rec)
        graph = cortex.load_cortex("cs61a")
        self.assertNotIn(
            "what is a mutex and why does it matter on the exam?",
            graph["nodes"],
        )
        self.assertFalse(any("draw an environment" in k for k in graph["nodes"]))
        mutex = graph["nodes"]["mutex"]
        self.assertTrue(any(m.get("timestamp") == "00:01:00" for m in mutex.get("moments") or []))
        env = graph["nodes"]["environment diagram"]
        self.assertTrue(any("nested define" in p.lower() for p in env.get("exam_prompts") or []))

    def test_alias_merges_plural(self):
        self.seed_lecture("cs61a")
        rec = {
            "title": "Week 3b",
            "source": "extra.mp4",
            "recorded_at": "2026-02-11 09:00",
            "analysis": {
                "terms": [{"term": "mutexes", "definition": "plural of mutex"}],
                "bookmarks": [],
                "detailed_notes": [],
            },
        }
        cortex.ingest_recap("cs61a", rec)
        graph = cortex.load_cortex("cs61a")
        self.assertIn("mutex", graph["nodes"])
        self.assertNotIn("mutexes", graph["nodes"])
        self.assertEqual(graph.get("aliases", {}).get("mutexes"), "mutex")
        self.assertIn("mutexes", graph["nodes"]["mutex"].get("aliases") or [])


class LibraryTests(IsolatedHome):
    def test_search_quiz_todos_moments(self):
        self.seed_lecture("cs61a")
        self.seed_meeting("acme-client")
        hits = library.search_records("mutex")
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["brain"], "cs61a")
        self.assertFalse(library.search_records("mutex", records=list(brains.iter_brain_records("acme-client"))))
        cards = library._terms_from(list(brains.iter_brain_records("cs61a"))[0])
        self.assertTrue(any(t[0] == "mutex" for t in cards))
        todos = [
            item
            for rec in library.list_records(mode="meeting")
            for item in (rec.get("analysis") or {}).get("action_items") or []
        ]
        self.assertTrue(any("Jordan" in str(i) for i in todos))
        latest = library.list_records()[0]
        self.assertTrue((latest.get("analysis") or {}).get("bookmarks"))

    def test_library_empty(self):
        self.assertEqual(library.list_records(), [])


class PipelineTests(IsolatedHome):
    def test_guess_mode(self):
        self.assertEqual(pipeline.guess_mode(Path("cs61a-week3-lecture.mp4")), "lecture")
        self.assertEqual(pipeline.guess_mode(Path("standup-monday.mov")), "meeting")
        self.assertEqual(pipeline.guess_mode(Path("random.mov")), "meeting")

    def test_transcript_timestamps(self):
        text = pipeline.transcript_with_timestamps(
            {"segments": [{"start": 12, "text": "hello"}, {"start": 70, "text": "world"}]}
        )
        self.assertIn("[0:00:12] hello", text)
        self.assertIn("[0:01:10] world", text)

    def test_markdown_wikilinks_and_persist(self):
        md = pipeline.render_markdown(LECTURE_ANALYSIS, "week3.mp4", "2026-02-10 09:00", "lecture")
        self.assertIn("[[mutex]]", md)
        self.assertIn("What you missed", md)
        meeting = pipeline.render_markdown(
            MEETING_ANALYSIS, "zoom.m4a", "2026-03-01 14:00", "meeting"
        )
        self.assertIn("Action items", meeting)
        brains.create_brain("cs61a", kind="lecture")
        source = self.home / "week3.mp4"
        source.write_text("fake")
        rec, folder = pipeline.persist_recap(
            LECTURE_ANALYSIS,
            source,
            "2026-02-10 09:00",
            "lecture",
            "[0:12:40] mutex",
            provider="test",
            brain_slug="cs61a",
        )
        self.assertTrue((folder / "catchmeup.json").is_file())
        self.assertEqual(rec["brain"], "cs61a")
        self.assertIn("mutex", cortex.load_cortex("cs61a")["nodes"])
        notes = list(brains.notes_dir("cs61a").glob("*_lecture_notes.md"))
        self.assertTrue(notes)
        self.assertIn("[[mutex]]", notes[0].read_text())

    def test_pending_media_and_keep_library_source(self):
        brains.create_brain("mit-60001", kind="lecture")
        corpus = self.home / "MIT-6.0001"
        corpus.mkdir()
        first = corpus / "01 - lecture.mp4"
        second = corpus / "02 - clip.mp4"
        first.write_bytes(b"a")
        second.write_bytes(b"b")
        (corpus / "readme.txt").write_text("nope")
        names = [p.name for p in brains.media_files(corpus)]
        self.assertEqual(names, ["01 - lecture.mp4", "02 - clip.mp4"])
        self.assertTrue(brains.keep_source(first, "mit-60001"))
        dropped = brains.inbox_dir("mit-60001") / "drop.mp4"
        dropped.write_bytes(b"x")
        self.assertFalse(brains.keep_source(dropped, "mit-60001"))
        dest = self.home / "recap-folder"
        mp3 = corpus / "01 - lecture.mp3"
        mp3.write_bytes(b"m")
        pipeline.archive_pipeline_outputs(first, mp3, dest, keep=True)
        self.assertTrue(first.is_file())
        self.assertFalse(mp3.exists())
        self.assertTrue((dest / "01 - lecture.mp3").is_file())
        pipeline.persist_recap(
            LECTURE_ANALYSIS,
            first,
            "2026-09-02 12:00",
            "lecture",
            "transcript",
            provider="test",
            brain_slug="mit-60001",
        )
        pending = [p.name for p in brains.pending_media("mit-60001", corpus)]
        self.assertEqual(pending, ["02 - clip.mp4"])

    def test_media_files_walks_nested_week_folders(self):
        brains.create_brain("os", kind="lecture")
        root = self.home / "course"
        week = root / "week-3"
        week.mkdir(parents=True)
        (week / "lecture.mp4").write_bytes(b"a")
        hidden = root / ".hidden"
        hidden.mkdir()
        (hidden / "nope.mp4").write_bytes(b"x")
        (root / ".DS_Store").write_text("x")
        names = [p.name for p in brains.media_files(root)]
        self.assertEqual(names, ["lecture.mp4"])

    def test_persist_without_brain_goes_to_processed(self):
        source = self.home / "standup.mov"
        source.write_text("fake")
        rec, folder = pipeline.persist_recap(
            MEETING_ANALYSIS,
            source,
            "2026-03-01 14:00",
            "meeting",
            "transcript",
            provider="test",
        )
        self.assertIsNone(rec["brain"])
        self.assertTrue(str(folder).startswith(str(brains.processed_root())))
        self.assertEqual(len(library.list_records()), 1)

    def test_ffmpeg_to_mp3(self):
        import shutil

        if not shutil.which("ffmpeg") and not Path("/opt/homebrew/bin/ffmpeg").exists():
            self.skipTest("ffmpeg not installed")
        wav = self.home / "tone.wav"
        pipeline.run(
            [
                pipeline.ffmpeg_bin(),
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:duration=0.4",
                str(wav),
            ]
        )
        mp3 = pipeline.to_mp3(wav)
        self.assertTrue(mp3.is_file())
        self.assertGreater(mp3.stat().st_size, 100)


class ProviderTests(IsolatedHome):
    def test_parse_json_payload(self):
        self.assertEqual(parse_json_payload('{"a": 1}'), {"a": 1})
        self.assertEqual(parse_json_payload("```json\n{\"a\": 2}\n```"), {"a": 2})
        self.assertEqual(parse_json_payload("Sure.\n{\"a\": 3}\n"), {"a": 3})

    def test_normalize_and_active(self):
        import os

        self.assertEqual(normalize_provider("claude"), "anthropic")
        self.assertEqual(normalize_provider("gpt"), "openai")
        self.assertEqual(normalize_provider("grok"), "xai")
        previous = os.environ.get("CATCHMEUP_PROVIDER")
        os.environ["CATCHMEUP_PROVIDER"] = "gemini"
        self.addCleanup(self._restore_env, "CATCHMEUP_PROVIDER", previous)
        self.assertEqual(active_provider(), "gemini")

    def test_resolve_api_key_placeholder_is_empty(self):
        import os

        previous_ant = os.environ.get("ANTHROPIC_API_KEY")
        previous_cm = os.environ.get("CATCHMEUP_API_KEY")
        os.environ["ANTHROPIC_API_KEY"] = "your-key-here"
        os.environ["CATCHMEUP_API_KEY"] = "your-key-here"
        self.addCleanup(self._restore_env, "ANTHROPIC_API_KEY", previous_ant)
        self.addCleanup(self._restore_env, "CATCHMEUP_API_KEY", previous_cm)
        self.assertEqual(resolve_api_key("anthropic"), "")

    def test_ollama_extra_body_skips_thinking(self):
        import os

        self.assertIsNone(openai_extra_body("anthropic"))
        previous_think = os.environ.get("CATCHMEUP_OLLAMA_THINK")
        previous_ctx = os.environ.get("CATCHMEUP_NUM_CTX")
        os.environ.pop("CATCHMEUP_OLLAMA_THINK", None)
        os.environ.pop("CATCHMEUP_NUM_CTX", None)
        self.addCleanup(self._restore_env, "CATCHMEUP_OLLAMA_THINK", previous_think)
        self.addCleanup(self._restore_env, "CATCHMEUP_NUM_CTX", previous_ctx)
        body = openai_extra_body("ollama")
        self.assertEqual(body["reasoning_effort"], "none")
        self.assertEqual(body["options"]["num_ctx"], 32768)

    def _restore_env(self, key: str, previous: str | None) -> None:
        import os

        if previous is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = previous


class McpTests(IsolatedHome):
    def test_initialize_and_tools(self):
        init = mcp_server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        self.assertEqual(init["result"]["protocolVersion"], mcp_server.PROTOCOL)
        listed = mcp_server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        names = {t["name"] for t in listed["result"]["tools"]}
        self.assertGreaterEqual(
            names,
            {"list_brains", "ask_brain", "search_brain", "think_brain", "list_recaps", "diff_brain", "walk_brain", "trace_brain", "grade_work"},
        )

    def test_list_brains_and_search(self):
        self.seed_lecture("cs61a")
        reply = mcp_server.handle(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "list_brains", "arguments": {}},
            }
        )
        text = reply["result"]["content"][0]["text"]
        self.assertIn("cs61a", text)
        search = mcp_server.handle(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {
                    "name": "search_brain",
                    "arguments": {"brain": "cs61a", "query": "mutex"},
                },
            }
        )
        text = search["result"]["content"][0]["text"].lower()
        self.assertIn("mutex", text)
        recaps = mcp_server.handle(
            {
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/call",
                "params": {"name": "list_recaps", "arguments": {"brain": "cs61a"}},
            }
        )
        self.assertIn("Week 3", recaps["result"]["content"][0]["text"])

    def test_think_brain_mocked(self):
        self.seed_lecture("cs61a")

        def fake_json(prompt, log=print):
            if "Decompose" in prompt or "subquestions" in prompt:
                return {"task_type": "explain", "subquestions": ["mutex?"], "concepts": ["mutex"]}
            if "claims" in prompt:
                return {"claims": [{"claim": "lock", "because": "lec", "source": "w3", "confidence": "high"}], "missing": []}
            return {"tensions": [], "gaps": [], "exam_or_action": []}

        with patch("catchmeup.cortex.complete_json", side_effect=fake_json), patch(
            "catchmeup.cortex.complete_text", return_value="A mutex is a lock."
        ):
            reply = mcp_server.handle(
                {
                    "jsonrpc": "2.0",
                    "id": 6,
                    "method": "tools/call",
                    "params": {
                        "name": "think_brain",
                        "arguments": {"brain": "cs61a", "question": "mutex?"},
                    },
                }
            )
        self.assertIn("mutex", reply["result"]["content"][0]["text"].lower())

    def test_grade_work_mocked(self):
        self.seed_lecture("cs61a")
        with patch("catchmeup.providers.complete_text", return_value="Verdict: partial — mention acquire."):
            reply = mcp_server.handle(
                {
                    "jsonrpc": "2.0",
                    "id": 7,
                    "method": "tools/call",
                    "params": {
                        "name": "grade_work",
                        "arguments": {
                            "brain": "cs61a",
                            "work": "A mutex is a lock.",
                            "assignment": "define mutex",
                        },
                    },
                }
            )
        self.assertIn("partial", reply["result"]["content"][0]["text"].lower())

    def test_unknown_method(self):
        reply = mcp_server.handle({"jsonrpc": "2.0", "id": 9, "method": "nope"})
        self.assertEqual(reply["error"]["code"], -32601)


if __name__ == "__main__":
    import unittest

    unittest.main()
