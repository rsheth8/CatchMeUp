"""Where CatchMeUp code lives vs where recaps live.

Code is the `catchmeup` package. User data (brains, recordings, notes, logs)
lives under CATCHMEUP_HOME, which defaults to the source checkout root.
"""
from __future__ import annotations

import os
from pathlib import Path

PACKAGE_DIR = Path(__file__).resolve().parent
REPO_DIR = PACKAGE_DIR.parent
RECORD_NAME = "catchmeup.json"


def home() -> Path:
    return Path(os.environ.get("CATCHMEUP_HOME") or REPO_DIR)


def brains_root() -> Path:
    return home() / "brains"


def processed_root() -> Path:
    return home() / "processed"


def output_root() -> Path:
    return home() / "output"


def logs_root() -> Path:
    return home() / "logs"


def recordings_root() -> Path:
    return home() / "recordings"


def load_env() -> None:
    seen: set[Path] = set()
    for path in (home() / ".env", REPO_DIR / ".env"):
        resolved = path.resolve() if path.exists() else path
        if resolved in seen or not path.is_file():
            continue
        seen.add(resolved)
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip())
