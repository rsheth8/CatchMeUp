"""PyInstaller boot entry; delegates to the exact same installed CLI."""
from catchmeup.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
