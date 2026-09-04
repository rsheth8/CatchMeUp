"""Reject unexpected project files in release source and wheel archives."""
from pathlib import Path, PurePosixPath
import sys
import tarfile
import zipfile


def audit(path):
    if path.suffix == ".whl":
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
        for name in names:
            parts = PurePosixPath(name).parts
            assert parts and (parts[0] == "catchmeup" or parts[0].endswith(".dist-info")), name
    else:
        with tarfile.open(path) as archive:
            members = archive.getmembers()
            assert all(not m.issym() and not m.islnk() for m in members), "No archive links allowed"
            names = [m.name for m in members]
        allowed = {"catchmeup", "catchmeup.egg-info", "tests", "packaging", "docs",
                   "README.md", "LICENSE", "pyproject.toml", "MANIFEST.in", "PKG-INFO",
                   "setup.cfg", "catchup", "watch_and_process.sh"}
        for name in names:
            parts = PurePosixPath(name).parts
            assert len(parts) == 1 or parts[1] in allowed, name
    for name in names:
        parts = PurePosixPath(name).parts
        assert ".." not in parts and not name.startswith("/"), name
        assert not any(p.startswith(".env") for p in parts), name
        assert not any(p in {"brains", "recordings", "processed", "logs", "output", "GraphQL-Crash-Course"} for p in parts), name
        assert PurePosixPath(name).suffix not in {".m4a", ".wav", ".mp3", ".mov", ".mp4"}, name
    print(f"Artifact content audit passed: {path.name} ({len(names)} entries)")


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        audit(Path(arg))
