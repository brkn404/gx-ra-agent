"""Unit tests for Linux posture category scores."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

from gxra.agent.collectors.security_posture import (
    _linux_lolbin_activity,
    _linux_volume_activity,
    collect_linux_posture,
)


def test_lolbin_detects_certutil_comm():
    mock = MagicMock()
    mock.returncode = 0
    mock.stdout = "systemd\nbash\ngxra-lab-certutil\n"
    with patch("gxra.agent.collectors.security_posture.subprocess.run", return_value=mock):
        score = _linux_lolbin_activity()
    assert score >= 0.35


def test_volume_activity_scales_with_file_count():
    mock = MagicMock()
    mock.returncode = 0
    mock.stdout = "\n".join(f"/tmp/f{i}" for i in range(120))
    with patch("gxra.agent.collectors.security_posture.subprocess.run", return_value=mock):
        score = _linux_volume_activity()
    assert score >= 0.25


def test_collect_linux_posture_includes_new_categories():
    with patch(
        "gxra.agent.collectors.security_posture._linux_backup_integrity",
        return_value=0.05,
    ), patch(
        "gxra.agent.collectors.security_posture._linux_lolbin_activity",
        return_value=0.35,
    ), patch(
        "gxra.agent.collectors.security_posture._linux_security_product",
        return_value=0.4,
    ), patch(
        "gxra.agent.collectors.security_posture._linux_auth_anomaly",
        return_value=0.05,
    ), patch(
        "gxra.agent.collectors.security_posture._linux_volume_activity",
        return_value=0.45,
    ):
        scores = collect_linux_posture()
    assert scores["auth_anomaly"] == 0.05
    assert scores["volume_activity"] == 0.45
    assert scores["lolbin_activity"] == 0.35
