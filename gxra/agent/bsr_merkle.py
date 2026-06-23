"""BSR-compatible Merkle tree helpers for gxra-agent local_os snapshots."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import List


def hash_file_path(file_path: str) -> str:
    path = Path(file_path)
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _hash_pair(left: str, right: str) -> str:
    combined = bytes.fromhex(left) + bytes.fromhex(right)
    return hashlib.sha256(combined).hexdigest()


def _pad_to_power_of_two(hashes: List[str]) -> List[str]:
    n = len(hashes)
    if n == 0:
        return hashes
    next_power = 1
    while next_power < n:
        next_power <<= 1
    if next_power == n:
        return hashes
    return hashes + [hashes[-1]] * (next_power - n)


def build_merkle_root(file_hashes: List[str]) -> str:
    if not file_hashes:
        raise ValueError("Cannot build Merkle tree from empty hash list")
    current_level = _pad_to_power_of_two(file_hashes.copy())
    while len(current_level) > 1:
        next_level: List[str] = []
        for i in range(0, len(current_level), 2):
            left = current_level[i]
            right = current_level[i + 1] if i + 1 < len(current_level) else current_level[i]
            next_level.append(_hash_pair(left, right))
        current_level = next_level
    return current_level[0]


def build_local_snapshot(file_paths: List[str]) -> dict:
    hashes: List[str] = []
    for file_path in file_paths:
        path = Path(file_path)
        if not path.is_file():
            raise FileNotFoundError(f"Protected file not found: {file_path}")
        hashes.append(hash_file_path(file_path))
    return {
        "file_hashes": hashes,
        "merkle_root": build_merkle_root(hashes),
        "file_count": len(hashes),
    }
