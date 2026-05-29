"""Tests for gxra.timewarp.api_client."""

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from gxra.timewarp.api_client import RecoveryApiClient, RecoveryApiError


def test_ingest_retries_then_succeeds(tmp_path):
    manifest = tmp_path / "recovery-set.json"
    manifest.write_text(
        json.dumps(
            {
                "entity_id": "ent-1",
                "target_id": "rt-1",
                "capture_window": {"window_id": "w", "started_at": 1},
                "behavioral_context": {"gxra_state_id": "s1"},
                "boundary": {"boundary_type": "process_tree", "boundary_id": "x"},
                "artifacts": [],
            }
        )
    )
    client = RecoveryApiClient("http://api.test", "tenant-1")
    mock_resp_ok = MagicMock()
    mock_resp_ok.status_code = 201
    mock_resp_ok.json.return_value = {"recovery_set_id": "rs-abc", "status": "verified"}

    mock_resp_fail = MagicMock()
    mock_resp_fail.status_code = 503
    mock_resp_fail.text = "unavailable"

    with patch("gxra.timewarp.api_client.httpx.post") as post:
        post.side_effect = [
            mock_resp_fail,
            mock_resp_ok,
        ]
        result = client.ingest_recovery_set(manifest, retries=2, backoff_sec=0)
    assert result["recovery_set_id"] == "rs-abc"
    assert post.call_count == 2


def test_ingest_raises_after_retries(tmp_path):
    manifest = tmp_path / "recovery-set.json"
    manifest.write_text(
        json.dumps(
            {
                "entity_id": "ent-1",
                "target_id": "rt-1",
                "capture_window": {"window_id": "w", "started_at": 1},
                "behavioral_context": {},
                "boundary": {"boundary_type": "x", "boundary_id": "y"},
                "artifacts": [],
            }
        )
    )
    client = RecoveryApiClient("http://api.test", "t1")
    with patch("gxra.timewarp.api_client.httpx.post") as post:
        post.return_value = MagicMock(status_code=500, text="err")
        with pytest.raises(RecoveryApiError):
            client.ingest_recovery_set(manifest, retries=2, backoff_sec=0)
