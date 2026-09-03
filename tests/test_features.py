#!/usr/bin/env python3
from __future__ import annotations

import os
import random
from pathlib import Path
from unittest.mock import MagicMock, patch

from catchmeup import brains
from catchmeup import exam
from catchmeup import library
from catchmeup import pipeline
from catchmeup import record
from tests.support import IsolatedHome, MEETING_ANALYSIS


class DiarizeTests(IsolatedHome):
    def test_pretty_speaker(self):
        self.assertEqual(pipeline.pretty_speaker("SPEAKER_00"), "Speaker 1")
        self.assertEqual(pipeline.pretty_speaker("SPEAKER_01"), "Speaker 2")
        self.assertEqual(pipeline.pretty_speaker("Speaker 3"), "Speaker 3")
        self.assertEqual(pipeline.pretty_speaker("Jordan"), "Jordan")

    def test_want_diarize_defaults(self):
        os.environ.pop("CATCHMEUP_DIARIZE", None)
        self.assertTrue(pipeline.want_diarize("meeting"))
        self.assertFalse(pipeline.want_diarize("lecture"))
        os.environ["CATCHMEUP_DIARIZE"] = "0"
        self.assertFalse(pipeline.want_diarize("meeting"))
        os.environ["CATCHMEUP_DIARIZE"] = "1"
        self.assertTrue(pipeline.want_diarize("lecture"))
        os.environ.pop("CATCHMEUP_DIARIZE", None)

    def test_transcript_includes_speakers(self):
        text = pipeline.transcript_with_timestamps({
            "segments": [
                {"start": 8.1, "text": "usage based", "speaker": "SPEAKER_00"},
                {"start": 12, "text": "addendum", "speaker": "SPEAKER_01"},
            ]
        })
        self.assertIn("Speaker 1: usage based", text)
        self.assertIn("Speaker 2: addendum", text)

    def test_rttm_merge(self):
        rttm = self.home / "a.rttm"
        rttm.write_text(
            "SPEAKER file 1 0.0 5.0 <NA> <NA> SPEAKER_00 <NA> <NA>\n"
            "SPEAKER file 1 5.0 5.0 <NA> <NA> SPEAKER_01 <NA> <NA>\n"
        )
        data = {
            "segments": [
                {"start": 1.0, "end": 3.0, "text": "hello"},
                {"start": 6.0, "end": 8.0, "text": "there"},
            ]
        }
        merged = pipeline.apply_rttm(data, rttm)
        self.assertEqual(pipeline.segment_speaker(merged["segments"][0]), "Speaker 1")
        self.assertEqual(pipeline.segment_speaker(merged["segments"][1]), "Speaker 2")

    def test_meeting_markdown_lists_speakers(self):
        md = pipeline.render_markdown(MEETING_ANALYSIS, "zoom.m4a", "2026-03-01", "meeting")
        self.assertIn("Who spoke", md)
        self.assertIn("Jordan", md)


class ExamTests(IsolatedHome):
    def test_build_and_grade(self):
        self.seed_lecture("cs61a")
        questions = exam.build_exam(list(brains.iter_brain_records("cs61a")), count=6, rng=random.Random(0))
        self.assertTrue(questions)
        self.assertTrue(any("mutex" in q["prompt"].lower() or "mutex" in q["answer"].lower() for q in questions))
        define = next(q for q in questions if q["kind"] == "term" and "mutex" in q["prompt"].lower())
        self.assertIn("what is", define["prompt"].lower())
        self.assertNotIn("Define:", define["prompt"])
        result = exam.grade_answer(define, "a lock only one thread can hold")
        self.assertEqual(result["verdict"], "pass")
        miss = exam.grade_answer(define, "bananas")
        self.assertEqual(miss["verdict"], "miss")
        filler = exam.grade_answer(define, "only one can this that")
        self.assertEqual(filler["verdict"], "miss")
        printed = exam.format_exam(questions, answers=True)
        self.assertIn("CatchMeUp exam", printed)
        self.assertIn("mutex", printed.lower())
        self.assertFalse(any(q["prompt"].startswith("Define:") for q in questions))
        self.assertFalse(any("Why does" in q["prompt"] for q in questions))

    def test_paraphrase_and_specific_prompts(self):
        q = exam._term_question(
            "string concatenation",
            "The process of joining two or more strings together end-to-end to create a new string. In Python this uses +.",
            "strings lecture",
        )
        self.assertIsNotNone(q)
        self.assertIn("what is", q["prompt"].lower())
        self.assertEqual(
            exam.grade_answer(q, "joining two strings together with +")["verdict"],
            "pass",
        )
        moment = exam._moment_question(
            "Slice with step parameter: s[4::30]",
            "start=4, stop is the end, step=30; if the string is shorter you just get the character at 4.",
            "strings lecture",
            "0:01:55",
        )
        self.assertIsNotNone(moment)
        self.assertIn("s[4::30]", moment["prompt"])
        self.assertNotIn("will be on the exam", moment["answer"].lower())


class DiffTests(IsolatedHome):
    def test_lecture_drift(self):
        self.seed_lecture("cs61a")
        self.seed_lecture_week4("cs61a")
        rows = library.list_records(brain="cs61a")
        self.assertGreaterEqual(len(rows), 2)
        diff = library.diff_recaps(rows[0], rows[1])
        text = library.format_diff(diff)
        self.assertIn("heap", " ".join(diff["terms_added"]))
        self.assertIn("mutex", " ".join(diff["terms_dropped"]))
        self.assertIn("+", text)
        self.assertIn("−", text)


class ClipTests(IsolatedHome):
    def test_find_clip_mutex(self):
        self.seed_lecture("cs61a")
        hit = library.find_clip("mutex")
        self.assertIsNotNone(hit)
        self.assertIn("mutex", (hit["heading"] + hit["insight"]).lower())
        self.assertEqual(hit["timestamp"], "00:12:40")
        self.assertAlmostEqual(hit["start"], 12 * 60 + 40)

    def test_find_clip_isolated_to_brain(self):
        self.seed_lecture("cs61a")
        self.seed_meeting("acme-client")
        hit = library.find_clip("billing", brain="cs61a")
        self.assertIsNone(hit)
        hit = library.find_clip("billing", brain="acme-client")
        self.assertIsNotNone(hit)

    def test_clip_prefers_heading_over_aside(self):
        aside = {
            "title": "Big O",
            "source": "efficiency.mp4",
            "_dir": str(self.home),
            "analysis": {
                "bookmarks": [{
                    "timestamp": "00:25:00",
                    "heading": "Recursive vs Iterative Factorial",
                    "insight": "Both are O(n)—recursion adds overhead",
                }],
                "terms": [],
            },
        }
        main = {
            "title": "Recursion",
            "source": "recursion.mp4",
            "_dir": str(self.home),
            "analysis": {
                "bookmarks": [{
                    "timestamp": "00:02:10",
                    "heading": "What is Recursion?",
                    "insight": "Reducing a problem to a simpler version",
                }],
                "terms": [{"term": "recursion", "definition": "solve via smaller self"}],
            },
        }
        hit = library.find_clip("recursion", records=[aside, main])
        self.assertIsNotNone(hit)
        self.assertEqual(hit["timestamp"], "00:02:10")
        self.assertIn("recursion", hit["heading"].lower())

    def test_clip_uses_cortex_moment_when_brain_set(self):
        self.seed_lecture("cs61a")
        hit = library.find_clip("mutex", brain="cs61a")
        self.assertIsNotNone(hit)
        self.assertEqual(hit["timestamp"], "00:12:40")
        self.assertTrue(hit.get("concept") == "mutex" or "mutex" in hit["heading"].lower())

    def test_play_range_passes_afplay_a_file(self):
        from unittest.mock import patch

        audio = self.home / "lec.mp3"
        audio.write_bytes(b"xx")
        with patch("catchmeup.library.shutil.which", side_effect=lambda n: "/bin/true"):
            with patch("catchmeup.library.subprocess.run") as run:
                run.return_value = MagicMock(returncode=0)
                library.play_range(audio, 12.4, duration=2)
        cmds = [c.args[0] for c in run.call_args_list]
        self.assertTrue(cmds)
        ffmpeg_cmd = cmds[0]
        self.assertEqual(ffmpeg_cmd[-1][-4:], ".wav")
        self.assertNotIn("-", ffmpeg_cmd[-1:])
        afplay_cmd = cmds[1]
        self.assertEqual(afplay_cmd[0], "/bin/true")
        self.assertNotEqual(afplay_cmd[1], "-")
        self.assertTrue(str(afplay_cmd[1]).endswith(".wav"))

    def test_cortex_clip_lists_all_moments(self):
        self.seed_lecture("cs61a")
        clips = library.list_clips("mutex", brain="cs61a")
        self.assertGreaterEqual(len(clips), 1)
        self.assertEqual(clips[0]["timestamp"], "00:12:40")


class MemoryAndSpeakerTests(IsolatedHome):
    def test_exam_remembers_misses_and_drill_prefers_them(self):
        self.seed_lecture("cs61a")
        q = {"prompt": "Define: mutex", "answer": "a lock", "kind": "term", "source": "w3"}
        exam.record_attempt("cs61a", q, "miss", "bananas")
        exam.record_attempt("cs61a", q, "miss", "nope")
        weak = exam.weakest_concepts("cs61a")
        self.assertTrue(any("mutex" in c for c, _, _ in weak))
        rows = list(brains.iter_brain_records("cs61a"))
        questions = exam.build_exam(rows, count=3, brain="cs61a")
        self.assertTrue(any("mutex" in q["prompt"].lower() for q in questions))

    def test_long_notes_grade_does_not_need_every_token(self):
        q = {
            "prompt": "Explain: Mutexes",
            "kind": "notes",
            "answer": (
                "A mutex has acquire and release. Only one thread holds it at a time. "
                "Always acquire before touching the shared counter. Release when done. "
                "This pattern appears on every quiz and in lab 3 writeups."
            ),
        }
        result = exam.grade_answer(q, "a lock only one thread can hold")
        self.assertIn(result["verdict"], {"pass", "partial"})
        miss = exam.grade_answer(q, "bananas")
        self.assertEqual(miss["verdict"], "miss")

    def test_speaker_nicknames_rewrite_action_items(self):
        self.seed_meeting("acme-client")
        brains.set_speaker_name("acme-client", "1", "Jordan")
        mapped = brains.apply_speaker_map("acme-client", {
            "action_items": ["Speaker 1: send the addendum"],
            "speakers": [{"label": "Speaker 1", "name": "unknown", "said": "hi"}],
        })
        self.assertIn("Jordan", mapped["action_items"][0])
        self.assertEqual(mapped["speakers"][0]["name"], "Jordan")
        self.assertIn("Speaker 1 is Jordan", brains.speaker_prompt_hint("acme-client"))


class RecordTests(IsolatedHome):
    def test_parse_avfoundation_devices(self):
        blob = """
[AVFoundation indev @ 0x1] AVFoundation video devices:
[AVFoundation indev @ 0x1] [0] FaceTime HD Camera
[AVFoundation indev @ 0x1] AVFoundation audio devices:
[AVFoundation indev @ 0x1] [0] MacBook Pro Microphone
[AVFoundation indev @ 0x1] [1] ZoomAudioDevice
"""
        devices = record.parse_avfoundation_audio(blob)
        self.assertEqual(devices[0], (0, "MacBook Pro Microphone"))
        self.assertEqual(devices[1][1], "ZoomAudioDevice")
        self.assertTrue(record.is_loopback_name("ZoomAudioDevice"))
        self.assertFalse(record.is_loopback_name("MacBook Pro Microphone"))
        picked = record.pick_system_device(devices)
        self.assertEqual(picked[1], "ZoomAudioDevice")
        blackhole = record.pick_system_device([
            (0, "MacBook Pro Microphone"),
            (2, "BlackHole 2ch"),
            (1, "ZoomAudioDevice"),
        ])
        self.assertEqual(blackhole[1], "BlackHole 2ch")

    def test_fake_record(self):
        dest = self.home / "recordings" / "tone.m4a"
        path = record.record_audio(dest, seconds=0.4, fake=True)
        self.assertTrue(path.is_file())
        self.assertGreater(path.stat().st_size, 200)
