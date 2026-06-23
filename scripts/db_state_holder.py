#!/usr/bin/env python3
"""Hold a protected config file open for runtime memory-vs-disk binding tests."""

from __future__ import annotations

import argparse
import signal
import sys
import time
from pathlib import Path

running = True


def _stop(_signum, _frame) -> None:  # type: ignore[no-untyped-def]
    global running
    running = False


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Keep a file descriptor open so /proc/pid/fd binding checks apply"
    )
    parser.add_argument("path", help="File to hold open (e.g. db-state.json)")
    parser.add_argument(
        "--refresh-sec",
        type=float,
        default=30.0,
        help="Re-read interval to keep page cache warm (default 30s)",
    )
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    path = Path(args.path)
    if not path.is_file():
        print(f"missing file: {path}", file=sys.stderr)
        return 1

    handle = path.open("rb")
    print(f"holding fd={handle.fileno()} pid={__import__('os').getpid()} path={path}")
    sys.stdout.flush()

    while running:
        handle.seek(0)
        _ = handle.read(65536)
        time.sleep(args.refresh_sec)

    handle.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
