"""Live E2E tests against running gxra-api (pilot stack).

Requires:
  - API at GXRA_API_BASE (default http://127.0.0.1:8081)
  - Agent deployed with frozen baseline (~/.config/gxra-agent/config.json)

Run:
  GXRA_API_BASE=http://192.168.68.54:8081 pytest tests/test_e2e_pilot.py -v
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
CFG = Path(os.environ.get("GXRA_AGENT_CONFIG", Path.home() / ".config/gxra-agent/config.json"))


def _headers():
    return {"X-Tenant-Id": TENANT, "Content-Type": "application/json"}


def _entity_id() -> str:
    eid = os.environ.get("ENTITY_ID")
    if eid:
        return eid
    if not CFG.is_file():
        pytest.skip(f"No agent config at {CFG} — run scripts/deploy-linux-agent.sh")
    return json.loads(CFG.read_text())["entity_id"]


@pytest.fixture(scope="module")
def client():
    with httpx.Client(base_url=API, headers=_headers(), timeout=30.0) as c:
        r = c.get("/health")
        if r.status_code != 200:
            pytest.skip(f"API not reachable at {API}")
        yield c


def test_baseline_frozen(client: httpx.Client):
    eid = _entity_id()
    r = client.get(f"/v1/entities/{eid}/behavioral-baseline", params={"compare_latest": "true"})
    r.raise_for_status()
    bl = r.json()
    assert bl["status"] == "frozen"
    assert bl["sample_count"] >= 3
    assert bl["baseline_genome_digest"]


def test_backup_scan_authorize_allow(client: httpx.Client):
    eid = _entity_id()
    bl = client.get(f"/v1/entities/{eid}/behavioral-baseline").json()
    genome = bl["baseline_genome"]
    job = f"pytest-e2e-{int(time.time())}"
    ts = time.time()

    backup = client.post(
        "/v1/webhooks/veeam/backup-complete",
        json={
            "entity_id": eid,
            "job_id": job,
            "finished_at": ts,
            "repository_path": f"s3://backups/{job}",
            "genome": genome,
            "auto_qsba": False,
            "qsba_score": 0.08,
            "bsal_level": "L2",
            "drift_envelope": "acceptable",
        },
    )
    backup.raise_for_status()
    assert backup.json()["association"]["external_snapshot_id"] == job

    scan = client.post(
        "/v1/webhooks/predatar/scan-complete",
        json={
            "external_snapshot_id": job,
            "status": "clean",
            "confidence_score": 0.98,
        },
    )
    scan.raise_for_status()

    auth = client.post(
        "/v1/recovery/authorize",
        json={"entity_id": eid, "external_snapshot_id": job},
    )
    auth.raise_for_status()
    body = auth.json()
    assert body["decision"] == "ALLOW", body

    verify = client.get("/v1/verify/assurance", params={"external_snapshot_id": job})
    verify.raise_for_status()
    assert verify.json()["ok"] is True
