"""Private, expiring cross-process snapshots; mounted behind Hermes dashboard auth.

Each enabled `hermes serve` backend publishes its own process-local registry.
No session activation, tool execution, or provider requests. This plugin
intentionally depends on the current Hermes TUI registry helpers; an
incompatible backend expires rather than reporting an invented empty run.

Push notification support (0.3.0) adds device registration and a single
control path: `POST /push/respond` verifies a single-use response token and may
answer one pending approval with `once` or `deny`. Nothing else is controllable.
"""
import asyncio
from contextlib import asynccontextmanager, suppress
import importlib
import importlib.util
import json
import math
import os
from pathlib import Path
import stat
import sys
import time
import uuid

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

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
# Files in the reporting directory that are not publisher snapshots.
RESERVED_FILES = frozenset({"push.json", "push-tokens.json"})
MAX_PUSH_REQUEST_BYTES = 8192
PACKAGE = "fleet_liveops_pkg"


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
        if path.name in RESERVED_FILES:
            continue
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


# ---- Push registration and response verification ---------------------------

def push_module(name):
    """Import a plugin module as part of one package so relative imports work
    whether Hermes loaded this file by path or a test did."""
    if PACKAGE not in sys.modules:
        root = Path(__file__).resolve().parents[1]
        spec = importlib.util.spec_from_file_location(
            PACKAGE, root / "__init__.py", submodule_search_locations=[str(root)])
        module = importlib.util.module_from_spec(spec)
        sys.modules[PACKAGE] = module
        try:
            spec.loader.exec_module(module)
        except BaseException:
            sys.modules.pop(PACKAGE, None)
            raise
    return importlib.import_module(f"{PACKAGE}.{name}")


def push_store():
    return push_module("push_store").PushStore(reporting_directory())


def relay_client():
    return push_module("push_sender").RelayClient()


def failure(code, status):
    # Stable codes only; nothing from the request is echoed.
    return JSONResponse({"error": code}, status_code=status)


async def read_json_object(request):
    declared = request.headers.get("content-length")
    if declared and (not declared.isdigit() or int(declared) > MAX_PUSH_REQUEST_BYTES):
        return None
    body = await request.body()
    if len(body) > MAX_PUSH_REQUEST_BYTES:
        return None
    try:
        parsed = json.loads(body)
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


def resolve_pending_approval(record, request_id, choice):
    """Answer one pending approval in THIS process, only if it is the request the
    token was minted for. Returns the number resolved (0 when not pending here)."""
    from tools import approval
    digest = push_module("push_payload").command_digest
    pending = [entry for entry in approval.list_gateway_approvals(record["session_key"])
               if entry.get("request_id") == request_id]
    if len(pending) != 1 or digest(pending[0].get("command")) != record["digest"]:
        return 0
    return approval.resolve_gateway_approval(record["session_key"], choice, request_id=request_id)


@router.post("/push/register")
async def push_register(request: Request):
    body = await read_json_object(request)
    if body is None:
        return failure("invalid_field", 400)
    module = push_module("push_store")
    try:
        record = module.validate_registration(body)
        device, created = await asyncio.to_thread(push_store().add_device, record)
    except module.StoreError as exc:
        if exc.code == "invalid_field":
            return failure("invalid_field", 400)
        if exc.code in ("too_many_devices", "key_id_in_use"):
            return failure(exc.code, 409)
        return failure("store_unavailable", 500)
    except ImportError:
        return failure("crypto_unavailable", 503)
    return JSONResponse(module.public_view(device), status_code=201 if created else 200)


@router.get("/push/registrations")
async def push_registrations():
    module = push_module("push_store")
    try:
        devices = await asyncio.to_thread(push_store().devices)
    except module.StoreError:
        return failure("store_unavailable", 500)
    return {"devices": [module.public_view(device) for device in devices],
            "max_devices": module.MAX_DEVICES}


@router.delete("/push/register/{registration_id}")
async def push_unregister(registration_id: str):
    module = push_module("push_store")
    if not module.LOCAL_ID.fullmatch(registration_id):
        return failure("unknown_registration", 404)
    try:
        removed = await asyncio.to_thread(push_store().remove_device, registration_id)
    except module.StoreError:
        return failure("store_unavailable", 500)
    if removed is None:
        return failure("unknown_registration", 404)
    # Local removal always happens first (it stops pushes at once). Then ask the
    # relay to drop its side; that call is idempotent, and a failure is reported
    # so the app, which also holds the capability, can retry it.
    try:
        relay_unregistered = await asyncio.to_thread(
            push_module("push_sender").unregister_at_relay, removed, relay_client())
    except Exception:
        relay_unregistered = False
    return {"removed": True, "relay_unregistered": relay_unregistered}


@router.post("/push/respond")
async def push_respond(request: Request):
    """Approve once or deny one pending approval with its single-use token."""
    body = await read_json_object(request)
    if (body is None or set(body) != {"token", "request_id", "choice"}
            or body["choice"] not in ("once", "deny")):
        return failure("invalid_field", 400)
    module = push_module("push_store")
    try:
        record = await asyncio.to_thread(
            push_store().consume_token, body["token"], body["request_id"])
    except module.StoreError as exc:
        return failure(exc.code, 401 if exc.code == "invalid_token" else 409)
    try:
        resolved = await asyncio.to_thread(
            resolve_pending_approval, record, body["request_id"], body["choice"])
    except Exception:
        resolved = 0
    if not resolved:
        return failure("not_pending", 409)
    return {"resolved": resolved}
