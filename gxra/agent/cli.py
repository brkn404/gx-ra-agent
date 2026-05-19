"""GX-RA host agent CLI."""

from __future__ import annotations

import argparse
import socket
import sys
import time
from gxra.agent.client import GxraApiClient
from gxra.agent.collector import collect_host_genome, genome_digest
from gxra.agent.config import AgentConfig, default_config_path
from gxra.agent.collectors import collect_platform_signals
from gxra.agent.platform import detect_platform
from gxra.agent.virtualization import detect_virt


def _device_did(hostname: str) -> str:
    return f"did:gx:host-{hostname}"


def cmd_register(args: argparse.Namespace) -> int:
    hostname = args.hostname or socket.gethostname()
    cfg = AgentConfig.load()
    cfg.api_url = args.api_url or cfg.api_url
    cfg.tenant_id = args.tenant_id or cfg.tenant_id
    cfg.hostname = hostname
    cfg.device_did = args.device_did or _device_did(hostname)

    virt = detect_virt()
    entity_type = args.entity_type or virt.suggested_entity_type()
    source_refs = virt.to_source_refs()
    source_refs["hostname"] = hostname

    client = GxraApiClient(cfg)
    ent = client.register_entity(
        hostname=hostname,
        device_did=cfg.device_did,
        entity_type=entity_type,
        source_refs=source_refs,
    )
    cfg.entity_id = ent["entity_id"]
    path = cfg.save()
    print(
        f"Registered entity {cfg.entity_id} (tenant={cfg.tenant_id}, "
        f"type={entity_type}, virt={virt.platform}/{virt.role})"
    )
    print(f"Config saved to {path}")
    return 0


def cmd_start_learning(args: argparse.Namespace) -> int:
    cfg = AgentConfig.load()
    if not cfg.entity_id:
        print("Run `gxra-agent register` first", file=sys.stderr)
        return 1
    client = GxraApiClient(cfg)
    bl = client.start_learning(cfg.entity_id)
    print(f"Learning started at {bl['learning_started_at']} (profile={bl['genome_profile']})")
    return 0


def cmd_learn(args: argparse.Namespace) -> int:
    cfg = AgentConfig.load()
    if not cfg.entity_id:
        print("Run `gxra-agent register` first", file=sys.stderr)
        return 1
    client = GxraApiClient(cfg)
    if args.start_learning:
        client.start_learning(cfg.entity_id)

    count = args.count
    interval = args.interval
    print(f"Pushing telemetry every {interval}s ({count} samples) for {cfg.entity_id}")
    for i in range(count):
        genome = collect_host_genome(51)
        resp = client.push_telemetry(cfg.entity_id, genome, auto_qsba=args.auto_qsba)
        drift = resp.get("drift_from_baseline")
        print(
            f"  [{i + 1}/{count}] state={resp.get('state_id')} "
            f"qsba={resp.get('qsba_score'):.3f} baseline={resp.get('baseline_status')} "
            f"drift={drift}"
        )
        if i + 1 < count:
            time.sleep(interval)

    if args.freeze:
        bl = client.freeze_baseline(cfg.entity_id, min_samples=args.min_samples)
        print(f"Baseline frozen ({bl['sample_count']} samples) digest={bl.get('baseline_genome_digest', '')[:16]}…")
    return 0


def cmd_snapshot(args: argparse.Namespace) -> int:
    cfg = AgentConfig.load()
    if not cfg.entity_id:
        print("Run `gxra-agent register` first", file=sys.stderr)
        return 1
    genome = collect_host_genome(51)
    digest = genome_digest(genome)
    client = GxraApiClient(cfg)
    resp = client.push_telemetry(cfg.entity_id, genome, auto_qsba=args.auto_qsba)
    print(f"state_id={resp.get('state_id')} digest={digest[:16]}… drift={resp.get('drift_from_baseline')}")
    return 0


def cmd_push_telemetry(args: argparse.Namespace) -> int:
    return cmd_snapshot(args)


def cmd_freeze(args: argparse.Namespace) -> int:
    cfg = AgentConfig.load()
    if not cfg.entity_id:
        print("Run `gxra-agent register` first", file=sys.stderr)
        return 1
    client = GxraApiClient(cfg)
    bl = client.freeze_baseline(cfg.entity_id, min_samples=args.min_samples)
    print(json_dumps(bl))
    return 0


def json_dumps(obj: object) -> str:
    import json

    return json.dumps(obj, indent=2)


def cmd_info(args: argparse.Namespace) -> int:
    plat = detect_platform()
    signals = collect_platform_signals(plat)
    cfg_path = default_config_path()
    from gxra.agent.signals.strategy import categories_for_target, max_tier_from_env

    virt = detect_virt()
    tier_max = max_tier_from_env()
    in_scope = sorted(categories_for_target(plat.target, scope="host", max_tier=tier_max))
    print(json_dumps({
        "target": plat.target,
        "os": plat.os,
        "arch": plat.arch,
        "hostname": plat.hostname,
        "machine": plat.machine,
        "python": plat.python_version,
        "machine_id_prefix": signals.machine_id[:12] + "…",
        "virt_role": virt.role,
        "virt_platform": virt.platform,
        "virt_instance_id": virt.instance_id,
        "suggested_entity_type": virt.suggested_entity_type(),
        "config_path": str(cfg_path),
        "config_exists": cfg_path.is_file(),
        "signal_tier_max": tier_max,
        "signal_categories_in_scope": in_scope,
    }))
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    cfg = AgentConfig.load()
    if not cfg.entity_id:
        print("Run `gxra-agent register` first", file=sys.stderr)
        return 1
    client = GxraApiClient(cfg)
    bl = client.get_baseline(cfg.entity_id, compare_latest=True)
    print(json_dumps(bl))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="GX-RA host agent")
    parser.add_argument("--api-url", help="GX-RA API base URL")
    parser.add_argument("--tenant-id", help="X-Tenant-Id")
    sub = parser.add_subparsers(dest="command", required=True)

    p_reg = sub.add_parser("register", help="Register host as GX-RA entity")
    p_reg.add_argument("--hostname", help="Host display name")
    p_reg.add_argument("--device-did", help="DID (default did:gx:host-<hostname>)")
    p_reg.add_argument(
        "--entity-type",
        default=None,
        help="GX-RA entity type (default: auto from virt detection — virtual_machine, server, workload)",
    )
    p_reg.set_defaults(func=cmd_register)

    p_sl = sub.add_parser("start-learning", help="Start baseline learning window on API")
    p_sl.set_defaults(func=cmd_start_learning)

    p_learn = sub.add_parser("learn", help="Push telemetry samples on an interval")
    p_learn.add_argument("--interval", type=int, default=300, help="Seconds between pushes")
    p_learn.add_argument("--count", type=int, default=12, help="Number of samples")
    p_learn.add_argument("--start-learning", action="store_true", help="Call start-learning first")
    p_learn.add_argument("--freeze", action="store_true", help="Freeze baseline after learn")
    p_learn.add_argument("--min-samples", type=int, default=3)
    p_learn.add_argument("--no-auto-qsba", action="store_true")
    p_learn.set_defaults(func=cmd_learn, auto_qsba=True)

    p_snap = sub.add_parser("snapshot", help="One telemetry push")
    p_snap.add_argument("--no-auto-qsba", action="store_true")
    p_snap.set_defaults(func=cmd_snapshot, auto_qsba=True)

    p_push = sub.add_parser("push-telemetry", help="Alias for snapshot")
    p_push.add_argument("--no-auto-qsba", action="store_true")
    p_push.set_defaults(func=cmd_push_telemetry, auto_qsba=True)

    p_fr = sub.add_parser("freeze", help="Freeze behavioral baseline on API")
    p_fr.add_argument("--min-samples", type=int, default=3)
    p_fr.set_defaults(func=cmd_freeze)

    p_st = sub.add_parser("status", help="Show baseline status from API")
    p_st.set_defaults(func=cmd_status)

    p_info = sub.add_parser("info", help="Show OS/arch target and config path")
    p_info.set_defaults(func=cmd_info)

    args = parser.parse_args(argv)
    if getattr(args, "no_auto_qsba", False):
        args.auto_qsba = False
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
