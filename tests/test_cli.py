#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import unittest

from tests.support import IsolatedHome, ROOT


CATCHUP = ROOT / "catchup"


class CliTests(IsolatedHome):
    def run_cli(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["CATCHMEUP_HOME"] = str(self.home)
        result = subprocess.run(
            ["bash", str(CATCHUP), *args],
            cwd=str(ROOT),
            env=env,
            text=True,
            capture_output=True,
        )
        if check and result.returncode != 0:
            self.fail(
                f"./catchup {' '.join(args)} failed ({result.returncode})\n"
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        return result

    def test_bash_syntax(self):
        subprocess.run(["bash", "-n", str(CATCHUP)], check=True)
        subprocess.run(["bash", "-n", str(ROOT / "watch_and_process.sh")], check=True)

    def test_help(self):
        result = self.run_cli()
        self.assertIn("CatchMeUp", result.stdout)
        self.assertIn("brain new", result.stdout)
        self.assertIn("think", result.stdout)
        self.assertIn("exam", result.stdout)
        self.assertIn("clip", result.stdout)
        self.assertIn("rec", result.stdout)
        self.assertIn("diff", result.stdout)
        self.assertIn("./catchup help", result.stdout)
        self.assertIn("walk", result.stdout)
        page = self.run_cli("help", "exam")
        self.assertIn("Practice test", page.stdout)
        self.assertIn("--print", page.stdout)
        self.assertIn("drill", page.stdout.lower())
        ask = self.run_cli("help", "ask")
        self.assertIn("--closed", ask.stdout)
        rec = self.run_cli("help", "rec")
        self.assertIn("microphone", rec.stdout.lower())
        self.assertIn("--system", rec.stdout)
        speakers = self.run_cli("help", "speakers")
        self.assertIn("Jordan", speakers.stdout)
        missing = self.run_cli("help", "not-a-real-command", check=False)
        self.assertNotEqual(missing.returncode, 0)

    def test_brain_new_list_show_persona_cortex(self):
        created = self.run_cli("brain", "new", "cs61a", "--lecture")
        self.assertIn("cs61a", created.stdout)
        listed = self.run_cli("brain", "list")
        self.assertIn("cs61a", listed.stdout)
        shown = self.run_cli("brain", "show", "cs61a")
        self.assertIn("lecture", shown.stdout)
        self.run_cli("brain", "persona", "cs61a", "You are a CS 61A TA.")
        persona = self.run_cli("brain", "show", "cs61a")
        self.assertIn("CS 61A TA", persona.stdout)
        cortex_out = self.run_cli("cortex", "cs61a")
        self.assertIn("empty", cortex_out.stdout.lower())
        missing = self.run_cli("brain", "show", "nope", check=False)
        self.assertNotEqual(missing.returncode, 0)

    def test_home_does_not_pollute_repo(self):
        self.run_cli("brain", "new", "isolation-test", "--meeting")
        self.assertTrue((self.home / "brains" / "isolation-test" / "brain.json").is_file())
        self.assertFalse((ROOT / "brains" / "isolation-test" / "brain.json").is_file())

    def test_providers_and_unknown_command(self):
        listed = self.run_cli("providers")
        self.assertIn("openai", listed.stdout.lower())
        bogus = self.run_cli("not-a-command", check=False)
        self.assertNotEqual(bogus.returncode, 0)

    def test_into_missing_file(self):
        self.run_cli("brain", "new", "cs61a", "--lecture")
        missing = self.run_cli("into", "cs61a", str(self.home / "nope.mp4"), check=False)
        self.assertNotEqual(missing.returncode, 0)
        empty = self.home / "empty-course"
        empty.mkdir()
        folder = self.run_cli("into", "cs61a", str(empty))
        self.assertIn("Nothing new", folder.stdout)

    def test_exam_diff_clip_and_fake_rec(self):
        self.seed_lecture("cs61a")
        self.seed_lecture_week4("cs61a")
        exam_out = self.run_cli("exam", "cs61a", "--print", "-n", "5")
        self.assertIn("CatchMeUp exam", exam_out.stdout)
        self.assertIn("mutex", exam_out.stdout.lower())
        diff_out = self.run_cli("diff", "cs61a")
        self.assertRegex(diff_out.stdout.lower(), r"heap|mutex")
        clip_out = self.run_cli("clip", "cs61a", "mutex", "--print")
        self.assertIn("12:40", clip_out.stdout)
        rec_out = self.run_cli("rec", "--fake", "--keep", "-t", "0.4")
        self.assertIn("Saved", rec_out.stdout)
        recs = list((self.home / "recordings").glob("rec-*.m4a"))
        self.assertTrue(recs)
        self.assertGreater(recs[0].stat().st_size, 200)
        named = self.run_cli("speakers", "cs61a", "1=Ana")
        self.assertIn("Ana", named.stdout)
        shown = self.run_cli("speakers", "cs61a")
        self.assertIn("Ana", shown.stdout)

    def test_demo_and_cortex_map(self):
        demo = self.run_cli("demo")
        self.assertIn("CatchMeUp", demo.stdout)
        self.assertIn("mutex", demo.stdout.lower())
        self.assertIn("spreading activation", demo.stdout.lower())
        self.run_cli("brain", "new", "cs61a", "--lecture")
        self.seed_lecture("cs61a")
        mapped = self.run_cli("cortex", "cs61a")
        self.assertIn("mutex", mapped.stdout.lower())
        self.assertIn("concepts", mapped.stdout.lower())
        lit = self.run_cli("cortex", "cs61a", "mutex")
        self.assertIn("spreading activation", lit.stdout.lower())
        help_demo = self.run_cli("help", "demo")
        self.assertIn("CATCHMEUP_PLAIN", help_demo.stdout)
        self.assertIn("--web", help_demo.stdout)
        web = self.run_cli("demo", "--web")
        self.assertIn("demo.html", web.stdout)
        demo_html = self.home / "output" / "demo.html"
        self.assertTrue(demo_html.is_file())
        page = demo_html.read_text()
        self.assertIn("mutex", page)
        self.assertIn("id=\"hud\"", page)
        self.assertIn("id=\"tip\"", page)
        self.assertIn("function Spring", page)

    def test_walk_and_trace(self):
        self.seed_lecture("cs61a")
        walked = self.run_cli("walk", "cs61a", "mutex")
        self.assertIn("mutex", walked.stdout.lower())
        listed = self.run_cli("walk", "cs61a")
        self.assertIn("mutex", listed.stdout.lower())
        traced = self.run_cli("trace", "cs61a", "mutex", "environment", "diagrams")
        self.assertIn("mutex", traced.stdout.lower())
        notes = self.run_cli("notes", "cs61a")
        self.assertIn("mutex", notes.stdout.lower())
        graphed = self.run_cli("graph", "cs61a")
        self.assertIn("cortex.html", graphed.stdout)
        help_walk = self.run_cli("help", "walk")
        self.assertIn("Obsidian", help_walk.stdout)
        extra = self.run_cli("obsidian", "cs61a")
        self.assertIn("vault", extra.stdout.lower())


if __name__ == "__main__":
    unittest.main()
