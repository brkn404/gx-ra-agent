"""Live DENY paths: hybrid TI hash + infected post-backup scan.

Requires API with threat intel bundle (same as lighthouse Act 2–3).

  GXRA_API_BASE=http://192.168.68.54:8081 pytest tests/test_e2e_deny.py -v
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

import httpx
import pytest

API = os.environ.get("GXRA_API_BASE", os.environ.get("GXRA_API_URL", "http://127.0.0.1:8081")).rstrip("/")
TENANT = os.environ.get("GXRA_TENANT_ID", "pilot-1")

# Prefer GX-RA repo bundle when running from dev machine
_GXRA_ROOT = Path(__file__).resolve().parents[2].parent / "GX-RA"
_BUNDLE = os.environ.get(
    "GXRA_THREAT_INTEL_BUNDLE",
    str(_GXRA_ROOT / "data/gxra/threat_intel") if (_GXRA_ROOT / "data/gxra/threat_intel").is_dir() else "",
)


def _headers():
    return {"X-Tenant-Id": TENANT, "Content-Type": "application/json"}


def _malware_hash() -> str:
    base = Path(_BUNDLE) if _BUNDLE else _GXRA_ROOT / "data/gxra/threat_intel"
    for name in ("ioc_bundle.json", "ioc_seed.json"):
        path = base / name
        if not path.is_file():
            seed = _GXRA_ROOT / "gxra/threat_intel/data/ioc_seed.json"
            path = seed if seed.is_file() else path
        if not path.is_file():
            continue
        raw = json.loads(path.read_text(encoding="utf-8"))
        for ind in raw.get("indicators", []):
            if ind.get("ioc_type") == "sha256" and float(ind.get("severity", 0)) > 0:
                return str(ind["value"]).lower()
    pytest.skip("No active SHA256 in threat intel bundle — set GXRA_THREAT_INTEL_BUNDLE")


@pytest.fixture(scope="module")
def client():
    with httpx.Client(base_url=API, headers=_headers(), timeout=30.0) as c:
        r = c.get("/health")
        if r.status_code != 200:
            pytest.skip(f"API not reachable at {API}")
        yield c


def _new_entity(client: httpx.Client, name: str) -> str:
    r = client.post(
        "/v1/entities",
        json={
            "entity_type": "vm",
            "display_name": name,
            "device_did": f"did:gx:pytest-{name}-{int(time.time())}",
        },
    )
    r.raise_for_status()
    return r.json()["entity_id"]


def _backup_with_l2(client: httpx.Client, entity_id: str, job: str, genome: list[float] | None = None):
    genome = genome or [0.05] * 51
    r = client.post(
        "/v1/webhooks/veeam/backup-complete",
        json={
            "entity_id": entity_id,
            "job_id": job,
            "finished_at": time.time(),
            "repository_path": f"s3://backups/{job}",
            "genome": genome,
            "auto_qsba": False,
            "qsba_score": 0.08,
            "bsal_level": "L2",
            "drift_envelope": "acceptable",
        },
    )
    r.raise_for_status()
    return job


@pytest.mark.live
def test_hybrid_malware_hash_denies(client: httpx.Client):
    malware = _malware_hash()
    eid = _new_entity(client, "deny-hybrid")
    job = f"pytest-deny-hybrid-{int(time.time())}"
    _backup_with_l2(client, eid, job)

    tel = client.post(
        "/v1/telemetry/states",
        json={
            "entity_id": eid,
            "timestamp": time.time(),
            "genome": [0.05],
            "file_hashes": [malware],
            "auto_qsba": False,
            "qsba_score": 0.08,
            "bsal_level": "L2",
            "drift_envelope": "acceptable",
        },
    )
    tel.raise_for_status()

    auth = client.post(
        "/v1/recovery/authorize",
        json={
            "entity_id": eid,
            "external_snapshot_id": job,
            "file_hashes": [malware],
        },
    )
    auth.raise_for_status()
    body = auth.json()
    assert body["decision"] == "DENY", body
    assert body.get("hybrid_score") is not None or body.get("reasons")


@pytest.mark.live
def test_infected_scan_denies(client: httpx.Client):
    eid = _new_entity(client, "deny-infected")
    job = f"pytest-deny-infected-{int(time.time())}"
    _backup_with_l2(client, eid, job)

    scan = client.post(
        "/v1/webhooks/predatar/scan-complete",
        json={
            "external_snapshot_id": job,
            "status": "infected",
            "confidence_score": 0.0,
            "findings": ["ransomware.signature"],
        },
    )
    scan.raise_for_status()

    auth = client.post(
        "/v1/recovery/authorize",
        json={"entity_id": eid, "external_snapshot_id": job},
    )
    auth.raise_for_status()
    assert auth.json()["decision"] == "DENY"
