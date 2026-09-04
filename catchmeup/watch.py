"""Inbox watching without repository scripts or stale directory locks."""
from __future__ import annotations

from argparse import Namespace
from contextlib import redirect_stdout
import os
import sys
import time

from . import brains, paths


def run(scope=None, once=False, interval=8):
    if sys.platform == "win32":
        raise ValueError("Audio inbox watching currently supports macOS/Linux.")
    import fcntl
    from .cli import resolve_scope
    from . import pipeline
    brain, mode, _ = resolve_scope(Namespace(scope=scope))
    mode = mode or (brains.load_brain(brain)["kind"] if brain else os.environ.get("CATCHMEUP_MODE", "meeting"))
    inbox = brains.inbox_dir(brain) if brain else paths.recordings_root()
    inbox.mkdir(parents=True, exist_ok=True)
    paths.logs_root().mkdir(parents=True, exist_ok=True)
    # OS releases this lock after interruption/crash. Keep the inode in place.
    with (paths.logs_root() / "watch.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if once:
                return 0
            raise RuntimeError("Another inbox watcher is already running for this library.")
        print(f"Watching {inbox}; Ctrl-C stops.", file=sys.stderr)
        while True:
            files = brains.pending_media(brain, inbox) if brain else brains.media_files(inbox)
            samples = {p: (p.stat().st_size, p.stat().st_mtime_ns) for p in files if p.exists()}
            if samples:
                time.sleep(5)
            failures = 0
            for file, signature in samples.items():
                if not file.exists() or signature != (file.stat().st_size, file.stat().st_mtime_ns):
                    continue
                try:
                    with redirect_stdout(sys.stderr):
                        pipeline.process_recording(file, mode, brain)
                except Exception:
                    failures += 1
                    pipeline.log(f"Failed: {file.name}; retry explicitly or on the next pass.")
            if once:
                return 1 if failures else 0
            time.sleep(interval)
