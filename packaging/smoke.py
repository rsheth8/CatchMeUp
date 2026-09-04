"""Black-box install check. Run outside the repository, with no live user data.

Usage: python packaging/smoke.py /absolute/path/to/catchup
Uses synthetic documents only; never calls AI, records a microphone, or syncs.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def smoke(executable):
    executable = str(Path(executable).resolve(strict=True))
    with tempfile.TemporaryDirectory(prefix="catchup-install-check-") as temp:
        cwd = Path(temp).resolve()
        library = cwd / "isolated library"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CATCHMEUP_", "PYTHONPATH"))}
        env.update(CATCHMEUP_HOME=str(library), CATCHMEUP_SYNC="0", CATCHMEUP_NO_OPEN="1", NO_COLOR="1")

        def run(*args, status=0):
            result = subprocess.run([executable, *args], cwd=cwd, env=env, input="", capture_output=True, text=True, timeout=45)
            assert result.returncode == status, (args, result.returncode, result.stdout, result.stderr)
            return result

        assert "catchup " in run("--version").stdout
        assert "CatchMeUp" in run("--help").stdout
        run("brain", "--help")
        assert json.loads(run("library", "--json").stdout) == []
        assert json.loads(run("search", "example", "--json").stdout) == []
        assert json.loads(run("status", "--json").stdout)["home"] == str(library)
        assert not library.exists(), "Read-only commands must not initialize a library"
        run("status", "--invalid", status=2)
        run("brain", "new", "Demo team", "--meeting")
        (cwd / "agenda.md").write_text("# Agenda\nDiscuss release readiness and test coverage.\n")
        run("materials", "demo-team", "add", "agenda.md")
        assert "agenda.md" in run("materials", "demo-team").stdout
        assert "release" in run("materials", "demo-team", "search", "release").stdout
        # Exercise the actual PDF parser inside the installed/frozen application.
        from pypdf import PdfWriter
        from pypdf.generic import NameObject, DictionaryObject, DecodedStreamObject
        pdf = PdfWriter()
        page = pdf.add_blank_page(width=300, height=300)
        font = DictionaryObject({NameObject("/Type"): NameObject("/Font"),
                                 NameObject("/Subtype"): NameObject("/Type1"),
                                 NameObject("/BaseFont"): NameObject("/Helvetica")})
        page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): font})})
        content = DecodedStreamObject()
        content.set_data(b"BT /F1 12 Tf 20 250 Td (Release checklist from a PDF) Tj ET")
        page[NameObject("/Contents")] = content
        pdf.write(cwd / "checklist.pdf")
        run("materials", "demo-team", "add", "checklist.pdf")
        assert "PDF" in run("materials", "demo-team", "search", "checklist").stdout
        assert json.loads(run("tasks", "demo-team", "--json").stdout) == []
        run("today", "--audience", "work")
        run("prepare", "demo-team")
        run("--no-input", "config", "ollama")
        run("--no-input", "watch", "demo-team", "--once")
        run("--no-input", "graph", "demo-team", "--print")
        assert not list(cwd.glob("*.docx")), "No unexpected writes to the caller directory"
    print("Installed CLI smoke checks passed (isolated library, no network).")


if __name__ == "__main__":
    smoke(sys.argv[1])
