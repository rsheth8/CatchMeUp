# CLI architecture and distribution

## Decision

Maintain one Python CLI (`catchmeup.cli:main`) and one shared domain engine. Ship
that same interface as a standard Python package and, for Mac users who should
not manage Python, a bundled executable. Do not rewrite the engine in another
language just to distribute a binary. Do not maintain a parallel Bash command
implementation. The root `catchup` script is now only a source-checkout launcher;
`python -m catchmeup`, the installed `catchup`, and the bundle call the same code.

This follows the Python Packaging Authority's [command-line packaging guidance](https://packaging.python.org/en/latest/guides/creating-command-line-tools/).
The initial bundle uses PyInstaller's [one-folder mode](https://pyinstaller.org/en/stable/operating-mode.html):
users keep the executable and `_internal` together. It avoids unpacking an entire
Python environment on every invocation. It is not a single-file static binary.

Target for general Mac distribution: a versioned, signed/notarized bundle exposed
as `catchup` by a Homebrew tap, with an optional signed installer for users who do
not use Homebrew. These channels are not published yet. They should install the
same artifact, not introduce another runtime implementation. A tap can also use
Homebrew's [isolated Python application layout](https://docs.brew.sh/Language-Specific-Formulae)
if maintaining frozen bundles proves more expensive than shipping wheels.

## What is implemented

- A console entry point and module entry point with strict argparse parsing.
- One version in `catchmeup.__version__`, also used for package metadata.
- Nested help (`catchup help brain new` and `catchup brain new --help`).
- `--version`, `--home DIR`, `--no-input`, and `--debug` before the command.
- JSON output for `library`, `search`, `todos`, `diff`, `tasks`, `brain list/new/show`,
  `status`, `list`, `providers`, and `doctor`. Successful JSON output contains data
  only. Other commands reject `--json`; JSON is not universal yet.
- Exit status 0 for success, 1 for operational failure, 2 for invalid syntax,
  and 130 for user cancellation. A doctor result of 1 means one or more optional
  capabilities are unavailable; local study/work commands may still work.
- Caller-relative file paths; no directory-changing launcher.
- Secure hidden key entry / piped key entry; no positional API-key arguments.
- Owner-only, atomic config writes preserving unrelated settings. Environment
  variables override settings in the selected library's `.env`.
- Explicit audio dependency installation (`setup --install-audio`); plain setup
  initializes folders without downloading software or requiring an API key.
- Watchers, recording, graph, MCP, study, work, and material commands call Python
  directly. Old launchd scripts retain a compatibility shim.
- CI definitions for source tests, clean wheel installation and out-of-checkout
  smoke checks; an unsigned/ad-hoc-signed Mac executable candidate and checksum.
  CI never publishes releases or uses publishing credentials.

Some engine text still says `./catchup`; installed users should read that as
`catchup`. Persona without replacement text now *shows* the saved persona instead
of prompting to overwrite it. Use `brain persona NAME TEXT` or `--stdin` to edit.
Unknown options now fail instead of being silently ignored. For scripts prefer
`search --brain NAME WORDS` over inferred positional scopes.

## Data and upgrade safety

An explicit `--home DIR` (one invocation) or `CATCHMEUP_HOME` (persistent environment
setting) wins. Source checkouts retain their repository-local library. Installed
packages and bundles use:

| Platform | Default library |
|---|---|
| macOS | `~/Library/Application Support/CatchMeUp` |
| Linux | `$XDG_DATA_HOME/catchmeup`, otherwise `~/.local/share/catchmeup` |
| Windows | `%LOCALAPPDATA%/CatchMeUp` |

Only local library workflows are intended to be portable; microphone capture,
WhisperKit, and background launchd integration remain Mac-specific. Windows
distribution is not validated. No command automatically relocates an old library.
When moving from a checkout to an installed version, set `CATCHMEUP_HOME` to the
existing checkout directory. This reuses recordings and IDs without copying or
renumbering data. Back up that directory before a future schema migration.

No user data or credentials belong under the installed package or bundle. No
fallback reads another library's `.env`. Read-only help, version, status, and list
operations do not initialize a library. Upgrading the application should not
replace the data directory. Uninstalling the application should not delete it.

## Build and verify locally

From a development checkout with a Python virtual environment:

```sh
venv/bin/python3 -m pip install -e '.[build]'
venv/bin/python3 -m unittest discover -q
venv/bin/python3 -m build
venv/bin/python3 -m twine check dist/*.whl dist/*.tar.gz
venv/bin/python3 packaging/audit.py dist/*.whl dist/*.tar.gz
venv/bin/python3 -m PyInstaller --noconfirm packaging/catchup.spec
venv/bin/python3 packaging/smoke.py dist/catchup/catchup
```

Install the wheel in a separate clean environment and pass its `bin/catchup` to
`packaging/smoke.py` as well. That script changes to a temporary working directory,
removes PYTHONPATH, and uses synthetic material files and an isolated library.
It performs no AI, microphone, or sync operations. Artifact content checks should
reject credentials, recordings, course corpora, and project-local data.

PyInstaller builds are OS/architecture-specific. The workflow currently builds
on macos-14 and names the archive with the actual architecture; it does not claim
Intel or older macOS support. Validate compatibility on each supported target.
FFmpeg, WhisperKit, and model weights are not embedded in this bundle. `doctor`
explains available capabilities, and `setup --install-audio` installs the Mac
audio tools through Homebrew when requested. Ollama is an optional separate install.

## Preview publication and gates before stable distribution

The GitHub `v0.2.0` release is marked **pre-release** and distributes the audited
Python wheel/source archive plus checksums. It does not publish to PyPI or ship
the unsigned Mac bundle as a general-user download. The following gates still
apply before calling the product stable or distributing a trusted Mac installer.

1. Run the CI matrix successfully and audit the built wheel/source/bundle contents.
2. Exercise actual microphone permissions, WhisperKit, provider calls, cancellation,
   large recordings, and iPhone sync on clean supported Macs. Unit tests and smoke
   tests do not establish those integrations work in a frozen runtime.
3. Freeze/review release dependencies, generate a dependency/license inventory,
   and define supported macOS versions and architectures. The current dependency
   ranges are not a reproducible release lock.
4. Sign the complete bundle with the project's Apple Developer identity, notarize
   the distributable, and verify Gatekeeper behavior on another Mac. The current
   candidate is a developer test build, not a trusted public download. Never tell
   users to disable Gatekeeper to run it.
5. Create the approved release channel and Homebrew tap/installer. Publish immutable
   versioned assets and checksums only after approval; do not publish mutable builds
   from `main` as stable releases. Configure signing/publishing credentials through
   protected release environments, not repository files.
6. Test upgrading and rolling back the executable against an existing library;
   introduce schema versions and backup/migration tests before incompatible data
   changes. Keep package updates explicit—no background self-updater for now.

Later usability work: shell completion, more structured outputs with documented
schema evolution, macOS Keychain storage, and an installer that handles optional
audio dependencies without requiring the user to understand Python.
