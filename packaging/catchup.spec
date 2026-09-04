# One-folder bundle: no temporary unpack-on-every-run cost or second codebase.
from pathlib import Path

project = Path(SPECPATH).parent
a = Analysis(
    [str(project / "packaging" / "entrypoint.py")],
    pathex=[str(project)],
    binaries=[],
    datas=[(str(project / "LICENSE"), ".")],
    hiddenimports=[],
    hookspath=[],
    excludes=["pytest", "unittest"],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="catchup", console=True,
          strip=False, upx=False)
coll = COLLECT(exe, a.binaries, a.datas, name="catchup", strip=False, upx=False)
