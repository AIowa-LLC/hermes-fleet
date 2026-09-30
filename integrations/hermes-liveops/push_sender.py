"""Push sender: observer hooks -> sealed payloads -> the content-blind relay.

Runs in the process that runs the agent (Desktop backend or gateway). Hooks are
observers: they never return a value, never raise, and only enqueue. A single
daemon worker builds, seals and sends off the hook thread.

Logging is limited to static messages, the local registration id and status
codes. Device tokens, send capabilities, ciphertext, previews and command text
are never logged.
"""
import json
import logging
import platform
import random
import threading
import time
import urllib.error
import urllib.request

from . import push_payload as payload_lib
from .push_store import PushStore, StoreError

LOG = logging.getLogger("fleet_liveops.push")
LOG.addHandler(logging.NullHandler())

QUEUE_MAX = 64
MAX_ATTEMPTS = 5
BACKOFF_BASE = 1.0
BACKOFF_CAP = 30.0
RETRY_AFTER_CAP = 60.0
SENT_MAX = 256
SEEN_MAX = 256
HTTP_TIMEOUT = 10
MIN_EXPIRY = 60
MAX_EXPIRY = 24 * 60 * 60 - 60
DEFAULT_TTL = {"approval": 300, "clarify": 900, "done": 6 * 3600, "cron": 6 * 3600}
PRIORITY = {"approval": 10, "clarify": 10, "done": 5, "cron": 5}
APPROVED_CHOICES = frozenset({"once", "session", "always", "smart_approve"})
DENIED_CHOICES = frozenset({"deny", "smart_deny"})
PERMANENT = frozenset({400, 401, 413, 415, 422})


class Settings:
    """Plugin settings under ``plugins.entries.fleet-liveops.settings.push``.

    Read once when the plugin registers; changing them needs a backend restart.
    """

    def __init__(self, enabled=False, generic_only=False, kinds=None, gateway_label="", ttl=None):
        self.enabled = enabled is True
        self.generic_only = generic_only is True
        self.kinds = {kind: True for kind in payload_lib.KINDS}
        for kind, value in (kinds or {}).items():
            if kind in self.kinds:
                self.kinds[kind] = value is not False
        self.gateway_label = str(gateway_label or "")[:64]
        self.ttl = dict(DEFAULT_TTL)
        for kind, value in (ttl or {}).items():
            if kind in self.ttl and isinstance(value, int) and not isinstance(value, bool):
                self.ttl[kind] = max(30, min(value, 24 * 3600))

    @classmethod
    def from_context(cls, ctx):
        def get(key, default=None):
            try:
                return ctx.get_config("push." + key, default)
            except Exception:
                return default
        kinds = {kind: get("kinds." + kind) for kind in payload_lib.KINDS}
        ttl = {"approval": get("approval_ttl_seconds"), "clarify": get("clarify_ttl_seconds")}
        return cls(get("enabled", False), get("generic_only", False),
                   {k: v for k, v in kinds.items() if v is not None}, get("gateway_label", ""), ttl)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # A redirect would carry the bearer capability elsewhere.


class RelayClient:
    """Minimal HTTPS JSON client. Returns ``(status, retry_after, error_code)``.

    Status 0 means the request never got an HTTP answer (transient).
    """

    def __init__(self, timeout=HTTP_TIMEOUT):
        self.timeout = timeout
        self._opener = urllib.request.build_opener(NoRedirect)

    def post(self, url, body, capability):
        return self._call("POST", url, body, capability)

    def delete(self, url, capability):
        """Idempotent on the relay: 204 even when the registration is already gone."""
        return self._call("DELETE", url, None, capability)

    def _call(self, method, url, body, capability):
        headers = {"Accept": "application/json", "Authorization": "Bearer " + capability,
                   "User-Agent": "fleet-liveops-push/1"}
        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                return response.status, None, None
        except urllib.error.HTTPError as exc:
            code = None
            try:
                code = json.loads(exc.read(4096)).get("error")
            except Exception:
                pass
            retry_after = None
            try:
                retry_after = float(exc.headers.get("Retry-After"))
            except (TypeError, ValueError):
                pass
            return exc.code, retry_after, code if isinstance(code, str) else None
        except Exception:
            return 0, None, None


def unregister_at_relay(device, client=None):
    """Best-effort ``DELETE /v1/register/{relay_device_id}`` with the device's
    capability. True when the relay confirms the registration is gone."""
    client = client or RelayClient()
    status, _, _ = client.delete(
        f"{device['relay_url'].rstrip('/')}/v1/register/{device['relay_device_id']}",
        device["send_capability"])
    return status in (200, 204)


def default_lookup_request_id(session_key, command):
    """Resolve the concrete request id of the approval that just started.

    The hook payload has no ``request_id`` (upstream mints it just before the
    hook; see docs/upstream-compatibility). The in-process pending queue is the
    existing read API for it. Exactly one match, or ``None``.
    """
    try:
        from tools.approval import list_gateway_approvals
        matches = [entry.get("request_id") for entry in list_gateway_approvals(session_key)
                   if entry.get("command") == command and entry.get("request_id")]
        return matches[0] if len(matches) == 1 else None
    except Exception:
        return None


def _never_raises(method):
    def wrapper(self, *args, **kwargs):
        try:
            method(self, *args, **kwargs)
        except Exception:
            LOG.debug("push hook failed", exc_info=False)
        return None  # Observers never return directives, notably from pre_tool_call.
    wrapper.__name__ = method.__name__
    wrapper.__doc__ = method.__doc__
    return wrapper


class PushSender:
    def __init__(self, store_factory, settings, *, bot="", transport=None, clock=time.time,
                 rng=random.random, lookup=default_lookup_request_id, start_thread=True):
        self.settings = settings
        self.bot = bot
        self.transport = transport or RelayClient()
        self.clock = clock
        self.rng = rng
        self.lookup = lookup
        self._store_factory = store_factory
        self._store = None
        self._start_thread = start_thread
        self._label = settings.gateway_label or platform.node().split(".")[0] or "Hermes"
        self._cond = threading.Condition()
        self._jobs = []
        self._thread = None
        self._stopped = False
        self._sent = {}  # collapse id -> {"device_ids": [...], "session_key", "digest", ...}
        self._seen = {}
        self.dropped = 0

    # ---- hooks (hot path: O(1), no I/O, never raise, never return) ------
    @_never_raises
    def on_pre_approval_request(self, **kw):
        if not self.settings.kinds["approval"] or kw.get("coalesced"):
            return
        self._enqueue({"type": "event", "kind": "approval", "command": str(kw.get("command") or ""),
                       "session_key": str(kw.get("session_key") or ""),
                       "session_id": str(kw.get("session_id") or ""),
                       "tool_call_id": str(kw.get("tool_call_id") or ""),
                       "surface": str(kw.get("surface") or "")})

    @_never_raises
    def on_post_approval_response(self, **kw):
        if not self.settings.kinds["approval"]:
            return
        choice = kw.get("choice")
        outcome = ("approved" if choice in APPROVED_CHOICES else "denied" if choice in DENIED_CHOICES
                   else "timeout" if choice == "timeout" else "cancelled")
        self._enqueue({"type": "withdraw", "command": str(kw.get("command") or ""),
                       "session_key": str(kw.get("session_key") or ""),
                       "session_id": str(kw.get("session_id") or ""),
                       "tool_call_id": str(kw.get("tool_call_id") or ""), "outcome": outcome})

    @_never_raises
    def on_pre_tool_call(self, **kw):
        # A policy hook for every tool call: compare one string and get out.
        if kw.get("tool_name") != "clarify" or not self.settings.kinds["clarify"]:
            return
        args = kw.get("args")
        args = args if isinstance(args, dict) else {}
        question = args.get("question")
        if not question and isinstance(args.get("questions"), list) and args["questions"]:
            first = args["questions"][0]
            question = first.get("question") if isinstance(first, dict) else first
        self._enqueue({"type": "event", "kind": "clarify", "command": "",
                       "question": str(question or ""), "session_key": "",
                       "session_id": str(kw.get("session_id") or ""),
                       "tool_call_id": str(kw.get("tool_call_id") or "")})

    @_never_raises
    def on_session_end(self, **kw):
        kind = "cron" if kw.get("platform") == "cron" else "done"
        if not self.settings.kinds[kind] or kw.get("interrupted"):
            return
        if not (kw.get("completed") or kw.get("failed")):
            return
        self._enqueue({"type": "event", "kind": kind, "command": "", "session_key": "",
                       "session_id": str(kw.get("session_id") or ""),
                       "turn_id": str(kw.get("turn_id") or ""),
                       "outcome": "completed" if kw.get("completed") else "failed"})

    # ---- queue -----------------------------------------------------------
    def _enqueue(self, job):
        job.setdefault("not_before", 0.0)
        with self._cond:
            if self._stopped:
                return
            if len(self._jobs) >= QUEUE_MAX:
                self._jobs.pop(0)  # drop-oldest: a fresher alert beats a stale one
                self.dropped += 1
            self._jobs.append(job)
            if self._start_thread and self._thread is None:
                self._thread = threading.Thread(target=self._run, name="fleet-liveops-push",
                                                daemon=True)
                self._thread.start()
            self._cond.notify()

    def stop(self):
        with self._cond:
            self._stopped = True
            self._jobs.clear()
            self._cond.notify_all()

    def _next_ready(self, block):
        with self._cond:
            while not self._stopped:
                now = self.clock()
                for job in self._jobs:
                    if job["not_before"] <= now:
                        self._jobs.remove(job)
                        return job
                if not block:
                    return None
                if self._jobs:
                    self._cond.wait(max(0.05, min(job["not_before"] for job in self._jobs) - now))
                else:
                    self._cond.wait()
        return None

    def _run(self):
        while True:
            job = self._next_ready(block=True)
            if job is None:
                return
            try:
                self._process(job)
            except Exception:
                LOG.debug("push job failed", exc_info=False)

    def drain(self, limit=1000):
        """Process every ready job synchronously (tests and shutdown)."""
        for _ in range(limit):
            job = self._next_ready(block=False)
            if job is None:
                return
            self._process(job)

    def pending(self):
        with self._cond:
            return len(self._jobs)

    def _process(self, job):
        handler = {"event": self._expand_event, "withdraw": self._expand_withdrawal,
                   "send": self._send}[job["type"]]
        handler(job)

    def _store_or_none(self):
        if self._store is None:
            try:
                self._store = self._store_factory()
            except Exception:
                LOG.warning("push store unavailable; dropping notification")
                return None
        return self._store

    # ---- building ----------------------------------------------------------
    def _remember(self, key, table, limit):
        if key in table:
            return False
        table[key] = True
        while len(table) > limit:
            table.pop(next(iter(table)))
        return True

    def _expand_event(self, job):
        kind = job["kind"]
        if kind in ("done", "cron"):
            key = (job["session_id"], job.get("turn_id"))
            if job.get("turn_id") and not self._remember(key, self._seen, SEEN_MAX):
                return
        store = self._store_or_none()
        devices = store.devices() if store else []
        if not devices:
            return
        now = self.clock()
        ttl = self.settings.ttl[kind]
        command = job["command"]
        digest = payload_lib.command_digest(command) if kind == "approval" else None
        ref = payload_lib.request_ref(job["session_key"], job["session_id"])
        text = command if kind == "approval" else job.get("question", "")
        preview = None if self.settings.generic_only or kind in ("done", "cron") else \
            payload_lib.preview(text)
        risk = payload_lib.classify_risk(command) if kind == "approval" else "normal"
        request_id = token = None
        if kind == "approval":
            request_id = self.lookup(job["session_key"], command)
            try:
                token = store.mint_token(session_key=job["session_key"], request_id=request_id,
                                         command_digest=digest, expires_at=now + ttl)
            except StoreError:
                token = None  # Send the alert without a response token; the app still opens.
        payload = payload_lib.build_payload(
            kind, now=now, ttl=ttl, gateway_label=self._label, bot=self.bot,
            session_id=job["session_id"], ref=ref, preview_text=preview, digest=digest, risk=risk,
            request_id=request_id, response_token=token, outcome=job.get("outcome"))
        collapse = (payload_lib.collapse_id(job["session_key"], job["tool_call_id"], digest)
                    if kind == "approval" else None)
        sent_to = self._fan_out(devices, payload_lib.serialize(payload), kind=kind, push_type="alert",
                                collapse=collapse, expires_at=now + ttl, priority=PRIORITY[kind])
        if collapse and sent_to:
            self._sent[collapse] = {"device_ids": sent_to, "session_key": job["session_key"],
                                    "digest": digest, "ref": ref, "request_id": request_id}
            while len(self._sent) > SENT_MAX:
                self._sent.pop(next(iter(self._sent)))

    def _expand_withdrawal(self, job):
        digest = payload_lib.command_digest(job["command"])
        collapse = payload_lib.collapse_id(job["session_key"], job["tool_call_id"], digest)
        record = self._sent.pop(collapse, None)
        if record is None:
            return  # Nothing was pushed for this request.
        store = self._store_or_none()
        if store is None:
            return
        try:
            store.revoke_tokens(record["session_key"], record["digest"])
        except StoreError:
            pass
        devices = [device for device in store.devices() if device["id"] in record["device_ids"]]
        now = self.clock()
        payload = payload_lib.build_withdrawal(
            now=now, ttl=self.settings.ttl["approval"], ref=record["ref"],
            session_id=job["session_id"], outcome=job["outcome"], collapse=collapse,
            digest=record["digest"], request_id=record.get("request_id"))
        self._fan_out(devices, payload_lib.serialize(payload), kind=None, push_type="background",
                      collapse=collapse, expires_at=now + self.settings.ttl["approval"], priority=5)

    def _fan_out(self, devices, plaintext, *, kind, push_type, collapse, expires_at, priority):
        delivered = []
        for device in devices:
            try:
                ciphertext = payload_lib.seal(plaintext, device["device_public_key"])
            except Exception:
                LOG.warning("could not seal to device %s; skipped", device["id"])
                continue
            now = self.clock()
            body = {"relay_device_id": device["relay_device_id"], "ciphertext": ciphertext,
                    "push_type": push_type, "priority": priority,
                    "expiry": int(max(now + MIN_EXPIRY, min(expires_at, now + MAX_EXPIRY)))}
            if collapse:
                body["collapse_id"] = collapse
            if push_type == "alert":
                body["alert"] = {"title_key": kind}
            self._enqueue({"type": "send", "device_id": device["id"], "url": device["relay_url"],
                           "capability": device["send_capability"], "body": body, "attempts": 0})
            delivered.append(device["id"])
        return delivered

    # ---- delivery ----------------------------------------------------------
    def _send(self, job):
        body = job["body"]
        now = self.clock()
        if body["expiry"] <= now:
            return  # Stale alerts are worse than none.
        status, retry_after, code = self.transport.post(
            job["url"].rstrip("/") + "/v1/send", body, job["capability"])
        if status == 200:
            return
        if status == 410:
            LOG.info("relay reports device %s unregistered; removing registration", job["device_id"])
            store = self._store_or_none()
            if store is not None:
                store.remove_device(job["device_id"])
            return
        if status in PERMANENT:
            LOG.warning("relay refused notification for device %s (status %s)", job["device_id"], status)
            return
        # 0/5xx/429 are transient; 404 unknown_device is KV replication lag right after register.
        job["attempts"] += 1
        if job["attempts"] >= MAX_ATTEMPTS or (status == 404 and code != "unknown_device"):
            LOG.warning("giving up on device %s (status %s)", job["device_id"], status)
            return
        delay = min(BACKOFF_CAP, BACKOFF_BASE * 2 ** (job["attempts"] - 1)) * (0.5 + self.rng())
        if retry_after:
            delay = max(delay, min(retry_after, RETRY_AFTER_CAP))
        job["not_before"] = now + delay
        self._enqueue(job)


_ACTIVE = {"sender": None}


def default_store():
    from hermes_constants import get_default_hermes_root
    return PushStore(get_default_hermes_root() / "fleet-liveops")


def register(ctx, *, store_factory=default_store, transport=None, start_thread=True):
    """Register the observer hooks when push is enabled. Returns the sender or ``None``."""
    settings = Settings.from_context(ctx)
    previous, _ACTIVE["sender"] = _ACTIVE["sender"], None
    if previous is not None:
        previous.stop()
    if not settings.enabled:
        return None
    if not payload_lib.hpke_available():
        LOG.warning("push disabled: the installed cryptography library has no HPKE support")
        return None
    try:
        bot = str(ctx.profile_name)
    except Exception:
        bot = ""
    sender = PushSender(store_factory, settings, bot=bot, transport=transport,
                        start_thread=start_thread)
    ctx.register_hook("pre_approval_request", sender.on_pre_approval_request)
    ctx.register_hook("post_approval_response", sender.on_post_approval_response)
    ctx.register_hook("pre_tool_call", sender.on_pre_tool_call)
    ctx.register_hook("on_session_end", sender.on_session_end)
    unload = getattr(ctx, "on_unload", None)
    if callable(unload):
        unload(sender.stop)
    _ACTIVE["sender"] = sender
    return sender
