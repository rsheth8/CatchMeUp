"""Shared test helpers. Data lives under CATCHMEUP_HOME so tests never touch the real library."""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


LECTURE_ANALYSIS = {
    "title": "Week 3: Mutexes and environment diagrams",
    "tldr": [
        "A mutex is a lock that serializes access to shared state.",
        "Environment diagrams show frame + parent pointer.",
    ],
    "bookmarks": [
        {
            "timestamp": "00:12:40",
            "heading": "mutex acquire",
            "insight": "Always acquire before touching the shared counter.",
        },
        {
            "timestamp": "00:18:02",
            "heading": "environment diagrams",
            "insight": "Draw the frame, then the parent pointer to the enclosing env.",
        },
    ],
    "detailed_notes": [
        {
            "heading": "Mutexes",
            "content": "A mutex has acquire and release. Only one thread holds it at a time.",
        },
        {
            "heading": "Environment diagrams",
            "content": "Each call creates a frame. Lookup walks parent pointers.",
        },
    ],
    "terms": [
        {"term": "mutex", "definition": "A lock that only one thread can hold at a time."},
        {"term": "environment diagram", "definition": "Picture of frames and parent pointers."},
    ],
    "study": ["Draw an environment diagram for nested define."],
}

MEETING_ANALYSIS = {
    "title": "Acme billing sync",
    "tldr": ["We promised usage-based billing in Q3."],
    "action_items": ["Jordan draft the billing addendum by Friday"],
    "bookmarks": [
        {
            "timestamp": "00:08:11",
            "heading": "billing promise",
            "insight": "Usage-based, not seats. Client asked for a written addendum.",
        }
    ],
    "detailed_notes": [
        {
            "heading": "Billing",
            "content": "Switch from seat licenses to usage-based billing in Q3.",
        }
    ],
    "speakers": [
        {"label": "Speaker 1", "name": "Jordan", "said": "Account lead; promised usage-based billing."},
        {"label": "Speaker 2", "name": "unknown", "said": "Client asking for a written addendum."},
    ],
}

LECTURE_WEEK4 = {
    "title": "Week 4: Heaps",
    "tldr": [
        "A binary heap is a complete tree that satisfies the heap property.",
        "Environment diagrams still use parent pointers.",
    ],
    "bookmarks": [
        {
            "timestamp": "00:06:10",
            "heading": "heap insert",
            "insight": "Bubble up after insert. This will be on the exam.",
        }
    ],
    "detailed_notes": [
        {
            "heading": "Heaps",
            "content": "Insert at the next open leaf, then bubble up.",
        }
    ],
    "terms": [
        {"term": "heap", "definition": "Complete binary tree used as a priority queue."},
        {"term": "environment diagram", "definition": "Picture of frames and parent pointers."},
    ],
    "study": ["Insert 7 into a min-heap and draw the result."],
}


class IsolatedHome(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        self._prev_env = {
            key: os.environ.get(key) for key in ("CATCHMEUP_HOME", "CATCHMEUP_CLOSED", "CATCHMEUP_MODE")
        }
        os.environ["CATCHMEUP_HOME"] = str(self.home)
        os.environ.pop("CATCHMEUP_CLOSED", None)
        os.environ.pop("CATCHMEUP_MODE", None)
        for name in ("recordings", "output", "processed", "logs", "brains"):
            (self.home / name).mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self._tmp.cleanup()
        for key, previous in self._prev_env.items():
            if previous is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = previous

    def seed_lecture(self, slug: str = "cs61a"):
        from catchmeup import brains
        from catchmeup import cortex

        if not brains.exists(slug):
            brains.create_brain(slug, kind="lecture")
        rec = {
            "version": 1,
            "mode": "lecture",
            "title": LECTURE_ANALYSIS["title"],
            "source": "cs61a-week3.mp4",
            "recorded_at": "2026-02-10 09:00",
            "processed_at": "2026-02-10 18:00",
            "analysis": LECTURE_ANALYSIS,
        }
        transcript = (
            "[0:12:40] A mutex is a lock. Acquire it before you touch shared state.\n"
            "[0:18:02] Environment diagrams: each call makes a frame with a parent pointer.\n"
        )
        folder = brains.store_recap(slug, rec, transcript)
        rec["_dir"] = str(folder)
        cortex.ingest_recap(slug, rec)
        return rec

    def seed_meeting(self, slug: str = "acme-client"):
        from catchmeup import brains
        from catchmeup import cortex

        if not brains.exists(slug):
            brains.create_brain(slug, kind="meeting")
        rec = {
            "version": 1,
            "mode": "meeting",
            "title": MEETING_ANALYSIS["title"],
            "source": "acme-billing-zoom.m4a",
            "recorded_at": "2026-03-01 14:00",
            "processed_at": "2026-03-01 16:00",
            "analysis": MEETING_ANALYSIS,
        }
        folder = brains.store_recap(
            slug, rec, "[0:08:11] We promised usage-based billing in Q3."
        )
        rec["_dir"] = str(folder)
        cortex.ingest_recap(slug, rec)
        return rec

    def seed_lecture_week4(self, slug: str = "cs61a"):
        from catchmeup import brains
        from catchmeup import cortex

        if not brains.exists(slug):
            brains.create_brain(slug, kind="lecture")
        rec = {
            "version": 1,
            "mode": "lecture",
            "title": LECTURE_WEEK4["title"],
            "source": "cs61a-week4.mp4",
            "recorded_at": "2026-02-17 09:00",
            "processed_at": "2026-02-17 18:00",
            "analysis": LECTURE_WEEK4,
        }
        folder = brains.store_recap(
            slug, rec, "[0:06:10] A heap is a complete tree. Insert then bubble up."
        )
        rec["_dir"] = str(folder)
        cortex.ingest_recap(slug, rec)
        return rec
