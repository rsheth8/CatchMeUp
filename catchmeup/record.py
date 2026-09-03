#!/usr/bin/env python3
"""Record from the Mac microphone into CatchMeUp (ffmpeg + AVFoundation)."""
from __future__ import annotations

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from . import brains


def ffmpeg_bin() -> str:
    found = shutil.which("ffmpeg")
    for candidate in (found, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
        if candidate and Path(candidate).exists():
            return candidate
    raise FileNotFoundError("ffmpeg not found. brew install ffmpeg")


LOOPBACK_HINTS = (
    "blackhole", "loopback", "zoomaudio", "zoom audio", "soundflower",
    "aggregate", "multi-output", "vb-audio", "vb cable", "cable input",
    "captures", "system audio",
)


def parse_avfoundation_audio(stderr: str) -> list[tuple[int, str]]:
    devices = []
    in_audio = False
    for line in (stderr or "").splitlines():
        if "AVFoundation audio devices" in line:
            in_audio = True
            continue
        if "AVFoundation video devices" in line:
            in_audio = False
            continue
        if not in_audio:
            continue
        m = re.search(r"\[(\d+)\]\s+(.+)$", line)
        if m:
            devices.append((int(m.group(1)), m.group(2).strip()))
    return devices


def is_loopback_name(name: str) -> bool:
    blob = (name or "").lower()
    return any(h in blob for h in LOOPBACK_HINTS)


def pick_system_device(devices: list[tuple[int, str]]) -> tuple[int, str] | None:
    """Prefer BlackHole / Loopback, then Zoom's virtual device, then any loopback."""
    ranked = ("blackhole", "loopback", "zoomaudio", "zoom audio")
    for hint in ranked:
        for idx, name in devices:
            if hint in name.lower():
                return idx, name
    for idx, name in devices:
        if is_loopback_name(name):
            return idx, name
    return None


def list_audio_devices() -> list[tuple[int, str]]:
    proc = subprocess.run(
        [ffmpeg_bin(), "-f", "avfoundation", "-list_devices", "true", "-i", ""],
        capture_output=True,
        text=True,
    )
    blob = (proc.stderr or "") + "\n" + (proc.stdout or "")
    return parse_avfoundation_audio(blob)


def default_device() -> str:
    return (os.environ.get("CATCHMEUP_AUDIO_DEVICE") or "0").strip() or "0"


def fake_mic_requested() -> bool:
    return (os.environ.get("CATCHMEUP_FAKE_MIC") or "").strip() in {"1", "true", "yes"}


def record_audio(
    dest: Path,
    device: str | None = None,
    seconds: float | None = None,
    fake: bool = False,
    system: bool = False,
) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    ff = ffmpeg_bin()
    if fake or fake_mic_requested():
        dur = seconds if seconds and seconds > 0 else 1.0
        cmd = [
            ff, "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", f"sine=frequency=440:duration={dur}",
        ]
        if dest.suffix.lower() in {".m4a", ".aac", ".mp4"}:
            cmd += ["-c:a", "aac"]
        cmd.append(str(dest))
        subprocess.run(cmd, check=True)
        return dest

    if sys.platform != "darwin":
        raise RuntimeError("./catchup rec uses the Mac microphone (AVFoundation).")

    idx = (device or "").strip()
    if system and not idx:
        devices = list_audio_devices()
        picked = pick_system_device(devices)
        if not picked:
            names = ", ".join(n for _, n in devices) or "(none)"
            raise RuntimeError(
                "No system-audio device found. Zoom/Meet don't show up as the Mac mic.\n"
                "  • If Zoom is running, try ZoomAudioDevice: ./catchup rec --devices\n"
                "  • Or install BlackHole (free), set it as Zoom's speaker, then:\n"
                "      ./catchup rec --system\n"
                f"  Devices I can see: {names}"
            )
        idx, label = str(picked[0]), picked[1]
        print(f"System audio → [{idx}] {label}")
    if not idx:
        idx = default_device()
    cmd = [
        ff, "-y", "-hide_banner",
        "-f", "avfoundation",
        "-i", f":{idx}",
    ]
    if seconds and seconds > 0:
        cmd += ["-t", str(seconds)]
    cmd += ["-ac", "1", "-ar", "44100", "-c:a", "aac", str(dest)]

    from . import viz

    err_log = dest.with_suffix(dest.suffix + ".ffmpeg.log")
    live = viz.use_tty()
    with open(err_log, "w") as errf:
        proc = subprocess.Popen(cmd, stderr=errf if live else None)
        start = time.time()
        try:
            while proc.poll() is None:
                if live:
                    sys.stdout.write("\r" + viz.rec_frame(time.time() - start) + "\033[K")
                    sys.stdout.flush()
                try:
                    proc.wait(timeout=0.08)
                except subprocess.TimeoutExpired:
                    continue
            rc = proc.returncode
        except KeyboardInterrupt:
            if live:
                print()
            proc.send_signal(signal.SIGINT)
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
            rc = 0
    if live:
        print()
    if err_log.exists():
        blob = err_log.read_text() if rc not in (0, None) else ""
        err_log.unlink(missing_ok=True)
    else:
        blob = ""
    if rc not in (0, None) and (not dest.exists() or dest.stat().st_size < 1000):
        extra = f"\n{blob[-800:]}" if blob else ""
        raise RuntimeError(
            f"ffmpeg recording failed (exit {rc}). "
            "Grant Terminal/iTerm microphone access, or pick a device: ./catchup rec --devices"
            + extra
        )
    if not dest.exists() or dest.stat().st_size < 200:
        raise RuntimeError("Recording was empty. Try ./catchup rec --devices")
    return dest


def suggested_path(brain: str | None = None, suffix: str = ".m4a") -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    name = f"rec-{stamp}{suffix}"
    if brain:
        return brains.inbox_dir(brain) / name
    return brains.recordings_root() / name


def main(argv=None):
    parser = argparse.ArgumentParser(prog="catchup-rec")
    parser.add_argument("--devices", action="store_true", help="List audio input devices")
    parser.add_argument("-o", "--out", help="Destination file")
    parser.add_argument("-d", "--device", help="AVFoundation audio device index")
    parser.add_argument("-t", "--seconds", type=float, help="Stop after this many seconds")
    parser.add_argument("--brain")
    parser.add_argument("--fake", action="store_true", help="Generate a test tone instead of using the mic")
    parser.add_argument(
        "--system",
        action="store_true",
        help="Capture Zoom/Meet via BlackHole, Loopback, or ZoomAudioDevice",
    )
    args = parser.parse_args(argv)

    if args.devices:
        if fake_mic_requested() or sys.platform != "darwin":
            print("0\t(fake sine — CATCHMEUP_FAKE_MIC)")
            return
        devices = list_audio_devices()
        if not devices:
            print("No AVFoundation audio devices found.")
            print("Grant microphone permission to Terminal, then retry.")
            sys.exit(1)
        print("index\tdevice")
        for idx, name in devices:
            tag = "  [system]" if is_loopback_name(name) else ""
            print(f"{idx}\t{name}{tag}")
        print("\nMic:     ./catchup rec --device 0")
        print("Zoom:    ./catchup rec --system")
        print("Or:      CATCHMEUP_AUDIO_DEVICE=1 ./catchup rec")
        return

    dest = Path(args.out) if args.out else suggested_path(args.brain)
    if dest.suffix.lower() not in {".m4a", ".wav", ".mp3", ".aac"}:
        dest = dest.with_suffix(".m4a")
    print(f"Recording → {dest}")
    fake = args.fake or fake_mic_requested()
    if not fake:
        from . import viz
        if not viz.use_tty():
            print("Speak. Ctrl-C stops.")
    path = record_audio(
        dest,
        device=args.device,
        seconds=args.seconds,
        fake=args.fake,
        system=args.system,
    )
    if fake:
        from . import viz
        print(viz.rec_frame(args.seconds or 1.0))
    print(path)


if __name__ == "__main__":
    main()
