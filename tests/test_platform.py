"""Smoke tests for standalone agent package."""

from gxra.agent.platform import detect_platform


def test_detect_platform():
    p = detect_platform()
    assert p.os in ("linux", "windows", "darwin")
    assert p.target
    assert len(p.hostname) >= 0
