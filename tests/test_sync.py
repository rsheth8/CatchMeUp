#!/usr/bin/env python3
"""CLI ↔ iPhone library: one shared folder, merge by id, round trips don't clone."""
from __future__ import annotations

import json
import os
from pathlib import Path

from catchmeup import brains, sync
from tests.support import IsolatedHome


PHONE_RECORDING_ID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
PHONE_BRAIN_ID = "11111111-2222-4333-8444-555555555555"
UNFILED_ID = "99999999-AAAA-4BBB-8CCC-DDDDDDDDDDDD"


def _phone_recording(
    rec_id: str,
    title: str,
    brain_id: str | None = None,
    updated: str = "2026-03-02T18:00:00Z",
) -> dict:
    return {
        "id": rec_id.lower(),  # Swift encodes UUIDs lowercase
        "title": title,
        "createdAt": "2026-03-01T09:00:00Z",
        "updatedAt": updated,
        "deleted": False,
        "mode": "lecture",
        "audioFilename": None,
        "duration": 12.0,
        "segments": [
            {
                "id": "00000000-0000-4000-8000-000000000001",
                "start": 12.4,
                "text": "A mutex is a lock.",
            }
        ],
        "recap": {
            "title": title,
            "tldr": ["A mutex serializes access."],
            "actionItems": [],
            "speakers": [],
            "bookmarks": [
                {
                    "timestamp": "00:12:40",
                    "heading": "mutex",
                    "insight": "Acquire before touching shared state.",
                }
            ],
            "detailedNotes": [
                {"heading": "Mutexes", "content": "Acquire, then release."}
            ],
            "terms": [{"term": "mutex", "definition": "A lock one thread holds."}],
            "study": ["Define mutex."],
        },
        "brainID": brain_id,
        "completedActions": [0],
    }


class SyncTests(IsolatedHome):
    def setUp(self):
        super().setUp()
        self.shared = self.home / "shared"
        self.shared.mkdir()
        os.environ["CATCHMEUP_SYNC_DIR"] = str(self.shared)
        os.environ["CATCHMEUP_SYNC"] = "auto"

    def test_status_without_folder(self):
        os.environ["CATCHMEUP_SYNC_DIR"] = str(self.home / "does-not-exist")
        report = sync.status()
        self.assertFalse(report.available)
        self.assertIn("does-not-exist", report.reason)

    def test_auto_push_is_silent_without_a_folder(self):
        os.environ["CATCHMEUP_SYNC_DIR"] = str(self.home / "does-not-exist")
        self.assertIsNone(sync.auto_push())

    def test_push_then_pull_round_trip_does_not_clone(self):
        self.seed_lecture("cs61a")
        first = sync.push()
        self.assertGreaterEqual(first.converted, 1)
        recaps = json.loads((self.shared / "recordings.json").read_text())
        self.assertEqual(len(recaps), 1)
        recap_id = recaps[0]["id"]
        self.assertEqual(recap_id, recap_id.upper())

        meta = json.loads(
            next((self.home / "brains" / "cs61a" / "recaps").glob("*/catchmeup.json")).read_text()
        )
        self.assertEqual(meta["ios_id"], recap_id)
        brain_meta = json.loads((self.home / "brains" / "cs61a" / "brain.json").read_text())
        self.assertTrue(brain_meta.get("ios_id"))

        second = sync.push()
        recaps_again = json.loads((self.shared / "recordings.json").read_text())
        self.assertEqual(len(recaps_again), 1)
        self.assertEqual(second.converted, first.converted)

        pulled = sync.pull()
        self.assertEqual(pulled.imported, 0)
        self.assertEqual(len(list(brains.iter_brain_records("cs61a"))), 1)

    def test_merge_keeps_ticked_actions_on_newer_push(self):
        self.seed_lecture("cs61a")
        sync.push()
        recaps = json.loads((self.shared / "recordings.json").read_text())
        recaps[0]["completedActions"] = [0, 1]
        recaps[0]["updatedAt"] = "2026-01-01T00:00:00Z"
        (self.shared / "recordings.json").write_text(json.dumps(recaps))

        # CLI recap is newer (processed_at is 2026-02-10). User state must survive.
        sync.push()
        merged = json.loads((self.shared / "recordings.json").read_text())
        self.assertEqual(merged[0]["completedActions"], [0, 1])

    def test_merge_is_case_insensitive_on_ids(self):
        existing = [{"id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "updatedAt": "2026-01-01T00:00:00Z"}]
        incoming = [{"id": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", "updatedAt": "2026-02-01T00:00:00Z", "title": "newer"}]
        merged = sync.merge_by_id(existing, incoming)
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0]["title"], "newer")
        self.assertEqual(merged[0]["id"], merged[0]["id"].upper())

    def test_pull_creates_brain_born_on_the_phone(self):
        (self.shared / "brains.json").write_text(
            json.dumps([
                {
                    "id": PHONE_BRAIN_ID.lower(),
                    "name": "OS",
                    "persona": "You are an OS TA.",
                    "mode": "lecture",
                    "createdAt": "2026-03-01T09:00:00Z",
                    "updatedAt": "2026-03-01T09:00:00Z",
                    "deleted": False,
                }
            ])
        )
        (self.shared / "recordings.json").write_text(
            json.dumps([
                _phone_recording(PHONE_RECORDING_ID, "Lecture 1: Mutexes", PHONE_BRAIN_ID)
            ])
        )
        report = sync.pull()
        self.assertEqual(report.imported, 1)
        self.assertTrue(brains.exists("os"))
        meta = brains.load_brain("os")
        self.assertEqual(meta["ios_id"], PHONE_BRAIN_ID)
        recs = list(brains.iter_brain_records("os"))
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]["ios_id"], PHONE_RECORDING_ID)
        self.assertIn("mutex", recs[0]["analysis"]["terms"][0]["term"].lower())
        transcript = Path(recs[0]["_dir"]) / "transcript.txt"
        self.assertIn("mutex", transcript.read_text().lower())

        again = sync.pull()
        self.assertEqual(again.imported, 0)
        self.assertEqual(len(list(brains.iter_brain_records("os"))), 1)

    def test_pull_files_unfiled_recordings_into_processed(self):
        (self.shared / "recordings.json").write_text(
            json.dumps([_phone_recording(UNFILED_ID, "Hallway chat", brain_id=None)])
        )
        (self.shared / "brains.json").write_text("[]")
        report = sync.pull()
        self.assertEqual(report.imported, 1)
        self.assertEqual(report.unfiled, 1)
        recaps = list((self.home / "processed").glob("*/catchmeup.json"))
        self.assertEqual(len(recaps), 1)
        data = json.loads(recaps[0].read_text())
        self.assertEqual(data["ios_id"], UNFILED_ID)
        self.assertIsNone(data["brain"])

        again = sync.pull()
        self.assertEqual(again.imported, 0)
        self.assertEqual(len(list((self.home / "processed").glob("*/catchmeup.json"))), 1)

    def test_auto_push_sends_when_the_folder_exists(self):
        self.seed_lecture("cs61a")
        report = sync.auto_push()
        self.assertIsNotNone(report)
        self.assertGreaterEqual(report.converted, 1)
        self.assertTrue((self.shared / "recordings.json").is_file())

    def test_auto_push_respects_opt_out(self):
        self.seed_lecture("cs61a")
        os.environ["CATCHMEUP_SYNC"] = "0"
        self.assertIsNone(sync.auto_push())
        self.assertFalse((self.shared / "recordings.json").exists())


if __name__ == "__main__":
    import unittest

    unittest.main()
