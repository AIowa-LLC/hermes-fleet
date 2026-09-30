"""Private cross-process state for the push sender.

The agent hooks (which run in the gateway or Desktop backend) and the dashboard
API (which registers devices and verifies response tokens) are different
processes, so state lives in the same owner-only directory the live reporter
uses. Two files, both mode 0600 inside a 0700 directory:

- ``push.json``: registered devices, including each device's relay send
  capability. It never contains gateway credentials.
- ``push-tokens.json``: hashes of outstanding single-use response tokens.

Nothing here logs. Errors carry stable codes, never request data.
"""
import base64
import binascii
from contextlib import contextmanager
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import stat
import threading
import time
from urllib.parse import urlsplit

try:
    import fcntl
except ImportError:  # pragma: no cover - the guided installer is POSIX only
    fcntl = None

REGISTRATIONS_FILE = "push.json"
TOKENS_FILE = "push-tokens.json"
LOCK_FILE = "push.lock"
# The live reporter treats every other *.json file as a publisher snapshot.
RESERVED_FILES = frozenset({REGISTRATIONS_FILE, TOKENS_FILE})
MAX_BYTES = 128_000
MAX_DEVICES = 8
MAX_TOKENS = 256
SCHEMA = 1

RELAY_DEVICE_ID = re.compile(r"^[A-Za-z0-9_-]{22}$")
CAPABILITY = re.compile(r"^[A-Za-z0-9_-]{32,128}$")
# The relay requires `relay_key_id` to carry at least 128 bits (22+ base64url
# characters) and to be unique per gateway; `key_id` is that value, so the same
# rule applies here and short ids are rejected before anything is stored.
KEY_ID = re.compile(r"^[A-Za-z0-9._:-]{22,64}$")
LOCAL_ID = re.compile(r"^[0-9a-f]{12}$")
REGISTRATION_FIELDS = frozenset({
    "relay_url", "relay_device_id", "send_capability", "device_public_key", "key_id", "label"})

_thread_lock = threading.RLock()


class StoreError(Exception):
    """A stable, non-revealing failure code (``args[0]``)."""

    @property
    def code(self):
        return self.args[0]


def private_directory(root):
    """Create or verify the owner-only directory, mirroring the live reporter."""
    root = Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise StoreError("unsafe_directory")
    root.chmod(0o700)
    return root


def _read_private(root, name):
    """Read a private regular file, refusing symlinks and foreign owners."""
    path = Path(root) / name
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    except OSError as exc:  # ELOOP for a symlink, EACCES, ...
        raise StoreError("unsafe_file") from exc
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > MAX_BYTES:
            raise StoreError("unsafe_file")
        if info.st_mode & 0o077:
            os.fchmod(stream.fileno(), 0o600)
        return stream.read(MAX_BYTES + 1)


def _write_private(root, name, payload):
    data = json.dumps(payload, allow_nan=False, sort_keys=True).encode()
    if len(data) > MAX_BYTES:
        raise StoreError("too_large")
    path = Path(root) / name
    if path.is_symlink():
        raise StoreError("unsafe_file")
    temp = Path(root) / f".{secrets.token_hex(6)}.tmp"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def decode_b64url(value):
    if (not isinstance(value, str) or not value or len(value) > 8192
            or not re.fullmatch(r"[A-Za-z0-9_-]+={0,2}", value)):
        raise ValueError
    try:
        return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except (binascii.Error, ValueError) as exc:
        raise ValueError from exc


def encode_b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def normalize_relay_url(value):
    """HTTPS only, no credentials, no IP literals: the sender posts a bearer
    capability here, so a hostile or mistyped target must be rejected early."""
    if not isinstance(value, str) or not 8 <= len(value) <= 256 or not value.isascii():
        raise ValueError
    parts = urlsplit(value)
    host = parts.hostname or ""
    if (parts.scheme != "https" or not host or parts.username is not None
            or parts.password is not None or parts.query or parts.fragment or ".." in parts.path):
        raise ValueError
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError  # IP literals are never a legitimate relay.
    lowered = host.lower()
    if (lowered == "localhost" or lowered.endswith((".localhost", ".local", ".internal", ".lan"))
            or "." not in lowered):
        raise ValueError
    try:
        port = parts.port
    except ValueError as exc:
        raise ValueError from exc
    netloc = lowered if port in (None, 443) else f"{lowered}:{port}"
    path = parts.path.rstrip("/")
    if path and not re.fullmatch(r"(?:/[A-Za-z0-9._~-]+)+", path):
        raise ValueError
    return f"https://{netloc}{path}"


def validate_registration(body):
    """Return a clean registration record or raise ``StoreError('invalid_field')``.

    Unknown fields are rejected, and the error never echoes the input.
    """
    try:
        if not isinstance(body, dict) or set(body) - REGISTRATION_FIELDS:
            raise ValueError
        relay_url = normalize_relay_url(body.get("relay_url"))
        relay_device_id = body.get("relay_device_id")
        capability = body.get("send_capability")
        key_id = body.get("key_id")
        label = body.get("label", "")
        if (not isinstance(relay_device_id, str) or not RELAY_DEVICE_ID.fullmatch(relay_device_id)
                or not isinstance(capability, str) or not CAPABILITY.fullmatch(capability)
                or not isinstance(key_id, str) or not KEY_ID.fullmatch(key_id)
                or not isinstance(label, str) or len(label) > 64
                or any(not ch.isprintable() for ch in label)):
            raise ValueError
        public_key = decode_b64url(body.get("device_public_key"))
        if len(public_key) != 32:
            raise ValueError
        _load_public_key(public_key)
    except (ValueError, TypeError) as exc:
        raise StoreError("invalid_field") from exc
    return {"relay_url": relay_url, "relay_device_id": relay_device_id,
            "send_capability": capability, "device_public_key": encode_b64url(public_key),
            "key_id": key_id, "label": label.strip()}


def _load_public_key(raw):
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
    return X25519PublicKey.from_public_bytes(raw)


def public_view(device):
    """The listing view: no capability, no key material, only the relay's host."""
    # The relay treats the key id as a possession check for the registration, so
    # listings show only a fingerprint of it.
    fingerprint = hashlib.sha256(device["key_id"].encode()).hexdigest()[:8]
    return {"id": device["id"], "label": device.get("label", ""), "key_fingerprint": fingerprint,
            "relay_host": urlsplit(device["relay_url"]).netloc,
            "created_at": device.get("created_at", 0)}


@contextmanager
def _locked(root):
    with _thread_lock:
        if fcntl is None:
            yield
            return
        fd = os.open(Path(root) / LOCK_FILE, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)  # closing releases the advisory lock


class PushStore:
    def __init__(self, root, clock=None):
        self.root = private_directory(root)
        self.clock = clock or time.time

    # ---- registrations -------------------------------------------------
    def _load_devices(self):
        raw = _read_private(self.root, REGISTRATIONS_FILE)
        if raw is None:
            return []
        try:
            payload = json.loads(raw)
            devices = payload["devices"] if payload.get("schema") == SCHEMA else []
        except (ValueError, KeyError, TypeError, AttributeError):
            return []
        clean = []
        for item in devices if isinstance(devices, list) else []:
            try:
                record = validate_registration({k: item[k] for k in REGISTRATION_FIELDS})
                if LOCAL_ID.fullmatch(item["id"]):
                    clean.append({**record, "id": item["id"],
                                  "created_at": int(item.get("created_at", 0))})
            except (StoreError, KeyError, TypeError, ValueError):
                continue
        return clean[:MAX_DEVICES]

    def devices(self):
        with _locked(self.root):
            return self._load_devices()

    def add_device(self, record):
        """Idempotent upsert keyed by relay + relay device id. Returns (device, created)."""
        with _locked(self.root):
            devices = self._load_devices()
            for existing in devices:
                same = (existing["relay_url"], existing["relay_device_id"]) == (
                    record["relay_url"], record["relay_device_id"])
                if existing["key_id"] == record["key_id"] and not same:
                    raise StoreError("key_id_in_use")  # one key id per registration
            for index, existing in enumerate(devices):
                if (existing["relay_url"], existing["relay_device_id"]) == (
                        record["relay_url"], record["relay_device_id"]):
                    devices[index] = {**record, "id": existing["id"],
                                      "created_at": existing["created_at"]}
                    self._save_devices(devices)
                    return devices[index], False
            if len(devices) >= MAX_DEVICES:
                raise StoreError("too_many_devices")
            device = {**record, "id": secrets.token_hex(6), "created_at": int(self.clock())}
            devices.append(device)
            self._save_devices(devices)
            return device, True

    def remove_device(self, local_id):
        """Remove a registration. Returns the removed record (so the caller can
        de-register it at the relay) or ``None``."""
        with _locked(self.root):
            devices = self._load_devices()
            kept = [device for device in devices if device["id"] != local_id]
            if len(kept) == len(devices):
                return None
            self._save_devices(kept)
            return next(device for device in devices if device["id"] == local_id)

    def _save_devices(self, devices):
        _write_private(self.root, REGISTRATIONS_FILE, {"schema": SCHEMA, "devices": devices})

    # ---- response tokens ------------------------------------------------
    @staticmethod
    def _hash(token):
        return hashlib.sha256(token.encode()).hexdigest()

    def _load_tokens(self):
        raw = _read_private(self.root, TOKENS_FILE)
        if raw is None:
            return {}
        try:
            payload = json.loads(raw)
            tokens = payload["tokens"] if payload.get("schema") == SCHEMA else {}
        except (ValueError, KeyError, TypeError, AttributeError):
            return {}
        now = self.clock()
        return {key: value for key, value in (tokens.items() if isinstance(tokens, dict) else [])
                if isinstance(value, dict) and isinstance(value.get("exp"), (int, float))
                and value["exp"] > now}

    def _save_tokens(self, tokens):
        _write_private(self.root, TOKENS_FILE, {"schema": SCHEMA, "tokens": tokens})

    def mint_token(self, *, session_key, request_id, command_digest, expires_at):
        """A 256-bit single-use token; only its SHA-256 is stored."""
        token = encode_b64url(secrets.token_bytes(32))
        record = {"exp": int(expires_at), "session_key": session_key,
                  "request_id": request_id, "digest": command_digest}
        with _locked(self.root):
            tokens = self._load_tokens()
            while len(tokens) >= MAX_TOKENS:  # drop the soonest-to-expire entry
                tokens.pop(min(tokens, key=lambda key: tokens[key]["exp"]))
            tokens[self._hash(token)] = record
            self._save_tokens(tokens)
        return token

    def consume_token(self, token, request_id):
        """Validate binding, then burn the token. Returns the stored record.

        A wrong ``request_id`` does not burn the token: only the holder of the
        sealed payload can reach the binding check, and an accidental mismatch
        should not strand a legitimate approval.
        """
        if not isinstance(token, str) or not isinstance(request_id, str) or not request_id:
            raise StoreError("invalid_token")
        digest = self._hash(token)
        with _locked(self.root):
            tokens = self._load_tokens()
            record = tokens.get(digest)
            if record is None:
                raise StoreError("invalid_token")
            bound = record.get("request_id")
            if bound and not secrets.compare_digest(bound.encode(), request_id.encode()):
                raise StoreError("token_mismatch")
            del tokens[digest]
            self._save_tokens(tokens)
            return record

    def revoke_tokens(self, session_key, command_digest):
        with _locked(self.root):
            tokens = self._load_tokens()
            kept = {key: value for key, value in tokens.items()
                    if not (value.get("session_key") == session_key
                            and value.get("digest") == command_digest)}
            if len(kept) != len(tokens):
                self._save_tokens(kept)
