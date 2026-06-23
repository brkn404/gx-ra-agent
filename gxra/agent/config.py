"""Agent configuration (~/.config/gxra-agent/config.json)."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Optional

from gxra.agent.platform import default_config_path as _default_config_path


def default_config_path() -> Path:
    return _default_config_path()


@dataclass
class AgentConfig:
    api_url: str = "http://127.0.0.1:8080"
    tenant_id: str = "default"
    entity_id: str = ""
    device_did: str = ""
    hostname: str = ""
    genome_profile: str = "agent"

    @classmethod
    def load(cls, path: Optional[Path] = None) -> "AgentConfig":
        env = os.environ.get("GXRA_AGENT_CONFIG")
        p = path or (Path(env) if env else default_config_path())
        if not p.is_file():
            cfg = cls()
            cfg.api_url = os.environ.get("GXRA_API_URL", cfg.api_url)
            cfg.tenant_id = os.environ.get("GXRA_TENANT_ID", cfg.tenant_id)
            return cfg
        data = json.loads(p.read_text())
        cfg = cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})
        if os.environ.get("GXRA_API_URL"):
            cfg.api_url = os.environ["GXRA_API_URL"]
        if os.environ.get("GXRA_TENANT_ID"):
            cfg.tenant_id = os.environ["GXRA_TENANT_ID"]
        return cfg

    def save(self, path: Optional[Path] = None) -> Path:
        env = os.environ.get("GXRA_AGENT_CONFIG")
        p = path or (Path(env) if env else default_config_path())
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(asdict(self), indent=2))
        return p
