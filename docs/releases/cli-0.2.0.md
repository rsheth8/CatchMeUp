# CatchMeUp CLI 0.2.0 — Preview

This is an early-access CLI release, not a production-certified Mac installer.

## What's new

- One Python command interface for checkout, package, and future Mac executable builds.
- Installable `catchup` command with nested help, version reporting, strict options,
  caller-relative paths, `--home`, `--no-input`, and expanded JSON output.
- Student/work workflows: course review, meeting preparation, follow-up tracking,
  and local PDF/PPTX/TXT/Markdown supporting materials.
- Safer configuration handling, overwrite protection, and user data outside installed code.
- Build recipes and automated source, wheel-installation, and Mac-bundle smoke checks.

## Install

Install pipx first, then download the wheel and SHA256SUMS from this release.
Verify the wheel's SHA-256 against its entry in SHA256SUMS before installing:

```sh
pipx install /absolute/path/to/catchmeup-0.2.0-py3-none-any.whl
catchup --version
catchup setup
catchup today
```

Python 3.10+ is required for package/source installation. macOS users can explicitly
install missing audio tools with `catchup setup --install-audio` after installing
Homebrew. Local tasks/materials need neither audio tools nor an API key.

For an existing library, use `catchup --home /absolute/path/to/your/library today`
or set `CATCHMEUP_HOME`. No automatic data migration or deletion occurs. Back up
your library before trying a preview release.

## Validation and limitations

- 150 local Python tests passed; clean-wheel and Apple Silicon bundle smoke checks
  passed with isolated synthetic data, including PDF import. These checks do not
  call live AI services, transcribe real recordings, or validate real-device sync.
- The attached wheel/source archives are audited to exclude credentials, recordings,
  and local course data. Checksums detect mismatched files, not platform notarization.
- No PyPI package, Homebrew tap, or signed/notarized Mac installer is published here.
  The unsigned/ad-hoc-signed bundle remains a developer build and is not attached.
- Microphone capture and WhisperKit are Mac-specific. Windows is not validated.
- Material extraction is text-based, not full visual/OCR understanding. Material
  files do not sync to iPhone yet; study and CLI/iPhone feature parity are incomplete.
- AI requests may send source text to your chosen provider. Audio syncing is optional
  and may upload recordings through the configured shared-folder service.

See the repository README and `docs/CLI_DISTRIBUTION.md` for setup, architecture,
known limitations, and the remaining stable-release gates.
