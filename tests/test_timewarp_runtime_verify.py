"""Tests for Time-Warp runtime verify (disk vs open-fd binding)."""

from __future__ import annotations

import json
import os
from pathlib import Path

from gxra.timewarp.runtime_verify import run_runtime_verify, verify_file_binding


def test_verify_file_binding_ok(tmp_path: Path):
    path = tmp_path / "app.conf"
    path.write_text("version=1\n")
    result = verify_file_binding(str(path))
    assert result.status == "not_open"
    assert result.disk_hash
    assert len(result.disk_hash) == 64


def test_verify_file_binding_disk_drift_vs_anchor(tmp_path: Path):
    path = tmp_path / "db-state.json"
    path.write_text('{"records": 43}\n')
    anchor = verify_file_binding(str(path)).disk_hash
    path.write_text('{"records": 99}\n')
    result = verify_file_binding(str(path), anchored_hash=anchor)
    assert result.status == "memory_drift"


def test_run_runtime_verify_merkle(tmp_path: Path):
    a = tmp_path / "a.conf"
    b = tmp_path / "b.conf"
    a.write_text("a=1\n")
    b.write_text("b=2\n")
    report = run_runtime_verify(
        entity_id="ent-test",
        tenant_id="kit-lab",
        protected_paths=[str(a), str(b)],
    )
    assert report.status in ("verified", "partial")
    assert report.disk_merkle_root
    assert len(report.files) == 2


def test_verify_stale_fd_after_path_replace(tmp_path: Path):
    path = tmp_path / "db-state.json"
    path.write_text('{"records": 42}\n')
    handle = path.open("rb")
    anchor = verify_file_binding(str(path)).disk_hash
    os.rename(path, tmp_path / "db-state.json.old")
    path.write_text('{"records": 999}\n')
    result = verify_file_binding(str(path), anchored_hash=anchor)
    handle.close()
    assert result.status == "memory_drift"
    assert result.holder_pids == [os.getpid()]
    assert result.memory_hash != result.disk_hash
    assert "Stale open FD" in (result.message or "")


def test_run_runtime_verify_json_serializable(tmp_path: Path):
    path = tmp_path / "state.json"
    path.write_text('{"counter": 5}\n')
    report = run_runtime_verify(
        entity_id="ent-test",
        tenant_id="kit-lab",
        protected_paths=[str(path)],
        timewarp_state_path=str(path),
    )
    payload = report.to_dict()
    json.dumps(payload)
    assert report.timewarp_counter == 5
