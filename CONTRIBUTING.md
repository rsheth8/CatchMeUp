# Contributing to CatchMeUp

## Prerequisites
- macOS
- Homebrew
- Python 3.11+ (setup script creates a venv)

## Run
```bash
git clone https://github.com/rsheth8/CatchMeUp.git
cd CatchMeUp
chmod +x catchup watch_and_process.sh
./catchup setup
./catchup doctor
./catchup lecture /path/to/a/recording-you-own.m4a
```

Do **not** drop confidential work calls (HCSC, client meetings) into the repo or screenshots.

## Tests
```bash
./venv/bin/python3 -m unittest discover -s tests -v
```

iOS (optional):
```bash
cd ios && brew install xcodegen && xcodegen generate
xcodebuild -project CatchMeUp.xcodeproj -scheme CatchMeUp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Secrets
`.env` is gitignored. Never commit API keys.
