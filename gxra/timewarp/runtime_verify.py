"""Runtime verification — compare on-disk protected files to process-held content."""

from __future__ import annotations

import json
import os
import shutil
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable, Optional

from gxra.agent.bsr_merkle import build_local_snapshot, hash_file_path


@dataclass
class FileBindingResult:
    path: str
    disk_hash: str
    status: str  # ok | disk_missing | memory_drift | not_open | error
    anchored_hash: Optional[str] = None
    memory_hash: Optional[str] = None
    holder_pids: list[int] = field(default_factory=list)
    message: str = ""


@dataclass
class RuntimeVerifyReport:
    entity_id: str
    tenant_id: str
    hostname: str
    protected_paths: list[str]
    status: str  # verified | drift | partial | error
    disk_merkle_root: Optional[str] = None
    anchored_merkle_root: Optional[str] = None
    timewarp_state_path: Optional[str] = None
    timewarp_counter: Optional[int] = None
    files: list[FileBindingResult] = field(default_factory=list)
    criu_available: bool = False
    message: str = ""
    created_at: float = field(default_factory=time.time)

    def to_dict(self) -> dict[str, Any]:
        body = asdict(self)
        body["files"] = [asdict(f) for f in self.files]
        return body


def _resolve_path(path: str) -> Path:
    return Path(path).resolve()


def _find_open_fds_for_path(target: Path) -> list[tuple[int, int]]:
    """Return (pid, fd) pairs where the process holds target open."""
    matches: list[tuple[int, int]] = []
    proc_root = Path("/proc")
    if not proc_root.is_dir():
        return matches
    try:
        target = target.resolve()
    except OSError:
        return matches

    for entry in proc_root.iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        fd_dir = entry / "fd"
        if not fd_dir.is_dir():
            continue
        try:
            for fd_entry in fd_dir.iterdir():
                if not fd_entry.name.isdigit():
                    continue
                try:
                    if fd_entry.resolve() == target:
                        matches.append((pid, int(fd_entry.name)))
                except OSError:
                    continue
        except PermissionError:
            continue
    return matches


def _find_stale_holders_for_path(target: Path) -> list[tuple[int, int]]:
    """Return (pid, fd) for open handles to a renamed sibling (path-replace tamper)."""
    matches: list[tuple[int, int]] = []
    proc_root = Path("/proc")
    if not proc_root.is_dir():
        return matches
    try:
        target = target.resolve()
    except OSError:
        return matches

    parent = target.parent
    stem = target.stem

    for entry in proc_root.iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        fd_dir = entry / "fd"
        if not fd_dir.is_dir():
            continue
        try:
            for fd_entry in fd_dir.iterdir():
                if not fd_entry.name.isdigit():
                    continue
                try:
                    resolved = fd_entry.resolve()
                except OSError:
                    continue
                if resolved.parent != parent or resolved == target:
                    continue
                if resolved.name.startswith(stem):
                    matches.append((pid, int(fd_entry.name)))
        except PermissionError:
            continue
    return matches


def _hash_fd(pid: int, fd: int) -> Optional[str]:
    import hashlib

    fd_path = Path(f"/proc/{pid}/fd/{fd}")
    digest = hashlib.sha256()
    try:
        with fd_path.open("rb") as handle:
            while True:
                chunk = handle.read(65536)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


def verify_file_binding(
    file_path: str,
    *,
    anchored_hash: Optional[str] = None,
) -> FileBindingResult:
    path = _resolve_path(file_path)
    if not path.is_file():
        return FileBindingResult(
            path=file_path,
            disk_hash="",
            status="disk_missing",
            anchored_hash=anchored_hash,
            message="Protected file not found on disk",
        )

    try:
        disk_hash = hash_file_path(str(path))
    except OSError as exc:
        return FileBindingResult(
            path=file_path,
            disk_hash="",
            status="error",
            anchored_hash=anchored_hash,
            message=str(exc),
        )

    holders = _find_open_fds_for_path(path)
    stale_holders = _find_stale_holders_for_path(path) if not holders else []
    effective_holders = holders or stale_holders
    path_replaced = bool(stale_holders and not holders)

    if not effective_holders:
        if anchored_hash and anchored_hash != disk_hash:
            return FileBindingResult(
                path=file_path,
                disk_hash=disk_hash,
                status="memory_drift",
                anchored_hash=anchored_hash,
                message="Disk hash drift vs anchor (file not held open in any process)",
            )
        return FileBindingResult(
            path=file_path,
            disk_hash=disk_hash,
            status="not_open",
            anchored_hash=anchored_hash,
            message="No process holds file open — disk-only check",
        )

    pids = sorted({pid for pid, _ in effective_holders})
    memory_hashes: set[str] = set()
    for pid, fd in effective_holders:
        mem_hash = _hash_fd(pid, fd)
        if mem_hash:
            memory_hashes.add(mem_hash)

    if not memory_hashes:
        return FileBindingResult(
            path=file_path,
            disk_hash=disk_hash,
            status="error",
            anchored_hash=anchored_hash,
            holder_pids=pids,
            message="Process holds file open but content could not be read",
        )

    if len(memory_hashes) > 1:
        return FileBindingResult(
            path=file_path,
            disk_hash=disk_hash,
            status="memory_drift",
            anchored_hash=anchored_hash,
            memory_hash=next(iter(memory_hashes)),
            holder_pids=pids,
            message="Multiple distinct in-memory copies across holders",
        )

    memory_hash = next(iter(memory_hashes))
    if memory_hash != disk_hash:
        message = "In-memory content differs from on-disk file"
        if path_replaced:
            message = (
                "Stale open FD after path replace — in-memory copy differs from on-disk file"
            )
        return FileBindingResult(
            path=file_path,
            disk_hash=disk_hash,
            status="memory_drift",
            anchored_hash=anchored_hash,
            memory_hash=memory_hash,
            holder_pids=pids,
            message=message,
        )

    if anchored_hash and anchored_hash != disk_hash:
        return FileBindingResult(
            path=file_path,
            disk_hash=disk_hash,
            status="memory_drift",
            anchored_hash=anchored_hash,
            memory_hash=memory_hash,
            holder_pids=pids,
            message="Memory matches live disk but disk drifted vs BSR anchor",
        )

    return FileBindingResult(
        path=file_path,
        disk_hash=disk_hash,
        status="ok",
        anchored_hash=anchored_hash,
        memory_hash=memory_hash,
        holder_pids=pids,
        message="Disk and in-memory copies match anchor",
    )


def read_timewarp_counter(state_path: str) -> Optional[int]:
    path = Path(state_path)
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    counter = payload.get("counter")
    return int(counter) if isinstance(counter, int) else None


def run_runtime_verify(
    *,
    entity_id: str,
    tenant_id: str,
    protected_paths: Iterable[str],
    anchored_hashes: Optional[dict[str, str]] = None,
    anchored_merkle_root: Optional[str] = None,
    timewarp_state_path: Optional[str] = None,
    hostname: Optional[str] = None,
) -> RuntimeVerifyReport:
    paths = list(protected_paths)
    anchored_hashes = anchored_hashes or {}
    file_results: list[FileBindingResult] = []

    for path in paths:
        file_results.append(
            verify_file_binding(path, anchored_hash=anchored_hashes.get(path))
        )

    disk_merkle_root: Optional[str] = None
    try:
        if paths and all(Path(p).is_file() for p in paths):
            disk_merkle_root = build_local_snapshot(paths)["merkle_root"]
    except (FileNotFoundError, ValueError):
        pass

    statuses = {r.status for r in file_results}
    if any(r.status in ("error", "disk_missing") for r in file_results):
        overall = "error"
        message = "One or more protected files could not be verified"
    elif "memory_drift" in statuses:
        overall = "drift"
        message = "Runtime binding drift detected"
    elif anchored_merkle_root and disk_merkle_root and disk_merkle_root != anchored_merkle_root:
        overall = "drift"
        message = "Disk Merkle root drift vs BSR anchor"
    elif statuses <= {"ok", "not_open"}:
        overall = "verified"
        message = "Protected files consistent (disk + open-fd where applicable)"
    else:
        overall = "partial"
        message = "Partial verification — some files not held open in memory"

    criu_available = shutil.which("criu") is not None

    return RuntimeVerifyReport(
        entity_id=entity_id,
        tenant_id=tenant_id,
        hostname=hostname or os.uname().nodename,
        protected_paths=paths,
        status=overall,
        disk_merkle_root=disk_merkle_root,
        anchored_merkle_root=anchored_merkle_root,
        timewarp_state_path=timewarp_state_path,
        timewarp_counter=read_timewarp_counter(timewarp_state_path)
        if timewarp_state_path
        else None,
        files=file_results,
        criu_available=criu_available,
        message=message,
    )
