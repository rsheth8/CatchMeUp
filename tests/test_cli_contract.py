"""Public executable contract, not just individual Python engine functions."""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

from tests.support import IsolatedHome, ROOT


class ContractTests(IsolatedHome):
    def call(self, *args, cwd=None, input="", status=0):
        result = subprocess.run([str(ROOT / "catchup"), *args], cwd=cwd or self.home,
                                env=os.environ.copy(), input=input, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, status, (args, result.stdout, result.stderr))
        return result

    def test_version_and_basic_commands_on_system_bash(self):
        from catchmeup import __version__
        self.assertEqual(self.call("--version").stdout.strip(), f"catchup {__version__}")
        self.assertEqual(json.loads(self.call("library", "--json").stdout), [])
        self.assertEqual(json.loads(self.call("search", "test", "--json").stdout), [])
        if Path("/bin/bash").exists():
            for args in [("library",), ("search", "test")]:
                result = subprocess.run(["/bin/bash", str(ROOT / "catchup"), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_every_command_has_help_without_execution(self):
        from catchmeup.cli import parser
        def walk(p, route=()):
            for action in p._actions:
                if isinstance(action, argparse._SubParsersAction):
                    seen = set()
                    for name, child in action.choices.items():
                        if id(child) in seen:
                            continue
                        seen.add(id(child))
                        yield route + (name,)
                        yield from walk(child, route + (name,))
        for route in walk(parser()):
            with self.subTest(route=route):
                result = self.call(*route, "--help")
                self.assertIn("usage:", result.stdout)
                self.assertEqual(result.stderr, "")

    def test_invalid_flags_never_succeed(self):
        for args in [("status", "--nonsense"), ("library", "--nonsense"),
                     ("today", "--aud", "work"), ("rec", "--seconds"),
                     ("rec", "--seconds", "nan"), ("rec", "--seconds", "-1"),
                     ("brain", "new", "test", "--typo"),
                     ("mode", "lecture", "ignored")]:
            result = self.call(*args, status=2)
            self.assertEqual(result.stdout, "")
            self.assertNotIn("Traceback", result.stderr)
        self.assertFalse((self.home / "brains" / "test").exists())

    def test_relative_paths_are_callers_paths(self):
        self.call("brain", "new", "team", "--meeting")
        cwd = self.home / "folder with spaces"
        cwd.mkdir()
        (cwd / "agenda.md").write_text("A locally supplied meeting agenda.")
        self.call("materials", "team", "add", "agenda.md", cwd=cwd)
        self.assertIn("agenda.md", self.call("materials", "team").stdout)
        (cwd / "recording.wav").write_bytes(b"synthetic test fixture")
        self.call("drop", "recording.wav", cwd=cwd)
        self.assertEqual((self.home / "recordings" / "recording.wav").read_bytes(), b"synthetic test fixture")

    def test_drop_refuses_overwrite(self):
        source = self.home / "same.wav"
        source.write_bytes(b"new")
        dest = self.home / "recordings" / "same.wav"
        dest.write_bytes(b"original")
        self.call("drop", str(source), status=1)
        self.assertEqual(dest.read_bytes(), b"original")

    def test_json_outputs_are_pure_and_have_real_data(self):
        self.seed_meeting("team")
        for args in [("library",), ("search", "billing"), ("todos",), ("brain", "list")]:
            result = self.call(*args, "--json")
            self.assertTrue(json.loads(result.stdout))
            self.assertEqual(result.stderr, "")
        result = self.call("tasks", "team", "--json")
        self.assertEqual(json.loads(result.stdout)[0]["status"], "open")
        self.call("library", "--brain", "missing", "--json", status=1)

    def test_no_input_and_missing_credentials_fail_cleanly(self):
        self.call("--no-input", "config", status=1)
        self.call("--no-input", "quiz", status=1)
        self.call("--no-input", "rec", status=1)
        self.assertFalse((self.home / ".env").exists())
        self.call("--no-input", "config", "ollama")
        self.assertIn("CATCHMEUP_PROVIDER=ollama", (self.home / ".env").read_text())

    def test_config_key_not_echoed_and_other_settings_preserved(self):
        config = self.home / ".env"
        config.write_text("# keep this\nCATCHMEUP_SYNC=0\nCATCHMEUP_MODEL=old\n")
        result = self.call("config", "anthropic", "--key-stdin", input="synthetic-test-key\n")
        self.assertNotIn("synthetic-test-key", result.stdout + result.stderr)
        self.call("model", "replacement")
        text = config.read_text()
        self.assertIn("CATCHMEUP_SYNC=0", text)
        self.assertIn("CATCHMEUP_API_KEY=synthetic-test-key", text)
        self.assertIn("CATCHMEUP_MODEL=replacement", text)
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_home_override_does_not_read_repo_credentials(self):
        from catchmeup import paths
        other = self.home / "separate library"
        result = self.call("--home", str(other), "status", "--json")
        self.assertEqual(json.loads(result.stdout)["home"], str(other.resolve()))
        self.assertFalse(other.exists())
        with patch.dict(os.environ, {"CATCHMEUP_HOME": str(other)}, clear=True):
            paths.load_env()
            self.assertNotIn("CATCHMEUP_API_KEY", os.environ)

    def test_installed_default_is_outside_package(self):
        from catchmeup import paths
        with patch.dict(os.environ, {}, clear=True), patch.object(paths, "REPO_DIR", self.home / "site-packages"), patch.object(Path, "home", return_value=self.home):
            default = paths.home()
            self.assertNotEqual(default, paths.REPO_DIR)
            self.assertTrue(default.is_relative_to(self.home))
            self.assertFalse(default.exists())
        with patch.dict(os.environ, {}, clear=True), patch.object(sys, "frozen", True, create=True), patch.object(Path, "home", return_value=self.home):
            self.assertNotEqual(paths.home(), ROOT)

    def test_persona_stdin_and_grade_stdin(self):
        from catchmeup.cli import main
        self.call("brain", "new", "team", "--meeting")
        self.call("brain", "persona", "team", "--stdin", input="Be a careful meeting assistant.")
        self.assertIn("careful", self.call("brain", "persona", "team").stdout)
        with patch("sys.stdin", io.StringIO("my homework")), patch("catchmeup.brains.grade_work", return_value="Assessment") as grade, redirect_stdout(io.StringIO()):
            self.assertEqual(main(["grade", "team", "-"]), 0)
            self.assertEqual(grade.call_args.args[1], "my homework")

    def test_scopes_and_path_traversal(self):
        self.call("library", "missing", status=1)
        self.call("brain", "show", "../../outside", status=1)
        self.call("materials", "../../outside", status=1)
        self.call("search", "stack/heap")

    def test_mcp_install_merges_without_overwriting(self):
        folder = self.home / ".cursor"
        folder.mkdir()
        target = folder / "mcp.json"
        target.write_text(json.dumps({"mcpServers": {"other": {"command": "existing"}}}))
        self.call("mcp", "install")
        data = json.loads(target.read_text())
        self.assertEqual(data["mcpServers"]["other"]["command"], "existing")
        self.assertIn("catchmeup", data["mcpServers"])
        self.call("mcp", "install", status=1)
        self.assertEqual(data, json.loads(target.read_text()))

    def test_watch_empty_pass(self):
        self.call("--no-input", "watch", "--once")

    def test_unknown_errors_do_not_leak_provider_secrets(self):
        from catchmeup.cli import main
        from contextlib import redirect_stderr
        errors = io.StringIO()
        with patch("catchmeup.cli.execute", side_effect=Exception("secret token")), redirect_stderr(errors):
            self.assertEqual(main(["status"]), 1)
        self.assertNotIn("secret token", errors.getvalue())

    def test_setup_does_not_install_dependencies_by_default(self):
        from catchmeup.cli import main
        with patch("catchmeup.cli_admin.subprocess.run") as run, redirect_stdout(io.StringIO()):
            self.assertEqual(main(["setup"]), 0)
        run.assert_not_called()

    def test_key_update_replaces_legacy_provider_key(self):
        config = self.home / ".env"
        config.write_text("ANTHROPIC_API_KEY=previous\nCATCHMEUP_API_KEY=previous\n")
        self.call("config", "anthropic", "--key-stdin", input="replacement")
        contents = config.read_text()
        self.assertIn("ANTHROPIC_API_KEY=replacement", contents)
        self.assertNotIn("previous", contents)

    def test_provider_switch_does_not_reuse_old_company_key(self):
        from catchmeup.cli_admin import configure
        from argparse import Namespace
        with patch.dict(os.environ, {"CATCHMEUP_HOME": str(self.home), "CATCHMEUP_PROVIDER": "anthropic", "CATCHMEUP_API_KEY": "old-company-key"}, clear=True):
            with self.assertRaisesRegex(ValueError, "interactive"):
                configure(Namespace(provider="openai", key_stdin=False, base_url=None, model=None, no_input=True))
        self.assertFalse((self.home / ".env").exists())

    def test_pipeline_receives_absolute_caller_path_and_mode(self):
        from catchmeup.cli import main
        file = self.home / "meeting.wav"
        file.write_bytes(b"test")
        with patch("catchmeup.pipeline.main") as pipeline, redirect_stdout(io.StringIO()):
            self.assertEqual(main(["meeting", str(file)]), 0)
        self.assertEqual(pipeline.call_args.args[0], [str(file.resolve()), "--mode", "meeting"])

    def test_background_job_is_not_repository_script(self):
        from catchmeup import cli_admin
        import plistlib
        target = self.home / "LaunchAgents" / "test.plist"
        with patch.object(sys, "platform", "darwin"), patch.object(cli_admin, "watch_plist", return_value=target), patch.object(cli_admin.subprocess, "run") as run, redirect_stdout(io.StringIO()):
            run.return_value.returncode = 0
            cli_admin.install_watch("lecture")
        data = plistlib.loads(target.read_bytes())
        self.assertIn("--once", data["ProgramArguments"])
        self.assertIn("catchmeup", data["ProgramArguments"])
        self.assertNotIn("watch_and_process.sh", str(data))
        self.assertEqual(data["EnvironmentVariables"]["CATCHMEUP_HOME"], str(self.home.resolve()))

    def test_no_input_does_not_wait_for_terminal_stdin(self):
        from catchmeup.cli import main
        self.seed_meeting("team")
        from contextlib import redirect_stderr
        with patch("sys.stdin.isatty", return_value=True), redirect_stderr(io.StringIO()):
            self.assertEqual(main(["--no-input", "brain", "persona", "team", "--stdin"]), 1)
            self.assertEqual(main(["--no-input", "grade", "team", "-"]), 1)
            self.assertEqual(main(["--no-input", "config", "anthropic", "--key-stdin"]), 1)
