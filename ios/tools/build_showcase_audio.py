"""Build bundled fictional narration and accurate clip offsets. macOS say + FFmpeg;
no network, API, microphone, or user recordings. Run explicitly to refresh assets.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1] / "ShowcaseAssets"

def run(*args):
    return subprocess.check_output(args, text=True).strip()

def main():
    catalog = json.loads((ROOT / "showcase-source.json").read_text())
    with tempfile.TemporaryDirectory(prefix="catchmeup-narration-") as temp:
        scratch = Path(temp)
        for entry in catalog:
            paths, starts, duration = [], [], 0.0
            for index, (heading, text) in enumerate(entry["notes"]):
                audio = scratch / f"{entry['key']}-{index}.aiff"
                run("say", "-v", "Samantha", "-r", "165", "-o", str(audio), text)
                starts.append(duration)
                duration += float(run("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(audio)))
                paths.append(audio)
            manifest = scratch / "concat.txt"
            manifest.write_text("".join(f"file '{path}'\n" for path in paths))
            output = ROOT / f"showcase-{entry['key']}.m4a"
            run("ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(manifest), "-ac", "1", "-ar", "24000", "-c:a", "aac", "-b:a", "48000", str(output))
            entry["starts"] = starts
            entry["duration"] = float(run("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(output)))
            print(f"Built {output.name}: {entry['duration']:.1f}s", flush=True)
    (ROOT / "showcase-catalog.json").write_text(json.dumps(catalog, indent=2) + "\n")

if __name__ == "__main__":
    main()
