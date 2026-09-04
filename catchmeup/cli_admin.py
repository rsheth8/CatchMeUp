"""Local setup and integrations shared by installed and bundled CLI builds."""
from __future__ import annotations

from collections import deque
import getpass
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

from . import paths

WATCH_LABEL = "com.rsheth8.catchmeup.watch"


def add_commands(command, as_json):
    for name, description, aliases in [
        ("status", "Library location, pending recordings, and notes", []),
        ("doctor", "Check installed capabilities without changing anything", []),
        ("list", "List exported Word notes", []),
        ("providers", "Supported AI providers", ["provider"]),
    ]:
        as_json(command(name, description, aliases))
    sub = command("setup", "Initialize the local library; optionally install Mac audio tools")
    sub.add_argument("--install-audio", action="store_true", help="Explicitly authorize Homebrew installation of missing FFmpeg/WhisperKit")
    sub = command("config", "Configure a provider; API keys are entered securely, never as command arguments")
    sub.add_argument("provider", nargs="?")
    sub.add_argument("--key-stdin", action="store_true", help="Read a key from stdin, without shell-history exposure")
    sub.add_argument("--model")
    sub.add_argument("--base-url")
    sub = command("model", "Set the model override")
    sub.add_argument("model")
    sub = command("mode", "Set the default recap style")
    sub.add_argument("mode", choices=["meeting", "lecture"])
    sub = command("logs", "Read recent pipeline logs", ["log"])
    sub.add_argument("-f", "--follow", action="store_true")
    command("open", "Open the exports folder on macOS")
    sub = command("watch", "Watch an inbox; --once processes one stable-file pass")
    sub.add_argument("scope", nargs="?", help="Brain name, meeting, or lecture")
    sub.add_argument("--once", action="store_true")
    from .cli import positive
    sub.add_argument("--interval", type=positive, default=8)
    sub = command("install-watch", "Install a macOS background inbox watcher")
    sub.add_argument("scope", nargs="?")
    command("uninstall-watch", "Remove the CatchMeUp background watcher (keeps recordings)")
    sub = command("mcp", "Connect a coding assistant to your local brains")
    sub.add_argument("action", nargs="?", choices=["run", "install"], default="run")


def executable():
    if getattr(sys, "frozen", False):
        return [sys.executable]
    return [sys.executable, "-m", "catchmeup"]


def command_environment():
    env = {"CATCHMEUP_HOME": str(paths.home())}
    # Editable/source installs need their package discoverable from launchd's cwd.
    if not getattr(sys, "frozen", False) and (paths.REPO_DIR / ".git").exists():
        env["PYTHONPATH"] = str(paths.REPO_DIR)
    env["PATH"] = os.environ.get("PATH", "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
    return env


def ensure_dirs():
    for directory in [paths.home(), paths.recordings_root(), paths.output_root(), paths.processed_root(), paths.logs_root(), paths.brains_root()]:
        directory.mkdir(parents=True, exist_ok=True)


def write_config(updates):
    """Preserve unrelated settings; replace atomically with owner-only permissions."""
    target = paths.home() / ".env"
    for value in updates.values():
        if any(c in str(value) for c in "\r\n\x00"):
            raise ValueError("Configuration values must fit on one line.")
    lines = target.read_text().splitlines() if target.is_file() else []
    keys = set(updates)
    lines = [line for line in lines if line.partition("=")[0].strip() not in keys]
    lines.extend(f"{key}={value}" for key, value in updates.items())
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".env-", dir=target.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write("\n".join(lines) + "\n")
        os.replace(temp, target)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    print(f"Saved configuration to {target}. Keep this private.")


def configure(args):
    from . import providers
    from .cli import require_input
    raw = args.provider
    if not raw:
        require_input(args, "Specify a provider, e.g. config ollama.")
        print(providers.format_provider_list(), file=sys.stderr)
        raw = input("Provider: ").strip()
    provider = providers.normalize_provider(raw)
    if not provider:
        raise ValueError("Unknown provider. Run catchup providers.")
    if provider == "custom" and not args.base_url:
        raise ValueError("Custom providers require --base-url.")
    if args.key_stdin:
        if args.no_input and sys.stdin.isatty():
            raise ValueError("Pipe the key to stdin when using --no-input.")
        key = sys.stdin.read().strip()
    elif provider == "ollama":
        key = "ollama"
    else:
        # Do not send the previous provider's generic key to a different company.
        if provider == providers.active_provider():
            key = providers.resolve_api_key(provider)
        else:
            key = next((os.environ[k] for k in providers.PROVIDERS[provider]["key_env"]
                        if k != "CATCHMEUP_API_KEY" and providers._looks_like_key(os.environ.get(k))), "")
        if not key:
            require_input(args, "Use --key-stdin or a provider API-key environment variable.")
            key = getpass.getpass("API key (hidden): ")
    if not key:
        raise ValueError("No API key supplied.")
    updates = {"CATCHMEUP_PROVIDER": provider, "CATCHMEUP_API_KEY": key,
               "CATCHMEUP_MODEL": args.model or "", "CATCHMEUP_BASE_URL": args.base_url or ""}
    updates[providers.PROVIDERS[provider]["key_env"][0]] = key
    write_config(updates)


def status():
    from . import brains
    return {"home": str(paths.home()), "default_mode": os.environ.get("CATCHMEUP_MODE", "meeting"),
            "pending": [str(p) for p in brains.media_files(paths.recordings_root())] if paths.recordings_root().exists() else [],
            "notes": [str(p) for p in sorted(paths.output_root().glob("*.docx"))],
            "watcher_installed": watch_plist().is_file() if sys.platform == "darwin" else False}


def doctor():
    from . import providers, pipeline
    checks = [{"capability": "local library", "available": True, "detail": str(paths.home())}]
    for label, resolver in [("audio conversion", pipeline.ffmpeg_bin), ("on-device transcription", pipeline.whisperkit_bin)]:
        try:
            location = resolver()
            available = bool(location and Path(location).is_file())
        except (RuntimeError, FileNotFoundError):
            location, available = "Not installed", False
        checks.append({"capability": label, "available": available, "detail": location})
    for module, label in [("pypdf", "PDF materials"), ("docx", "Word exports")]:
        checks.append({"capability": label, "available": importlib.util.find_spec(module) is not None, "detail": module})
    provider = providers.active_provider()
    checks.append({"capability": "AI configuration", "available": bool(providers.resolve_api_key(provider)),
                   "detail": f"{provider}; configuration check only, no network request"})
    return checks


def watch_plist():
    return Path.home() / "Library" / "LaunchAgents" / f"{WATCH_LABEL}.plist"


def install_watch(scope):
    if sys.platform != "darwin":
        raise ValueError("Background installation requires macOS. Use catchup watch in a terminal.")
    from .cli import resolve_scope
    from argparse import Namespace
    from . import brains
    brain, _, _ = resolve_scope(Namespace(scope=scope))
    ensure_dirs()
    inbox = brains.inbox_dir(brain) if brain else paths.recordings_root()
    inbox.mkdir(parents=True, exist_ok=True)
    target = watch_plist()
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = {"Label": WATCH_LABEL,
               "ProgramArguments": executable() + ["--no-input", "watch"] + ([scope] if scope else []) + ["--once"],
               "EnvironmentVariables": command_environment(), "WatchPaths": [str(inbox)],
               "StartInterval": 30, "RunAtLoad": True,
               "StandardOutPath": str(paths.logs_root() / "watch.out.log"),
               "StandardErrorPath": str(paths.logs_root() / "watch.err.log")}
    previous = target.read_bytes() if target.exists() else None
    subprocess.run(["launchctl", "unload", str(target)], capture_output=True)
    target.write_bytes(plistlib.dumps(payload))
    result = subprocess.run(["launchctl", "load", str(target)], capture_output=True, text=True)
    if result.returncode:
        if previous is not None:
            target.write_bytes(previous)
            subprocess.run(["launchctl", "load", str(target)], capture_output=True)
        else:
            target.unlink()
        raise RuntimeError("Could not load background watcher: " + result.stderr.strip())
    print(f"Installed watcher for {inbox}. Reinstall after moving the executable.")


def mcp_install():
    from .sync import atomic_json_write
    target = Path.cwd() / ".cursor" / "mcp.json"
    data = json.loads(target.read_text()) if target.exists() else {}
    servers = data.setdefault("mcpServers", {})
    if "catchmeup" in servers:
        raise ValueError(f"CatchMeUp is already configured in {target}; edit that entry to change it.")
    cmd = executable()
    servers["catchmeup"] = {"command": cmd[0], "args": cmd[1:] + ["mcp", "run"], "env": command_environment()}
    atomic_json_write(target, data)
    print(f"Added CatchMeUp to {target}; existing servers were preserved.")


def execute(args):
    from .cli import emit
    cmd = args.command
    if cmd == "status":
        data = status()
        if args.json:
            emit(data)
        else:
            print(f"Library: {data['home']}\nDefault mode: {data['default_mode']}\n{len(data['pending'])} pending recordings · {len(data['notes'])} exported notes")
    elif cmd == "doctor":
        checks = doctor()
        if args.json:
            emit(checks)
        else:
            for check in checks:
                print(f"{'Ready' if check['available'] else 'Missing'}: {check['capability']} — {check['detail']}")
            print("Missing audio or AI tools do not block local tasks/materials. Use catchup setup --install-audio for Mac audio tools.")
        return 0 if all(c["available"] for c in checks) else 1
    elif cmd == "setup":
        ensure_dirs()
        if args.install_audio:
            if sys.platform != "darwin" or not shutil.which("brew"):
                raise ValueError("Install Homebrew on macOS first: https://brew.sh")
            for binary, package in [("ffmpeg", "ffmpeg"), ("whisperkit-cli", "whisperkit-cli")]:
                if not shutil.which(binary):
                    subprocess.run(["brew", "install", package], check=True, stdout=sys.stderr)
        print(f"Library ready: {paths.home()}\nNext: catchup config PROVIDER, or catchup brain new NAME --lecture\nCheck capabilities: catchup doctor")
    elif cmd == "config":
        configure(args)
    elif cmd in {"mode", "model"}:
        write_config({f"CATCHMEUP_{cmd.upper()}": getattr(args, cmd)})
    elif cmd == "providers":
        from . import providers
        emit(providers.PROVIDERS) if args.json else print(providers.format_provider_list())
    elif cmd == "list":
        rows = sorted(paths.output_root().glob("*.docx"))
        emit([str(p) for p in rows]) if args.json else print("\n".join(map(str, rows)) or "No notes yet.")
    elif cmd == "logs":
        log = paths.logs_root() / "pipeline.log"
        if not log.is_file():
            print("No log yet. It appears after the first recap.")
        elif args.follow:
            import time
            with log.open() as stream:
                print("".join(deque(stream, maxlen=50)), end="", flush=True)
                while True:
                    line = stream.readline()
                    if line:
                        print(line, end="", flush=True)
                    else:
                        time.sleep(0.25)
        else:
            with log.open() as stream:
                print("".join(deque(stream, maxlen=80)), end="")
    elif cmd == "open":
        ensure_dirs()
        if sys.platform == "darwin" and not args.no_input:
            subprocess.run(["open", str(paths.output_root())], check=True)
        print(paths.output_root())
    elif cmd == "watch":
        from .watch import run
        return run(args.scope, args.once, args.interval)
    elif cmd == "install-watch":
        install_watch(args.scope)
    elif cmd == "uninstall-watch":
        target = watch_plist()
        if sys.platform != "darwin":
            raise ValueError("Background watcher management requires macOS.")
        if target.is_file():
            subprocess.run(["launchctl", "unload", str(target)], capture_output=True)
            target.unlink()
            print("Removed the watcher configuration. Recordings were kept; reinstall with install-watch.")
        else:
            print("No background watcher installed.")
    elif cmd == "mcp":
        if args.action == "install":
            mcp_install()
        else:
            from . import mcp
            mcp.main()
