#!/usr/bin/env python3
from __future__ import annotations

import os
import random
from pathlib import Path
from unittest.mock import MagicMock, patch

import exam
import library
import pipeline
import record
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
        import brains

        self.seed_lecture("cs61a")
        questions = exam.build_exam(list(brains.iter_brain_records("cs61a")), count=6, rng=random.Random(0))
        self.assertTrue(questions)
        self.assertTrue(any("mutex" in q["prompt"].lower() or "mutex" in q["answer"].lower() for q in questions))
        define = next(q for q in questions if q["kind"] == "term" and "mutex" in q["prompt"].lower())
        result = exam.grade_answer(define, "a lock only one thread can hold")
        self.assertEqual(result["verdict"], "pass")
        miss = exam.grade_answer(define, "bananas")
        self.assertEqual(miss["verdict"], "miss")
        printed = exam.format_exam(questions, answers=True)
        self.assertIn("CatchMeUp exam", printed)
        self.assertIn("mutex", printed.lower())


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
        with patch("library.shutil.which", side_effect=lambda n: "/bin/true"):
            with patch("library.subprocess.run") as run:
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

    def test_fake_record(self):
        dest = self.home / "recordings" / "tone.m4a"
        path = record.record_audio(dest, seconds=0.4, fake=True)
        self.assertTrue(path.is_file())
        self.assertGreater(path.stat().st_size, 200)
