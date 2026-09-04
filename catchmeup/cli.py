"""Public command contract. Handlers call the shared engine, never a shell dispatcher."""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import json
import math
import os
from pathlib import Path
import shutil
import sys

from . import __version__, paths


class Parser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        kwargs.setdefault("allow_abbrev", False)
        super().__init__(*args, **kwargs)


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a positive finite number")
    return number


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def parser():
    p = Parser(prog="catchup", description="CatchMeUp — study and work, from recordings to knowledge.",
               epilog="Start: catchup today | catchup brain new NAME --lecture | catchup help COMMAND")
    p.add_argument("--version", action="version", version=f"catchup {__version__}")
    p.add_argument("--home", metavar="DIR", help="Use this library; defaults to the user data directory (or source checkout)")
    p.add_argument("--no-input", action="store_true", help="Never prompt; interactive commands need explicit alternatives")
    p.add_argument("--debug", action="store_true", help="Show a traceback for unexpected errors")
    commands = p.add_subparsers(dest="command", parser_class=Parser, metavar="COMMAND")

    def command(name, helptext, aliases=()):
        sub = commands.add_parser(name, help=helptext, description=helptext, aliases=list(aliases))
        sub.set_defaults(command=name)
        return sub

    def as_json(sub):
        sub.add_argument("--json", action="store_true", help="JSON data only on stdout")

    def scope(sub, positional=False):
        if positional:
            sub.add_argument("scope", nargs="?", help="Brain name, meeting, or lecture")
        sub.add_argument("--brain", help="Explicit brain scope (recommended for scripts)")
        sub.add_argument("--mode", choices=["meeting", "lecture"])

    command("help", "Help for a command", ["commands", "cmds"]).add_argument("topic", nargs="*")
    from . import workspace
    workspace.add_commands(commands)

    b = command("brain", "Create and inspect course or team brains", ["brains"])
    actions = b.add_subparsers(dest="action", parser_class=Parser)
    for name, aliases in [("list", ["ls"]), ("new", ["create"]), ("show", ["info"]), ("persona", ["prompt"])]:
        sub = actions.add_parser(name, aliases=aliases)
        sub.set_defaults(action=name)
        if name == "new":
            sub.add_argument("name")
            kind = sub.add_mutually_exclusive_group()
            kind.add_argument("--lecture", "--class", dest="kind", action="store_const", const="lecture")
            kind.add_argument("--meeting", "--work", dest="kind", action="store_const", const="meeting")
            sub.set_defaults(kind="lecture")
            sub.add_argument("--persona")
        elif name in {"show", "persona"}:
            sub.add_argument("brain")
            if name == "persona":
                sub.add_argument("text", nargs="*", help="Persona text; omit to read the saved persona")
                sub.add_argument("--stdin", action="store_true", help="Read replacement persona from stdin")
        if name != "persona":
            as_json(sub)

    for name, aliases in [("library", ["history"]), ("todos", ["todo", "actions"]), ("diff", ["drift"])]:
        sub = command(name, f"{'Open follow-ups' if name == 'todos' else name.title()} from saved recaps", aliases)
        scope(sub, positional=True)
        as_json(sub)
    for name, aliases in [("search", ["find"]), ("ask", []), ("clip", ["hear"])]:
        sub = command(name, f"{name.title()} [brain|meeting|lecture] WORDS", aliases)
        sub.add_argument("words", nargs="+")
        scope(sub)
        if name == "ask":
            sub.add_argument("--closed", action="store_true", default=None, help="Answer only from saved sources")
        if name == "search":
            as_json(sub)
        if name == "clip":
            sub.add_argument("--print", dest="print_only", action="store_true", help="Show clip locations without playing audio")
    sub = command("moments", "Timestamps from the latest recap", ["bookmarks"])
    sub.add_argument("mode", nargs="?", choices=["meeting", "lecture"])
    sub = command("play", "Play a saved moment", ["jump"])
    sub.add_argument("words", nargs="+")
    scope(sub)
    sub = command("quiz", "Interactive flashcards from lecture terms", ["flashcards"])
    scope(sub, positional=True)
    sub.add_argument("-n", "--count", type=positive_int, default=8)
    for name, aliases in [("exam", ["midterm", "test"]), ("drill", ["srs"])]:
        sub = command(name, "Practice test from recaps; drill re-tests earlier misses", aliases)
        sub.add_argument("brain", nargs="?" if name == "exam" else None)
        sub.add_argument("-n", "--count", type=positive_int, default=8 if name == "exam" else 6)
        sub.add_argument("--print", dest="print_only", action="store_true")
        sub.add_argument("--answers", action="store_true")
    for name, aliases in [("think", ["analyze", "reason"]), ("cortex", []), ("walk", ["neuron"]), ("graph", ["web", "map"])]:
        sub = command(name, "Explore a brain's concepts; walk supports hop / clip / graph, without Obsidian", aliases)
        sub.add_argument("brain")
        sub.add_argument("words", nargs="+" if name == "think" else "*")
        if name == "think":
            sub.add_argument("--closed", action="store_true", default=None)
        if name in {"walk", "graph"}:
            sub.add_argument("--print", dest="print_only", action="store_true", help="Do not open an interactive interface")
    sub = command("notes", "List concept notes", ["note"])
    sub.add_argument("brain")
    sub = command("trace", "Find a path between two ideas", ["path"])
    sub.add_argument("brain")
    sub.add_argument("source")
    sub.add_argument("target", nargs="+")
    sub = command("obsidian", "Optional Obsidian vault export", ["vault"])
    sub.add_argument("brain")
    sub.add_argument("directory", nargs="?", type=Path)
    sub = command("speakers", "Nicknames: speakers TEAM 1=Jordan", ["speaker", "who"])
    sub.add_argument("brain")
    sub.add_argument("assignments", nargs="*")
    sub = command("grade", "Grade work against a brain; FILE may be - for stdin", ["homework", "hw"])
    sub.add_argument("brain")
    sub.add_argument("file")

    for name, aliases in [("meeting", ["work", "zoom"]), ("lecture", ["class", "lesson"]), ("recap", ["transcribe", "run", "process"]), ("into", ["file-into"])]:
        sub = command(name, "Transcribe and recap an audio/video file (into also accepts folders)", aliases)
        if name == "into":
            sub.add_argument("brain")
        else:
            sub.add_argument("--brain")
        sub.add_argument("file", type=Path)
        if name in {"into", "recap"}:
            sub.add_argument("--mode", choices=["meeting", "lecture"])
    sub = command("rec", "Record microphone audio; --system captures a configured loopback device", ["record", "mic"])
    sub.add_argument("scope", nargs="?")
    sub.add_argument("--devices", "--list-devices", "-l", action="store_true")
    sub.add_argument("--keep", "--no-recap", action="store_true")
    sub.add_argument("--fake", action="store_true", help=argparse.SUPPRESS)
    sub.add_argument("--system", "--loopback", "--zoom", action="store_true")
    sub.add_argument("--device", "-d")
    sub.add_argument("--seconds", "-t", type=positive)
    sub = command("drop", "Copy a recording into the inbox; never overwrite another recording", ["add"])
    sub.add_argument("file", type=Path)
    sub = command("demo", "Preview terminal visuals or a clickable graph; CATCHMEUP_PLAIN=1 disables animation", ["splash", "viz"])
    sub.add_argument("--web", "--graph", action="store_true")

    from . import cli_admin
    cli_admin.add_commands(command, as_json)
    sub = command("sync", "Share recaps with iPhone using iCloud or a shared folder", ["iphone", "ios"])
    from . import sync
    sync.add_arguments(sub)
    return p


def emit(value):
    print(json.dumps(value, ensure_ascii=False, indent=2, default=str))


def resolve_scope(args, words=None):
    from . import brains
    brain, mode = getattr(args, "brain", None), getattr(args, "mode", None)
    tokens = list(words or [])
    named = getattr(args, "scope", None)
    if named:
        if brain or mode:
            raise ValueError("Use a positional scope or --brain/--mode, not both.")
        if named in {"meeting", "lecture"}:
            mode = named
        else:
            brain = named
    elif not brain and not mode and tokens:
        if "/" not in tokens[0] and "\\" not in tokens[0] and tokens[0] not in {".", ".."} and brains.exists(tokens[0]):
            brain = tokens.pop(0)
        elif tokens[0] in {"meeting", "lecture"}:
            mode = tokens.pop(0)
    if brain:
        brains.load_brain(brain)
    return brain, mode, tokens


def require_input(args, alternative):
    if args.no_input or not sys.stdin.isatty():
        raise ValueError(f"This command needs an interactive terminal. {alternative}")


def recap(file, mode=None, brain=None):
    from . import brains, pipeline
    file = file.expanduser().resolve(strict=True)
    if brain:
        meta = brains.load_brain(brain)
        mode = mode or meta["kind"]
    args = [str(file)]
    if mode:
        args += ["--mode", mode]
    if brain:
        args += ["--brain", brain]
    if file.is_dir() and brain and not brains.pending_media(brain, file):
        print("Nothing new to file (already ingested, or no media in that folder).")
        return 0
    # The pipeline logs progress to stdout internally; public CLI progress is stderr.
    with redirect_stdout(sys.stderr):
        pipeline.main(args)
    print(f"Recap complete: {file}")


def execute(args):
    from . import brains, cortex, library
    cmd = args.command
    if cmd in {"today", "review", "prepare", "tasks", "materials"}:
        from . import workspace
        return workspace.execute(args)
    if cmd == "brain":
        action = args.action or "list"
        if action == "new":
            data = brains.create_brain(args.name, args.kind, args.persona)
            emit(data) if args.json else print(f"Created {data['slug']} ({data['kind']})\nNext: catchup into {data['slug']} FILE")
        elif action == "list":
            rows = brains.list_brains()
            if getattr(args, "json", False):
                emit(rows)
            else:
                for b in rows:
                    print(f"{b['slug']:<24} {b['kind']:<8} {b.get('recap_count', 0)} recaps")
                if not rows:
                    print("No brains yet. Create one: catchup brain new NAME --lecture")
        else:
            data = brains.load_brain(args.brain)
            if action == "show":
                emit(data)
            elif args.stdin or args.text:
                if args.stdin and args.text:
                    raise ValueError("Choose persona text or --stdin, not both.")
                if args.stdin and args.no_input and sys.stdin.isatty():
                    raise ValueError("Pipe persona text to stdin when using --no-input.")
                data["persona"] = sys.stdin.read().strip() if args.stdin else " ".join(args.text)
                brains.save_brain(data)
                print("Persona saved.")
            else:
                print(data.get("persona", ""))
    elif cmd in {"library", "search", "ask", "todos", "diff", "quiz", "clip", "play"}:
        brain, mode, words = resolve_scope(args, getattr(args, "words", None))
        if cmd in {"search", "ask", "clip", "play"} and not words:
            raise ValueError(f"Supply {'a timestamp' if cmd == 'play' else 'search or question text'} after the scope.")
        if getattr(args, "json", False):
            rows = library.list_records(mode, brain)
            if cmd == "search":
                rows = library.search_records(" ".join(words), mode, rows)
            elif cmd == "todos":
                from .workspace import followups
                rows = [{**task, "source": r.get("title")} for r in rows if r.get("mode") == "meeting"
                        for task in followups(r) if task.get("status") != "done"]
            elif cmd == "diff":
                if len(rows) < 2:
                    raise ValueError("Need at least two recaps to diff.")
                return emit(library.diff_recaps(rows[0], rows[1]))
            emit(rows)
        elif cmd in {"library", "todos", "diff"}:
            getattr(library, "cmd_" + cmd)(mode, brain)
        elif cmd == "quiz":
            require_input(args, "Use catchup exam --print for a non-interactive study sheet.")
            library.cmd_quiz(mode, args.count, brain)
        elif cmd == "play":
            if len(words) != 1:
                raise ValueError("Supply exactly one timestamp.")
            library.cmd_play(words[0], mode, brain)
        elif cmd == "ask":
            library.cmd_ask(" ".join(words), mode, brain, args.closed)
        elif cmd == "clip":
            library.cmd_clip(" ".join(words), mode, brain, args.print_only or args.no_input)
        else:
            library.cmd_search(" ".join(words), mode, brain)
    elif cmd == "moments":
        library.cmd_moments(args.mode)
    elif cmd in {"exam", "drill"}:
        from . import exam
        if not args.print_only:
            require_input(args, "Add --print to generate a study sheet; add --answers for the key.")
        exam.cmd_exam(args.brain, args.count, args.print_only, args.answers, drill=cmd == "drill")
    elif cmd in {"think", "cortex", "walk", "graph", "notes", "trace", "obsidian", "speakers", "grade"}:
        brains.load_brain(args.brain)
        text = " ".join(getattr(args, "words", [])) or None
        if cmd == "think":
            print(cortex.think(args.brain, text, log=lambda m: print(m, file=sys.stderr), closed=args.closed))
        elif cmd == "cortex":
            print(cortex.format_cortex(args.brain, query=text))
        elif cmd == "walk":
            if args.print_only or args.no_input:
                print(cortex.format_walk(args.brain, text))
            else:
                cortex.run_walk(args.brain, text)
        elif cmd == "graph":
            from . import graph
            if args.print_only or args.no_input:
                os.environ["CATCHMEUP_NO_OPEN"] = "1"
            print(graph.open_graph(args.brain, text))
        elif cmd == "notes":
            print(cortex.format_notes(args.brain))
        elif cmd == "trace":
            print(cortex.format_trace(args.brain, args.source, " ".join(args.target)))
        elif cmd == "obsidian":
            print(f"Wrote vault → {cortex.export_obsidian(args.brain, args.directory)}")
        elif cmd == "speakers":
            if any("=" not in item for item in args.assignments):
                raise ValueError("Use 1=Jordan; quote assignments containing spaces.")
            for spec in args.assignments:
                label, _, name = spec.partition("=")
                brains.set_speaker_name(args.brain, label, name)
            for label, name in brains.speaker_map(args.brain).items():
                print(f"{label} → {name}")
        elif cmd == "grade":
            if args.file == "-" and args.no_input and sys.stdin.isatty():
                raise ValueError("Pipe work to stdin when using --no-input.")
            work = sys.stdin.read() if args.file == "-" else Path(args.file).expanduser().read_text()
            print(brains.grade_work(args.brain, work, assignment=Path(args.file).name,
                                   log=lambda m: print(m, file=sys.stderr)))
    elif cmd in {"meeting", "lecture", "recap", "into"}:
        return recap(args.file, cmd if cmd in {"meeting", "lecture"} else args.mode, args.brain)
    elif cmd == "rec":
        from . import record
        if args.devices:
            return record.main(["--devices"])
        if not args.seconds and not args.fake:
            require_input(args, "Use --seconds N for timed recording.")
        brain, mode, _ = resolve_scope(args)
        mode = mode or (brains.load_brain(brain)["kind"] if brain else os.environ.get("CATCHMEUP_MODE", "meeting"))
        dest = record.suggested_path(brain)
        if dest.exists():
            raise ValueError(f"Recording already exists: {dest}. Retry in a moment.")
        print(f"Recording → {dest}", file=sys.stderr)
        record.record_audio(dest, args.device, args.seconds, args.fake, args.system)
        print(f"Saved {dest}")
        if not args.keep:
            return recap(dest, mode, brain)
    elif cmd == "drop":
        source = args.file.expanduser().resolve(strict=True)
        if not source.is_file():
            raise ValueError("Choose a recording file.")
        dest = paths.recordings_root() / source.name
        if source == dest:
            print(f"Already in recordings/: {dest}")
            return
        dest.parent.mkdir(parents=True, exist_ok=True)
        with source.open("rb") as incoming, dest.open("xb") as outgoing:
            shutil.copyfileobj(incoming, outgoing)
        print(f"Copied to {dest}")
    elif cmd == "demo":
        from . import viz
        viz.main(["--web"] if args.web else ["--animate"] if sys.stdout.isatty() and not args.no_input and not viz.plain() else [])
    elif cmd == "sync":
        from . import sync
        return sync.execute(args)
    else:
        from . import cli_admin
        return cli_admin.execute(args)


def main(argv=None):
    args_list = list(sys.argv[1:] if argv is None else argv)
    p = parser()
    # Keep the recording-file shortcut, but never let a file shadow a command.
    choices = next(a for a in p._actions if isinstance(a, argparse._SubParsersAction)).choices
    if args_list and args_list[0] not in choices and not args_list[0].startswith("-") and Path(args_list[0]).is_file():
        args_list.insert(0, "recap")
    args = p.parse_args(args_list)
    if args.home:
        os.environ["CATCHMEUP_HOME"] = str(Path(args.home).expanduser().resolve())
    if args.no_input:
        os.environ["CATCHMEUP_NO_OPEN"] = "1"
    if not args.command:
        p.print_help()
        return 0
    if args.command == "help":
        target = p
        for name in args.topic:
            action = next((a for a in target._actions if isinstance(a, argparse._SubParsersAction)), None)
            if action is None or name not in action.choices:
                p.error(f"unknown help topic: {' '.join(args.topic)}")
            target = action.choices[name]
        target.print_help()
        return 0
    try:
        paths.load_env()
        return execute(args) or 0
    except KeyboardInterrupt:
        print("Cancelled.", file=sys.stderr)
        return 130
    except BrokenPipeError:
        # Avoid a second broken-pipe traceback during interpreter shutdown.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 0
    except Exception as exc:
        if args.debug:
            raise
        if isinstance(exc, (OSError, ValueError, KeyError, RuntimeError)):
            print(f"catchup: {exc}", file=sys.stderr)
        else:
            print(f"catchup: {type(exc).__name__}. Retry with --debug for details.", file=sys.stderr)
        return 1
