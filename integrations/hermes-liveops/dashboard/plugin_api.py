"""Private, expiring cross-process snapshots; mounted behind Hermes dashboard auth.

Each enabled `hermes serve` backend publishes its own process-local registry.
No session activation, tool execution, provider requests, or control RPCs.
This plugin intentionally depends on the current Hermes TUI registry helpers;
an incompatible backend expires rather than reporting an invented empty run.
"""
import asyncio
from contextlib import asynccontextmanager, suppress
import json
import math
import os
from pathlib import Path
import stat
import time
import uuid

from fastapi import APIRouter

TTL_SECONDS = 8
MAX_BYTES = 2_000_000
MAX_PUBLISHERS = 64
MAX_SESSIONS = 200
MAX_CHILDREN = 500
SESSION_FIELDS = ("session_key", "title", "preview", "model", "started_at",
                  "last_active", "message_count", "status")
CHILD_FIELDS = ("subagent_id", "parent_id", "depth", "goal", "model",
                "started_at", "status", "tool_count", "last_tool")
BOOT_ID = uuid.uuid4().hex


def reporting_directory():
    from hermes_constants import get_default_hermes_root
    root = Path(get_default_hermes_root()) / "fleet-liveops"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise RuntimeError("Unsafe live reporting directory")
    root.chmod(0o700)
    return root


def collect_process_snapshot(server, registry, now):
    """Use live runtime truth, never state.db recency or `is_active` heuristics."""
    with server._sessions_lock:
        sessions = [(sid, session) for sid, session in server._sessions.items()
                    if not session.get("_finalized")][:MAX_SESSIONS]
    children = registry.list_active_subagents()[:MAX_CHILDREN]
    by_owner = {}
    for child in children:
        owner = child.get("owner_agent_session_id")
        if owner:
            by_owner.setdefault(owner, []).append(
                {key: child[key] for key in CHILD_FIELDS if key in child})
    rows = []
    for sid, session in sessions:
        item = server._session_live_item(sid, session)
        if not item.get("session_key"):
            continue
        row = {key: item[key] for key in SESSION_FIELDS if key in item}
        # Runtime IDs are only unique inside a process. This namespace is also
        # a deliberate observation-only ID: never route controls through it.
        row["id"] = f"fleet:{BOOT_ID}:{sid}"
        row["subagents"] = by_owner.get(item["session_key"], [])
        rows.append(row)
    return {"schema": 1, "pid": os.getpid(), "written_at": now, "sessions": rows}


def publish(root, payload, publisher=BOOT_ID):
    data = json.dumps(payload, allow_nan=False).encode()
    if len(data) > MAX_BYTES:
        raise ValueError("Live reporting snapshot too large")
    # Atomic replacement prevents a reader seeing a half-written JSON document.
    temp = root / f".{publisher}.tmp"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        temp.replace(root / f"{publisher}.json")
    finally:
        temp.unlink(missing_ok=True)


def publisher_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # Inaccessible is unknown, not proof the reporter stopped.


def aggregate(root, now):
    rows, publishers, stale_publishers = [], 0, 0
    for path in root.glob("*.json"):
        if publishers >= MAX_PUBLISHERS:
            break
        try:
            info = path.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_size > MAX_BYTES):
                continue
            # No symlink following, including replacement races during open.
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as stream:
                data = stream.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                continue
            payload = json.loads(data)
            age = now - payload["written_at"]
            if age > TTL_SECONDS and publisher_alive(payload.get("pid")):
                stale_publishers += 1
            if payload.get("schema") != 1 or not 0 <= age <= TTL_SECONDS:
                continue
            sessions = payload["sessions"]
            if not isinstance(sessions, list):
                continue
            publishers += 1
            for row in sessions[:MAX_SESSIONS]:
                if not isinstance(row, dict) or not isinstance(row.get("id"), str):
                    continue
                try:
                    activity = float(row.get("last_active") or 0)
                except (TypeError, ValueError):
                    continue
                if row["id"].startswith("fleet:") and math.isfinite(activity):
                    rows.append(row)
        except (OSError, ValueError, TypeError, KeyError):
            continue
    # Prefer active sessions over idle viewers when a large fleet hits the cap.
    rows.sort(key=lambda row: (row.get("status") == "idle" and not row.get("subagents"),
                               -float(row.get("last_active") or 0), row.get("id", "")))
    return {"schema": 1, "publishers": publishers, "stale_publishers": stale_publishers,
            "sessions": rows[:MAX_SESSIONS]}


async def publisher_loop(root):
    from tui_gateway import server
    from tools import delegate_tool_registry
    from hermes_cli.plugins_cmd import _get_enabled_set, _get_disabled_set
    while True:
        try:
            if "fleet-liveops" not in _get_enabled_set() or "fleet-liveops" in _get_disabled_set():
                (root / f"{BOOT_ID}.json").unlink(missing_ok=True)
                await asyncio.sleep(1)
                continue
            payload = await asyncio.to_thread(
                collect_process_snapshot, server, delegate_tool_registry, time.time())
            publish(root, payload)
        except Exception:
            # Keep serving; the previous report expires on failure. No raw
            # exception or session content is written to shared logs.
            pass
        await asyncio.sleep(1)


@asynccontextmanager
async def lifespan(app):
    root = reporting_directory()
    task = asyncio.create_task(publisher_loop(root))
    try:
        yield
    finally:
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task
        (root / f"{BOOT_ID}.json").unlink(missing_ok=True)


router = APIRouter(lifespan=lifespan)


@router.get("/snapshot")
async def snapshot():
    # Plugin routes inherit the dashboard's authentication and enablement
    # middleware. No extra listener or unauthenticated discovery endpoint.
    return await asyncio.to_thread(aggregate, reporting_directory(), time.time())
