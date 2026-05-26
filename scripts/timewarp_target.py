#!/usr/bin/env python3
"""Simple mutable process for Linux CRIU Time-Warp proof-of-capability."""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
from pathlib import Path


running = True


def _handle_stop(signum, frame):  # type: ignore[no-untyped-def]
    global running
    running = False


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Mutable demo target for CRIU checkpoint/restore proofs"
    )
    parser.add_argument(
        "--state-file",
        required=True,
        help="Path to JSON state file updated every tick",
    )
    parser.add_argument(
        "--blob-mb",
        type=int,
        default=8,
        help="Approximate in-memory blob size (MiB)",
    )
    parser.add_argument(
        "--tick-sec",
        type=float,
        default=1.0,
        help="Seconds between state updates",
    )
    parser.add_argument(
        "--label",
        default="timewarp-demo",
        help="Friendly label for manifest/state output",
    )
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)

    state_path = Path(args.state_file)
    state_path.parent.mkdir(parents=True, exist_ok=True)

    # Keep mutable memory pages active so checkpoint/restore is meaningful.
    blob = bytearray(os.urandom(max(1, args.blob_mb) * 1024 * 1024))
    counter = 0
    started_at = time.time()

    while running:
        idx = counter % len(blob)
        blob[idx] = (blob[idx] + counter + 1) % 256

        payload = {
            "label": args.label,
            "pid": os.getpid(),
            "started_at": started_at,
            "updated_at": time.time(),
            "counter": counter,
            "blob_mb": args.blob_mb,
            "sample_hex": bytes(blob[idx : idx + 16]).hex(),
        }
        state_path.write_text(json.dumps(payload, indent=2))
        counter += 1
        time.sleep(args.tick_sec)

    payload = {
        "label": args.label,
        "pid": os.getpid(),
        "stopped_at": time.time(),
        "counter": counter,
        "blob_mb": args.blob_mb,
    }
    state_path.write_text(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
