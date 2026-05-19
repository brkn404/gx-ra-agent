"""HTTP client for GX-RA API."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import httpx

from gxra.agent.config import AgentConfig


class GxraApiClient:
    def __init__(self, config: AgentConfig):
        self.config = config
        self.base = config.api_url.rstrip("/")
        self.headers = {
            "X-Tenant-Id": config.tenant_id,
            "Content-Type": "application/json",
        }

    def register_entity(
        self,
        *,
        hostname: str,
        device_did: str,
        entity_type: str = "vm",
        source_refs: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        refs = {"hostname": hostname, "agent": "gxra-agent"}
        if source_refs:
            refs.update(source_refs)
        payload = {
            "entity_type": entity_type,
            "display_name": hostname,
            "device_did": device_did,
            "genome_profile": "agent",
            "source_refs": refs,
        }
        r = httpx.post(
            f"{self.base}/v1/entities",
            headers=self.headers,
            json=payload,
            timeout=30.0,
        )
        r.raise_for_status()
        return r.json()

    def start_learning(self, entity_id: str) -> Dict[str, Any]:
        r = httpx.post(
            f"{self.base}/v1/entities/{entity_id}/behavioral-baseline/start-learning",
            headers=self.headers,
            timeout=30.0,
        )
        r.raise_for_status()
        return r.json()

    def freeze_baseline(self, entity_id: str, min_samples: int = 3) -> Dict[str, Any]:
        r = httpx.post(
            f"{self.base}/v1/entities/{entity_id}/behavioral-baseline/freeze",
            headers=self.headers,
            json={"min_samples": min_samples},
            timeout=30.0,
        )
        r.raise_for_status()
        return r.json()

    def get_baseline(
        self, entity_id: str, *, compare_latest: bool = False
    ) -> Dict[str, Any]:
        r = httpx.get(
            f"{self.base}/v1/entities/{entity_id}/behavioral-baseline",
            headers=self.headers,
            params={"compare_latest": str(compare_latest).lower()},
            timeout=30.0,
        )
        r.raise_for_status()
        return r.json()

    def push_telemetry(
        self,
        entity_id: str,
        genome: List[float],
        *,
        timestamp: Optional[float] = None,
        auto_qsba: bool = True,
    ) -> Dict[str, Any]:
        import time as _time

        payload = {
            "entity_id": entity_id,
            "timestamp": timestamp or _time.time(),
            "genome": genome,
            "genome_profile": "agent",
            "auto_qsba": auto_qsba,
        }
        r = httpx.post(
            f"{self.base}/v1/telemetry/states",
            headers=self.headers,
            json=payload,
            timeout=60.0,
        )
        r.raise_for_status()
        return r.json()
