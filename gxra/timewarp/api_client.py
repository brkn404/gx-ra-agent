"""GX-RA recovery control API client for capture ingest and execution reporting."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import httpx


class RecoveryApiError(RuntimeError):
    pass


class RecoveryApiClient:
    def __init__(
        self,
        base_url: str,
        tenant_id: str,
        *,
        timeout: float = 60.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.tenant_id = tenant_id
        self.timeout = timeout
        self._headers = {
            "X-Tenant-Id": tenant_id,
            "Content-Type": "application/json",
        }

    def register_target(self, target: Dict[str, Any]) -> None:
        url = f"{self.base_url}/v1/recovery/targets"
        resp = httpx.post(url, headers=self._headers, json=target, timeout=self.timeout)
        if resp.status_code not in (200, 201):
            raise RecoveryApiError(
                f"target register failed {resp.status_code}: {resp.text}"
            )

    def ingest_recovery_set(
        self,
        manifest_path: Path,
        *,
        retries: int = 3,
        backoff_sec: float = 2.0,
    ) -> Dict[str, Any]:
        raw = json.loads(manifest_path.read_text())
        keep = (
            "recovery_set_id",
            "entity_id",
            "target_id",
            "target_class",
            "status",
            "capture_window",
            "behavioral_context",
            "boundary",
            "artifacts",
            "candidate_lanes",
            "audit",
            "lab_run_dir",
        )
        payload = {k: raw[k] for k in keep if k in raw}
        if not payload.get("candidate_lanes"):
            payload["auto_rank_lanes"] = True
        else:
            payload["auto_rank_lanes"] = False
        if not payload.get("lab_run_dir"):
            payload["lab_run_dir"] = str(manifest_path.parent.resolve())

        url = f"{self.base_url}/v1/recovery/sets"
        last_err: Optional[Exception] = None
        for attempt in range(1, retries + 1):
            try:
                resp = httpx.post(
                    url, headers=self._headers, json=payload, timeout=self.timeout
                )
                if resp.status_code not in (200, 201):
                    raise RecoveryApiError(
                        f"ingest failed {resp.status_code}: {resp.text}"
                    )
                return resp.json()
            except Exception as exc:
                last_err = exc
                if attempt < retries:
                    time.sleep(backoff_sec * attempt)
        raise RecoveryApiError(f"ingest failed after {retries} attempts: {last_err}")

    def patch_execution(
        self,
        recovery_set_id: str,
        *,
        status: str,
        started_at: Optional[float] = None,
        completed_at: Optional[float] = None,
        operator_id: Optional[str] = None,
        outcome_notes: Optional[str] = None,
        lane_id: Optional[str] = None,
        selected_by: Optional[str] = None,
        set_status: Optional[str] = None,
    ) -> Dict[str, Any]:
        body: Dict[str, Any] = {
            "execution": {
                "status": status,
                "started_at": started_at,
                "completed_at": completed_at,
                "operator_id": operator_id,
                "outcome_notes": outcome_notes,
            }
        }
        if lane_id:
            body["selected_lane"] = {
                "lane_id": lane_id,
                "selected_at": completed_at or time.time(),
                "selected_by": selected_by or operator_id,
            }
        if set_status:
            body["status"] = set_status

        url = f"{self.base_url}/v1/recovery/sets/{recovery_set_id}"
        resp = httpx.patch(url, headers=self._headers, json=body, timeout=self.timeout)
        if resp.status_code != 200:
            raise RecoveryApiError(
                f"execution patch failed {resp.status_code}: {resp.text}"
            )
        return resp.json()


def load_agent_config(config_path: Optional[Path] = None) -> Dict[str, Any]:
    candidates: List[Path] = []
    if config_path:
        candidates.append(config_path)
    home = Path.home()
    candidates.extend(
        [
            Path(".gxra-agent-config.json"),
            home / ".config/gxra-agent/config.json",
        ]
    )
    for path in candidates:
        if path.is_file():
            return json.loads(path.read_text())
    return {}


def client_from_env() -> RecoveryApiClient:
    import os

    cfg = load_agent_config(
        Path(os.environ["GXRA_AGENT_CONFIG"])
        if os.environ.get("GXRA_AGENT_CONFIG")
        else None
    )
    base = (
        os.environ.get("GXRA_API_URL")
        or os.environ.get("GXRA_API_BASE")
        or cfg.get("api_url")
        or "http://127.0.0.1:8081"
    )
    tenant = os.environ.get("GXRA_TENANT_ID") or cfg.get("tenant_id") or "pilot-1"
    return RecoveryApiClient(base, tenant)
