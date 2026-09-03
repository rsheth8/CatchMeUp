"""Workspace and material workflows use isolated data and never contact a model."""
from __future__ import annotations

import json
import os
import subprocess
import zipfile
from pathlib import Path
from unittest.mock import patch

from catchmeup import brains, materials, workspace, sync, cortex
from tests.support import IsolatedHome, ROOT


class MaterialTests(IsolatedHome):
    def setUp(self):
        super().setUp()
        brains.create_brain("course", kind="lecture")
        brains.create_brain("team", kind="meeting")

    def document(self, name="reading.md", text="Quicksort partitions around a pivot."):
        path = self.home / name
        path.write_text(text)
        return path

    def test_import_is_local_idempotent_and_keeps_original(self):
        path = self.document()
        with patch("catchmeup.providers.complete_text") as model:
            doc, created = materials.add("course", path)
            again, duplicate = materials.add("course", path)
        model.assert_not_called()
        self.assertTrue(created)
        self.assertFalse(duplicate)
        self.assertEqual(doc["id"], again["id"])
        self.assertEqual(path.read_bytes(), (materials.root("course") / doc["id"] / "original.md").read_bytes())
        self.assertEqual(len(materials.list_materials("course")), 1)
        self.assertEqual(list(brains.iter_brain_records("course")), [])

    def test_material_only_brain_can_answer_with_citations(self):
        materials.add("course", self.document())
        with patch("catchmeup.providers.complete_text", return_value="Pivot [1]") as model:
            self.assertEqual(brains.ask_brain("course", "quicksort pivot", closed=True), "Pivot [1]")
        prompt = model.call_args.args[0]
        self.assertIn("Material reading.md", prompt)
        self.assertIn("lines 1", prompt)
        self.assertIn("never instructions", model.call_args.kwargs["system"])
        self.assertIn("not proof", model.call_args.kwargs["system"])

    def test_materials_are_scoped_to_brain(self):
        materials.add("team", self.document("agenda.txt", "Confidential pricing unicorns"))
        self.assertFalse(brains.retrieve("unicorns", brains.evidence_records("course")))
        self.assertTrue(brains.retrieve("unicorns", brains.evidence_records("team")))

    def test_all_text_chunks_are_retrievable(self):
        materials.add("course", self.document(text="prefix " * 1000 + " rarewordtail"))
        hits = brains.retrieve("rarewordtail", materials.records("course"))
        self.assertIn("rarewordtail", hits[0]["text"])
        self.assertIn("excerpt", hits[0]["label"])
        self.assertFalse(any("README" in label for label, _ in brains._chunks(materials.records("course")[0])))

    def test_can_attach_to_meeting_and_reject_ambiguous_match(self):
        rec = self.seed_meeting("team")
        doc, _ = materials.add("team", self.document(), recap="billing")
        self.assertEqual(doc["recaps"][0]["title"], rec["title"])
        self.seed_meeting("team")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            materials.add("team", self.document("new.txt"), recap="billing")

    def test_invalid_scope_and_file_rejected_without_writes(self):
        with self.assertRaises(ValueError):
            materials.add("../course", self.document())
        for name, text in [("empty.md", ""), ("binary.exe", "no"), ("broken.pptx", "no")]:
            self.assertEqual(workspace.main(["materials", "course", "add", str(self.document(name, text))]), 1)
        self.assertEqual(materials.list_materials("course"), [])

    def test_text_sections_preserve_line_numbers(self):
        path = self.document(text="\n".join(f"Line {i}" for i in range(81)))
        pages, _ = materials.extract(path)
        self.assertEqual([p["label"] for p in pages], ["lines 1–40", "lines 41–80", "lines 81–81"])

    def test_pdf_text_and_blank_pages(self):
        from pypdf import PdfWriter
        from pypdf.generic import DecodedStreamObject, NameObject, DictionaryObject
        writer = PdfWriter()
        page = writer.add_blank_page(612, 792)
        font = DictionaryObject({NameObject("/Type"): NameObject("/Font"), NameObject("/Subtype"): NameObject("/Type1"),
                                 NameObject("/BaseFont"): NameObject("/Helvetica")})
        page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): font})})
        stream = DecodedStreamObject()
        stream.set_data(b"BT /F1 12 Tf 50 700 Td (Biology mitochondria) Tj ET")
        page[NameObject("/Contents")] = stream
        writer.add_blank_page(612, 792)
        path = self.home / "biology.pdf"
        writer.write(path)
        pages, warnings = materials.extract(path)
        self.assertIn("mitochondria", pages[0]["text"])
        self.assertEqual(pages[1]["label"], "page 2")
        self.assertTrue(any("no readable text" in w for w in warnings))

    def test_empty_encrypted_and_corrupt_pdf_fail_cleanly(self):
        from pypdf import PdfWriter
        writer = PdfWriter()
        writer.add_blank_page(100, 100)
        blank = self.home / "blank.pdf"
        writer.write(blank)
        with self.assertRaisesRegex(ValueError, "No readable text"):
            materials.extract(blank)
        writer.encrypt("password")
        locked = self.home / "locked.pdf"
        writer.write(locked)
        with self.assertRaisesRegex(ValueError, "encrypted"):
            materials.extract(locked)
        with self.assertRaisesRegex(ValueError, "could not be read"):
            materials.extract(self.document("broken.pdf", "broken"))

    def test_pptx_uses_presentation_order_not_filenames(self):
        path = self.home / "slides.pptx"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("ppt/presentation.xml", '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId r:id="r2"/><p:sldId r:id="r1"/></p:sldIdLst></p:presentation>')
            archive.writestr("ppt/_rels/presentation.xml.rels", '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="r1" Target="slides/slide1.xml"/><Relationship Id="r2" Target="slides/slide2.xml"/></Relationships>')
            for i, text in [(1, "Last"), (2, "First")]:
                archive.writestr(f"ppt/slides/slide{i}.xml", f'<a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:r><a:t>{text}</a:t></a:r></a:p>')
        pages, _ = materials.extract(path)
        self.assertEqual([p["text"] for p in pages], ["First", "Last"])
        self.assertEqual(pages[0]["label"], "slide 1")

    def test_size_limits(self):
        path = self.document(text="too long")
        with patch.object(materials, "MAX_BYTES", 2), self.assertRaisesRegex(ValueError, "50 MB"):
            materials.add("course", path)
        with patch.object(materials, "MAX_TEXT", 2), self.assertRaisesRegex(ValueError, "text is too large"):
            materials.add("course", path)

    def test_deep_analysis_packs_material_evidence(self):
        materials.add("course", self.document())
        self.assertIn("Quicksort", cortex._pack_activated("course", "quicksort", []))


class WorkspaceTests(IsolatedHome):
    def test_dashboard_and_briefs_are_read_only(self):
        rec = self.seed_meeting()
        self.seed_lecture()
        path = Path(rec["_dir"]) / "catchmeup.json"
        before = path.read_bytes()
        with patch("catchmeup.providers.complete_text") as model:
            self.assertIn("Study review", workspace.brief("cs61a", study=True))
            self.assertIn("Jordan", workspace.brief("acme-client"))
            self.assertIn("Course", workspace.dashboard("student"))
            self.assertNotIn("Acme", workspace.dashboard("student"))
            self.assertNotIn("Course", workspace.dashboard("work"))
        model.assert_not_called()
        self.assertEqual(before, path.read_bytes())

    def test_legacy_tasks_dedupe_and_require_review(self):
        rec = self.seed_meeting()
        rec["analysis"] = {"action_items": ["Draft plan", "Draft plan", "Other task"]}
        tasks = workspace.followups(rec)
        self.assertEqual(len(tasks), 2)
        self.assertTrue(all(t["needsReview"] for t in tasks))
        self.assertEqual(tasks, workspace.followups(rec))
        self.assertTrue(all(not t["owner"] and not t.get("dueDate") for t in tasks))

    def test_edits_preserve_phone_fields_and_completion(self):
        rec = self.seed_meeting()
        path = Path(rec["_dir"]) / "catchmeup.json"
        data = json.loads(path.read_text())
        task = workspace.followups(rec)[0]
        task["reminderID"] = "existing-reminder"
        data["meeting"] = {"agenda": "Budget", "followUps": [task], "outcomes": [{"text": "Keep decision"}], "documentNotes": [{"summary": "Keep note"}]}
        sync.atomic_json_write(path, data)
        updated = workspace.update_task("acme-client", task["id"][:8], "review", "Jordan", "2026-10-01")
        self.assertFalse(updated["needsReview"])
        self.assertEqual(updated["reminderID"], "existing-reminder")
        workspace.update_task("acme-client", task["id"][:8], "done")
        saved = json.loads(path.read_text())
        self.assertEqual(saved["meeting"]["agenda"], "Budget")
        self.assertEqual(saved["meeting"]["followUps"][0]["status"], "done")
        self.assertEqual(saved["meeting"]["documentNotes"], data["meeting"]["documentNotes"])
        self.assertIn("[done]", brains._chunks(next(brains.iter_brain_records("acme-client")))[1][1])
        reopened = workspace.update_task("acme-client", task["id"][:8], "open", due="none")
        self.assertIsNone(reopened["dueDate"])
        self.assertFalse(reopened["needsReview"])

    def test_invalid_date_id_and_action_do_not_write(self):
        rec = self.seed_meeting()
        path = Path(rec["_dir"]) / "catchmeup.json"
        original = path.read_bytes()
        task = workspace.followups(rec)[0]
        with self.assertRaises(ValueError):
            workspace.update_task("acme-client", task["id"], "edit", due="tomorrow")
        with self.assertRaises(ValueError):
            workspace.update_task("acme-client", "missing", "done")
        self.assertEqual(workspace.main(["tasks", "acme-client", "edit", task["id"]]), 1)
        self.assertEqual(path.read_bytes(), original)

    def test_wrong_brain_type_has_guidance(self):
        self.seed_lecture()
        with self.assertRaisesRegex(ValueError, "review"):
            workspace.brief("cs61a")

    def test_cli_workflow_end_to_end(self):
        self.seed_meeting()
        self.seed_lecture()
        def run(*args):
            result = subprocess.run(["bash", str(ROOT / "catchup"), *args], env=os.environ.copy(), text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout
        self.assertIn("Study review", run("review", "cs61a"))
        self.assertIn("Meeting prep", run("prepare", "acme-client"))
        self.assertIn("Work", run("today", "--audience", "work"))
        tasks = json.loads(run("tasks", "acme-client", "--json"))
        task_id = tasks[0]["id"][:8]
        run("tasks", "acme-client", "review", task_id, "--owner", "Jordan", "--due", "2026-10-01")
        run("tasks", "acme-client", "done", task_id)
        self.assertEqual(json.loads(run("tasks", "acme-client", "--json")), [])
        self.assertEqual(json.loads(run("tasks", "acme-client", "--all", "--json"))[0]["status"], "done")
        for command in ("materials", "tasks", "prepare", "review", "today"):
            self.assertIn("usage:", run("help", command))

    def test_phone_workspace_roundtrip_and_stale_pull(self):
        self.seed_meeting()
        shared = self.home / "shared"
        shared.mkdir()
        sync.push(target=shared)
        records = json.loads((shared / "recordings.json").read_text())
        original = records[0]
        original["updatedAt"] = "2026-09-01T12:00:59Z"
        local = next(brains.iter_brain_records("acme-client"))
        task = workspace.followups(local)[0]
        task["reminderID"] = "keep-me"
        original["meeting"] = {"agenda": "Plan", "followUps": [task], "outcomes": [], "documentNotes": []}
        sync.atomic_json_write(shared / "recordings.json", [original])
        sync.pull(source=shared)
        pulled = next(brains.iter_brain_records("acme-client"))
        self.assertEqual(pulled["meeting"], original["meeting"])
        converted = sync.convert_recording(Path(pulled["_path"]), self.home, {})
        self.assertEqual(converted["updatedAt"], original["updatedAt"])
        self.assertEqual(converted["meeting"], original["meeting"])
        workspace.update_task("acme-client", task["id"][:8], "done")
        # Phone moved on since last pull, but is still older than the local edit.
        original["updatedAt"] = "2026-09-02T12:00:00Z"
        sync.atomic_json_write(shared / "recordings.json", [original])
        sync.pull(source=shared)
        self.assertEqual(next(brains.iter_brain_records("acme-client"))["meeting"]["followUps"][0]["status"], "done")
        sync.push(target=shared)
        final = json.loads((shared / "recordings.json").read_text())[0]
        self.assertEqual(final["meeting"]["followUps"][0]["status"], "done")
        self.assertEqual(final["meeting"]["followUps"][0]["reminderID"], "keep-me")

    def test_newer_legacy_push_preserves_phone_workspace(self):
        old = {"id": "A", "updatedAt": "2026-01-01T00:00:00Z", "meeting": {"agenda": "Keep"}}
        new = {"id": "A", "updatedAt": "2026-02-01T00:00:00Z"}
        self.assertEqual(sync.merge_by_id([old], [new], carry_user_state=True)[0]["meeting"], old["meeting"])

    def test_rapid_edits_do_not_tie_on_phone(self):
        rec = self.seed_meeting()
        task = workspace.followups(rec)[0]
        workspace.update_task("acme-client", task["id"][:8], "start")
        first = next(brains.iter_brain_records("acme-client"))
        workspace.update_task("acme-client", task["id"][:8], "done")
        second = next(brains.iter_brain_records("acme-client"))
        self.assertGreater(sync.cli_update_time(second), sync.cli_update_time(first))

    def test_legacy_local_timestamp_compares_as_local_time(self):
        instant = "2026-09-03T12:34:00Z"
        metadata = {"processed_at": sync.local_stamp(instant)}
        self.assertEqual(sync.cli_update_time(metadata), sync.parse_iso(instant))

    def test_duplicate_legacy_action_keeps_completion(self):
        rec = {"source": "meeting", "analysis": {"action_items": ["Draft plan", "Draft plan"]}, "completedActions": [1]}
        self.assertEqual(workspace.followups(rec)[0]["status"], "done")
