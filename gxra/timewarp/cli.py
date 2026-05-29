"""gxra-timewarp — production Linux Time-Warp actuator CLI."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _poc_script() -> Path:
    return _repo_root() / "scripts" / "timewarp-criu-poc.sh"


def _resolve_python() -> str:
    override = os.environ.get("GXRA_TIMEWARP_PYTHON")
    if override and Path(override).is_file():
        return override
    venv = os.environ.get("VIRTUAL_ENV")
    if venv:
        candidate = Path(venv) / "bin" / "python"
        if candidate.is_file():
            return str(candidate)
    candidate = _repo_root() / ".venv" / "bin" / "python"
    if candidate.is_file():
        return str(candidate)
    return sys.executable


def _production_env() -> dict[str, str]:
    env = dict(os.environ)
    py = _resolve_python()
    env["GXRA_TIMEWARP_PYTHON"] = py
    venv_bin = str(Path(py).parent)
    env["PATH"] = f"{venv_bin}:{env.get('PATH', '')}"
    env.setdefault("GXRA_RECOVERY_INGEST", "1")
    env.setdefault("GXRA_RECOVERY_INGEST_REQUIRED", "1")
    env.setdefault("GXRA_TIMEWARP_KILL_ORIGINAL", "1")
    env.setdefault("GXRA_TIMEWARP_REATTACH_SYSTEMD", "1")
    env.setdefault("GXRA_TIMEWARP_REPORT_EXECUTION", "1")
    return env


def _run_poc(args: list[str], *, need_root: bool = False) -> int:
    script = _poc_script()
    if not script.is_file():
        print(f"Missing actuator script: {script}", file=sys.stderr)
        return 1
    cmd = ["sudo", str(script), *args] if need_root else [str(script), *args]
    if need_root and os.geteuid() != 0:
        return subprocess.call(cmd, env=_production_env())
    if os.geteuid() == 0 and cmd[0] == "sudo":
        cmd = cmd[1:]
    return subprocess.call(cmd, env=_production_env())


def _register_target_if_needed(manifest_path: Path) -> None:
    if os.environ.get("GXRA_RECOVERY_REGISTER_TARGET", "1") != "1":
        return
    from gxra.timewarp.api_client import RecoveryApiError, client_from_env, load_agent_config

    root = _repo_root()
    target_json = Path(
        os.environ.get(
            "GXRA_RECOVERY_TARGET_JSON",
            str(root / "docs/timewarp-ubuntu24-worker-target.json"),
        )
    )
    if not target_json.is_file():
        return
    raw = json.loads(manifest_path.read_text())
    entity_id = raw.get("entity_id") or load_agent_config().get("entity_id")
    if not entity_id:
        return
    target = json.loads(target_json.read_text())
    target["entity_id"] = entity_id
    target["tenant_id"] = os.environ.get("GXRA_TENANT_ID", "pilot-1")
    try:
        client_from_env().register_target(target)
    except RecoveryApiError as exc:
        if os.environ.get("GXRA_RECOVERY_INGEST_REQUIRED", "1") == "1":
            raise
        print(f"Warning: target register failed: {exc}", file=sys.stderr)


def cmd_capture(args: argparse.Namespace) -> int:
    poc_args = ["capture"]
    if args.pid:
        poc_args.append(str(args.pid))
    rc = _run_poc(poc_args, need_root=True)
    if rc != 0:
        return rc
    if args.ingest_only:
        return _cmd_ingest(args)
    return 0


def cmd_capture_set(args: argparse.Namespace) -> int:
    rc = _run_poc(["capture-set"], need_root=True)
    if rc != 0:
        return rc
    return 0


def cmd_ingest(args: argparse.Namespace) -> int:
    return _cmd_ingest(args)


def _cmd_ingest(args: argparse.Namespace) -> int:
    from gxra.timewarp.api_client import RecoveryApiError, client_from_env

    manifest = Path(args.manifest).resolve()
    if not manifest.is_file():
        print(f"Missing recovery-set.json: {manifest}", file=sys.stderr)
        return 1
    _register_target_if_needed(manifest)
    retries = int(os.environ.get("GXRA_RECOVERY_INGEST_RETRIES", "3"))
    try:
        result = client_from_env().ingest_recovery_set(manifest, retries=retries)
    except RecoveryApiError as exc:
        print(f"Recovery ingest failed: {exc}", file=sys.stderr)
        return 1
    set_id = result.get("recovery_set_id", "")
    status = result.get("status", "")
    lanes = result.get("candidate_lanes") or []
    top_lane = lanes[0]["lane_id"] if lanes else ""
    print(f"recovery_set_id={set_id} status={status}")
    if top_lane:
        print(f"top_lane={top_lane}")
    return 0


def cmd_restore(args: argparse.Namespace) -> int:
    run_dir = str(Path(args.run_dir).resolve())
    mode = "restore-set" if args.full else "restore"
    return _run_poc([mode, run_dir], need_root=True)


def cmd_report(args: argparse.Namespace) -> int:
    from gxra.timewarp.api_client import RecoveryApiError, client_from_env

    try:
        client_from_env().patch_execution(
            args.recovery_set_id,
            status=args.status,
            started_at=args.started_at,
            completed_at=time.time(),
            operator_id=args.operator or os.environ.get("USER", "gxra-timewarp"),
            outcome_notes=args.notes,
            lane_id=args.lane_id,
            set_status="executed" if args.status == "succeeded" else None,
        )
    except RecoveryApiError as exc:
        print(f"Execution report failed: {exc}", file=sys.stderr)
        return 1
    print(f"reported execution status={args.status} for {args.recovery_set_id}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="gxra-timewarp",
        description="GX-RA Linux Time-Warp actuator (CRIU + compound recovery sets)",
    )
    sub = p.add_subparsers(dest="command", required=True)

    cap = sub.add_parser("capture", help="Behavioral snapshot + CRIU capture")
    cap.add_argument("--pid", help="Existing process PID (default: demo target)")
    cap.add_argument(
        "--ingest-only",
        action="store_true",
        help="After capture, only run ingest (capture via poc separately)",
    )
    cap.set_defaults(func=cmd_capture)

    cs = sub.add_parser(
        "capture-set",
        help="Compound capture (systemd + LVM + CRIU) — set GXRA_TIMEWARP_* env",
    )
    cs.set_defaults(func=cmd_capture_set)

    ing = sub.add_parser("ingest", help="POST recovery-set.json to GX-RA API")
    ing.add_argument("manifest", help="Path to recovery-set.json")
    ing.set_defaults(func=cmd_ingest)

    rest = sub.add_parser("restore", help="Restore from capture run directory")
    rest.add_argument("run_dir", help="Capture run dir under GXRA_TIMEWARP_DIR")
    rest.add_argument(
        "--full",
        action="store_true",
        help="Storage rsync + CRIU + systemd reattach (restore-set)",
    )
    rest.set_defaults(func=cmd_restore)

    rep = sub.add_parser("report", help="PATCH execution outcome to GX-RA API")
    rep.add_argument("recovery_set_id")
    rep.add_argument("--status", default="succeeded", choices=["succeeded", "failed"])
    rep.add_argument("--lane-id", default="lane-process-storage")
    rep.add_argument("--operator", default=None)
    rep.add_argument("--notes", default=None)
    rep.add_argument("--started-at", type=float, default=None)
    rep.set_defaults(func=cmd_report)

    return p


def main(argv: list[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    rc = args.func(args)
    raise SystemExit(rc)


if __name__ == "__main__":
    main()
