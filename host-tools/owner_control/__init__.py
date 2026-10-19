"""Owner-bound Telegram commands for the local Fleet QR pairing flow.

This package is copied into an installed Hermes profile as a general plugin.  It adds only two
scoped PTB command handlers; it does not enter the agent turn loop or create a model-visible tool.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import threading
from typing import Any, Callable, Mapping, Optional
from urllib.parse import urlsplit


_REQUIRED_READINESS = (
    "issuer_ready",
    "home_matches",
    "runtime_matches",
    "https_origin_verified",
    "system_tls_trusted",
    "phone_reachability_verified",
    "local_display_ready",
    "service_runtime_verified",
)
_KNOWN_HELPER_BLOCKERS = frozenset(_REQUIRED_READINESS) | {
    "actual_private_numeric_owner_event_and_explicit_issue_request",
}
_SAFE_BLOCKERS = {
    "issuer_not_ready": "The installed Fleet issuer is not ready for this Hermes profile.",
    "scope_mismatch": "The verified host or profile does not match this Telegram gateway.",
    "https_unverified": "The pairing HTTPS origin is not verified as reachable and trusted.",
    "owner_approval_missing": "A current private host approval receipt is missing.",
    "local_display_unverified": "Private local QR display is not verified.",
    "service_runtime_unverified": "The running dashboard service has not been verified.",
    "helper_unavailable": "The maintained Fleet host readiness helper is unavailable.",
    "config_missing": "Owner-control host settings are incomplete for this profile.",
    "report_invalid": "The Fleet host readiness report could not be verified.",
}
_PAIRING_LINK = re.compile(r"https://[^\s/#]+(?::\d+)?/pair#v=1&i=([A-Za-z0-9_-]+)&s=([A-Za-z0-9_-]+)\Z")
_INVITATION_ID = re.compile(r"Invitation id \(to cancel\): ([A-Za-z0-9_-]+)\Z")
_SAFE_INVITATION_ID = re.compile(r"[A-Za-z0-9_-]+\Z")
_REPLAY_LOCK = threading.Lock()
_ACTIVE_OWNERS: set[tuple[str, int]] = set()
_RECEIPT_LIMIT = 10_000


@dataclass(frozen=True)
class Dependencies:
    """Side-effect seams used by the native handlers and deterministic tests."""

    readiness_check: Callable[[Path], Mapping[str, Any]]
    issue_invitation: Callable[[Path], tuple[str, str]]
    render_qr: Callable[[str, str, Path, Path], bool]
    cancel_invitation: Callable[[Path, str], bool]
    current_home: Callable[[], Path]
    ordinary_access: Callable[[Any], bool]
    owner_provider: Optional[Callable[[], Any]] = None
    claim_update: Optional[Callable[[Path, Any], bool]] = None


def _resolved(path: Any) -> Optional[Path]:
    if not isinstance(path, (str, Path)) or not str(path).strip():
        return None
    try:
        return Path(path).expanduser().resolve(strict=True)
    except (OSError, RuntimeError, ValueError):
        return None


def _owner_ids(raw: Any) -> Optional[frozenset[str]]:
    """Accept only an explicit non-empty list of exact numeric Telegram account IDs."""
    if not isinstance(raw, (list, tuple)) or not raw:
        return None
    values: set[str] = set()
    for value in raw:
        if isinstance(value, bool) or not isinstance(value, (str, int)):
            return None
        token = str(value).strip()
        if not token.isdecimal() or int(token) <= 0:
            return None
        values.add(token)
    return frozenset(values) if values else None


def _has_forward_markers(message: Any) -> bool:
    """Reject Telegram forwards and via-bot messages across the supported PTB field names."""
    names = (
        "forward_origin", "forward_date", "forward_from", "forward_from_chat",
        "forward_sender_name", "forward_signature", "via_bot", "is_automatic_forward",
    )
    return any(getattr(message, name, None) is not None and getattr(message, name, None) is not False
               for name in names)


def _authorized_private_update(update: Any, owners: frozenset[str]) -> bool:
    """Authorize only a live, non-forwarded command sent by the account owning the private chat."""
    message = getattr(update, "message", None)
    user = getattr(update, "effective_user", None)
    chat = getattr(update, "effective_chat", None)
    if (message is None or user is None or chat is None
            or getattr(update, "internal", False) is True
            or getattr(update, "effective_message", None) is not message
            or _has_forward_markers(message)):
        return False
    user_id = getattr(user, "id", None)
    chat_id = getattr(chat, "id", None)
    message_user = getattr(message, "from_user", None)
    message_chat = getattr(message, "chat", None)
    update_id = getattr(update, "update_id", None)
    if type(user_id) is not int or type(chat_id) is not int or user_id <= 0 or chat_id != user_id:
        return False
    if (type(update_id) is not int or update_id < 0
            or getattr(message_user, "id", None) != user_id
            or getattr(message_chat, "id", None) != chat_id
            or getattr(chat, "type", None) != "private"
            or getattr(message_chat, "type", None) != "private"
            or getattr(user, "is_bot", False) is not False
            or getattr(message_user, "is_bot", False) is not False):
        return False
    return str(user_id) in owners


def _safe_report(report: Any, home: Path) -> tuple[bool, list[str], Optional[Path], str]:
    """Validate the helper's machine report without displaying its diagnostic text."""
    if not isinstance(report, Mapping):
        return False, ["report_invalid"], None, ""
    helper_blockers = report.get("blockers", ())
    if isinstance(helper_blockers, (list, tuple)) and any(
        value in ("helper_unavailable", "config_missing") for value in helper_blockers
    ):
        return False, sorted(set(helper_blockers) & {"helper_unavailable", "config_missing"}), None, ""
    report_home = _resolved(report.get("home"))
    runtime = _resolved(report.get("runtime_dir"))
    origin = report.get("origin")
    release_id = report.get("release_id")
    if (report_home != home or runtime is None or not isinstance(origin, str)
            or not isinstance(release_id, str) or not release_id.strip()):
        return False, ["scope_mismatch"], None, ""
    if (not isinstance(helper_blockers, (list, tuple))
            or any(not isinstance(value, str) or value not in _KNOWN_HELPER_BLOCKERS
                   for value in helper_blockers)):
        return False, ["report_invalid"], None, ""
    if any(report.get(blocker) is not False for blocker in helper_blockers
           if blocker in _REQUIRED_READINESS):
        return False, ["report_invalid"], None, ""
    parsed = urlsplit(origin)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment
            or len(parsed.hostname.split(".")) < 2):
        return False, ["report_invalid"], None, ""
    failed = [name for name in _REQUIRED_READINESS if report.get(name) is not True]
    blockers = set(str(value) for value in report.get("blockers", ()) if isinstance(value, str))
    if "issuer_ready" in failed:
        blockers.add("issuer_not_ready")
    if "home_matches" in failed or "runtime_matches" in failed:
        blockers.add("scope_mismatch")
    if "https_origin_verified" in failed or "system_tls_trusted" in failed or "phone_reachability_verified" in failed:
        blockers.add("https_unverified")
    if "local_display_ready" in failed:
        blockers.add("local_display_unverified")
    if "service_runtime_verified" in failed:
        blockers.add("service_runtime_unverified")
    return not failed, sorted(blockers), runtime, origin


def _reply(update: Any, text: str) -> Any:
    message = getattr(update, "effective_message", None)
    reply = getattr(message, "reply_text", None)
    if not callable(reply):
        return None
    return reply(text)


def _friendly_blockers(blockers: list[str]) -> str:
    messages = [_SAFE_BLOCKERS[name] for name in blockers if name in _SAFE_BLOCKERS]
    if not messages:
        messages = [_SAFE_BLOCKERS["report_invalid"]]
    return "Fleet QR pairing is blocked:\n" + "\n".join(f"• {item}" for item in messages)


def _reserve_owner(update: Any, home: Path) -> bool:
    """Serialize invitation work for one owner while durable update receipts are claimed."""
    user_id = getattr(getattr(update, "effective_user", None), "id", None)
    if type(user_id) is not int or user_id <= 0:
        return False
    owner_key = (str(home), user_id)
    with _REPLAY_LOCK:
        if owner_key in _ACTIVE_OWNERS:
            return False
        _ACTIVE_OWNERS.add(owner_key)
    return True


def _release_request(update: Any, home: Path) -> None:
    user_id = getattr(getattr(update, "effective_user", None), "id", None)
    if type(user_id) is not int:
        return
    with _REPLAY_LOCK:
        _ACTIVE_OWNERS.discard((str(home), user_id))


def _claim_receipt(conn: Any, home: Path, bot_id: int, user_id: int, update_id: int) -> bool:
    """Permanently claim one profile/bot/owner/update tuple; refuse at the bounded store limit."""
    if (type(bot_id) is not int or bot_id <= 0 or type(user_id) is not int or user_id <= 0
            or type(update_id) is not int or update_id < 0):
        return False
    conn.execute(
        "CREATE TABLE IF NOT EXISTS issuance_receipts ("
        "profile_key TEXT NOT NULL, bot_id INTEGER NOT NULL, owner_key TEXT NOT NULL, "
        "update_id INTEGER NOT NULL, claimed_at INTEGER NOT NULL, "
        "PRIMARY KEY(profile_key, bot_id, owner_key, update_id))"
    )
    conn.execute("BEGIN IMMEDIATE")
    profile_key = hashlib.sha256(str(home).encode("utf-8")).hexdigest()
    owner_key = hashlib.sha256(str(user_id).encode("ascii")).hexdigest()
    exists = conn.execute(
        "SELECT 1 FROM issuance_receipts WHERE profile_key=? AND bot_id=? "
        "AND owner_key=? AND update_id=?",
        (profile_key, bot_id, owner_key, update_id),
    ).fetchone()
    if exists:
        conn.rollback()
        return False
    count = conn.execute("SELECT COUNT(*) FROM issuance_receipts").fetchone()[0]
    if count >= _RECEIPT_LIMIT:
        conn.rollback()
        return False
    conn.execute(
        "INSERT INTO issuance_receipts(profile_key,bot_id,owner_key,update_id,claimed_at) "
        "VALUES(?,?,?,?,strftime('%s','now'))",
        (profile_key, bot_id, owner_key, update_id),
    )
    conn.commit()
    return True


def build_handlers(
    *, owner_config: Any, expected_home: Any, dependencies: Dependencies,
) -> tuple[Callable[..., Any], Callable[..., Any]]:
    """Build async callbacks for PTB; dependencies are injected to keep security tests synthetic."""
    configured_owners = _owner_ids(owner_config)
    bound_home = _resolved(expected_home)

    def scope_ok() -> bool:
        try:
            return bound_home is not None and _resolved(dependencies.current_home()) == bound_home
        except Exception:
            return False

    def owners_now() -> Optional[frozenset[str]]:
        # On a scope hop, retain only the immutable profile-bound IDs for a harmless status reply;
        # readiness still fails and no invitation side effect is reachable.
        if bound_home is None:
            return None
        if not scope_ok():
            return configured_owners
        try:
            raw = dependencies.owner_provider() if dependencies.owner_provider is not None else owner_config
        except Exception:
            return None
        return _owner_ids(raw) if dependencies.owner_provider is not None else configured_owners

    def readiness() -> tuple[bool, list[str], Optional[Path], str]:
        if not scope_ok():
            return False, ["scope_mismatch"], None, ""
        try:
            return _safe_report(dependencies.readiness_check(bound_home), bound_home)
        except Exception:
            return False, ["helper_unavailable"], None, ""

    def authorized(update: Any, owners: Optional[frozenset[str]]) -> bool:
        if owners is None or not _authorized_private_update(update, owners):
            return False
        try:
            return dependencies.ordinary_access(update) is True
        except Exception:
            return False

    async def fleetstatus(update: Any, _context: Any) -> None:
        owners = owners_now()
        if not authorized(update, owners):
            await _reply(update, "This command is available only to a configured owner in a private Telegram chat.")
            return
        ready, blockers, _runtime, _origin = await asyncio.to_thread(readiness)
        if ready:
            await _reply(update, "Fleet QR host checks are ready for this profile. Send /fleetqr only when you want to issue an invitation now.")
        else:
            await _reply(update, _friendly_blockers(blockers))

    async def fleetqr(update: Any, _context: Any) -> None:
        owners = owners_now()
        if not authorized(update, owners):
            await _reply(update, "This command is available only to a configured owner in a private Telegram chat.")
            return
        ready, blockers, runtime, origin = await asyncio.to_thread(readiness)
        if not ready or runtime is None:
            await _reply(update, _friendly_blockers(blockers))
            return
        if not _reserve_owner(update, bound_home):
            await _reply(update, "A previous Fleet QR request may still be active, or this Telegram update was replayed. Check the local QR and pending invitations before trying again.")
            return
        # The exact native command is an explicit issuance request. Capture its bearer link in memory
        # only; never pass it through argv, stderr, logs, Telegram, or an exception string.
        invitation_id = ""

        async def cancel_attempt() -> bool:
            try:
                return await asyncio.to_thread(
                    dependencies.cancel_invitation, bound_home, invitation_id)
            except Exception:
                return False

        try:
            claimed = await asyncio.to_thread(dependencies.claim_update, bound_home, update)
            if claimed is not True:
                await _reply(update, "This Telegram request was already handled, or the local replay guard is full or unavailable. No new invitation was issued.")
                return
            invitation_id, link = await asyncio.to_thread(dependencies.issue_invitation, bound_home)
            if not isinstance(invitation_id, str) or not _SAFE_INVITATION_ID.fullmatch(invitation_id):
                await _reply(update, "The invitation could not be verified. No link was sent. The host cannot confirm cancellation; check pending invitations locally before issuing another.")
                return
            match = _PAIRING_LINK.fullmatch(link)
            if not match or match.group(1) != invitation_id:
                cancelled = False
                if invitation_id:
                    cancelled = await cancel_attempt()
                suffix = "The invitation was cancelled." if cancelled else "Cancellation could not be confirmed; check pending invitations locally before issuing another."
                await _reply(update, "The local issuer returned an unverifiable invitation. No link was sent. " + suffix)
                return
            parsed_link, parsed_origin = urlsplit(link), urlsplit(origin)
            if (parsed_link.scheme != "https" or parsed_link.netloc != parsed_origin.netloc
                    or parsed_link.path != "/pair"):
                cancelled = await cancel_attempt()
                suffix = "The invitation was cancelled." if cancelled else "Cancellation could not be confirmed; check pending invitations locally before issuing another."
                await _reply(update, "The invitation origin did not match the verified host. " + suffix)
                return
            await _reply(update, "Your Fleet pairing QR is opening privately on this computer. Scan it with Fleet while it is visible; a status message will arrive when the local display closes.")
            displayed = await asyncio.to_thread(
                dependencies.render_qr, link, invitation_id, bound_home, runtime)
            if displayed is not True:
                cancelled = await cancel_attempt()
                suffix = " The invitation was cancelled." if cancelled else " Cancellation could not be confirmed; check pending invitations locally before issuing another."
                await _reply(update, "Private QR display failed; the invitation link was not sent." + suffix)
                return
        except Exception:
            # Keep secret-bearing inputs and implementation exception text out of Telegram and logs.
            cancelled = False
            if invitation_id:
                cancelled = await cancel_attempt()
            suffix = " The invitation was cancelled." if cancelled else " Cancellation could not be confirmed; check pending invitations locally before issuing another."
            await _reply(update, "The local QR flow did not complete; the invitation link was not sent." + suffix)
            return
        finally:
            _release_request(update, bound_home)
        await _reply(update, "Local QR display finished. Telegram did not receive the invitation link; the invitation expires and works once.")

    return fleetstatus, fleetqr


def _production_dependencies(
    config_provider: Callable[[], Mapping[str, Any]],
    ordinary_access: Callable[[Any], bool],
) -> Dependencies:
    """Bind the reviewed local readiness/display helpers and current-profile pairing store."""
    from hermes_constants import get_hermes_home

    def readiness_check(home: Path) -> Mapping[str, Any]:
        try:
            from .readiness import inspect_readiness, normalise_origin
        except ImportError:
            return {"home": str(home), "runtime_dir": "", "origin": "", "release_id": "",
                    "blockers": ("helper_unavailable",)}
        settings = config_provider()
        if not isinstance(settings, Mapping):
            return {"home": str(home), "runtime_dir": "", "origin": "", "release_id": "",
                    "blockers": ("config_missing",)}
        configured_home = _resolved(settings.get("hermes_home"))
        required = ("source", "runtime_source", "manifest", "trusted_manifest_sha256", "origin", "approval")
        if any(not isinstance(settings.get(key), str) or not settings[key].strip() for key in required):
            return {"home": str(home), "runtime_dir": "", "origin": "", "release_id": "",
                    "blockers": ("config_missing",)}
        if configured_home != _resolved(home):
            return {"home": str(settings.get("hermes_home", "")), "runtime_dir": "",
                    "origin": "", "release_id": "", "blockers": ("scope_mismatch",)}
        normalized_origin = normalise_origin(settings["origin"])
        report = inspect_readiness(
            home, Path(settings["runtime_source"]).expanduser(),
            source=Path(settings["source"]).expanduser(),
            manifest=Path(settings["manifest"]).expanduser(),
            trusted_digest=settings["trusted_manifest_sha256"], origin=normalized_origin,
            approval=Path(settings["approval"]).expanduser(),
        )
        if (not isinstance(report, Mapping)
                or _resolved(report.get("home")) != configured_home
                or _resolved(report.get("runtime_dir")) != _resolved(settings["runtime_source"])
                or report.get("origin") != normalized_origin
                or report.get("release_id") != settings["trusted_manifest_sha256"]):
            return {"home": str(home), "runtime_dir": "", "origin": "", "release_id": "",
                    "blockers": ("scope_mismatch",)}
        return report

    def issue(home: Path) -> tuple[str, str]:
        _assert_active_home(home, get_hermes_home())
        from hermes_cli.fleet_pairing_cli import main
        from io import StringIO

        output = StringIO()
        # The only issuer output containing the bearer link remains in this local buffer.
        result = main(["invite", "--label", "Fleet phone", "--ttl", "600"], out=output)
        captured = output.getvalue()
        invitation_id = ""
        link = ""
        for line in captured.splitlines():
            id_match = _INVITATION_ID.fullmatch(line)
            if id_match:
                invitation_id = id_match.group(1)
            if "/pair#v=1&i=" in line:
                link = line.strip()
        if result != 0 or not invitation_id or not link:
            if invitation_id:
                try:
                    cancel(home, invitation_id)
                except Exception:
                    pass
            raise RuntimeError("local invitation could not be verified")
        return invitation_id, link

    def cancel(home: Path, invitation_id: str) -> bool:
        _assert_active_home(home, get_hermes_home())
        from hermes_cli.fleet_pairing_cli import main
        from io import StringIO

        output = StringIO()
        result = main(["cancel", invitation_id], out=output)
        return result == 0 and output.getvalue().strip() == "cancelled"

    def render(link: str, invitation_id: str, home: Path, runtime: Path) -> bool:
        _assert_active_home(home, get_hermes_home())
        from .qr_display import render_private
        return render_private(link, invitation_id=invitation_id, home=home, runtime_dir=runtime) is True

    def claim_update(home: Path, update: Any) -> bool:
        _assert_active_home(home, get_hermes_home())
        update_id = getattr(update, "update_id", None)
        user_id = getattr(getattr(update, "effective_user", None), "id", None)
        get_bot = getattr(update, "get_bot", None)
        try:
            bot = get_bot() if callable(get_bot) else None
        except Exception:
            return False
        bot_id = getattr(bot, "id", None)
        if (type(update_id) is not int or update_id < 0 or type(user_id) is not int or user_id <= 0
                or type(bot_id) is not int or bot_id <= 0):
            return False
        from plugins.plugin_storage import plugin_data_dir, plugin_db

        data_dir = plugin_data_dir("fleet-owner-control")
        os.chmod(data_dir, 0o700)
        db_path = data_dir / "data.db"
        conn = plugin_db("fleet-owner-control")
        try:
            os.chmod(db_path, 0o600)
            return _claim_receipt(conn, home, bot_id, user_id, update_id)
        except Exception:
            conn.rollback()
            return False
        finally:
            conn.close()

    return Dependencies(readiness_check, issue, render, cancel, get_hermes_home,
                        ordinary_access, claim_update=claim_update)


def _assert_active_home(expected: Path, actual: Any) -> None:
    if _resolved(expected) is None or _resolved(actual) != _resolved(expected):
        raise RuntimeError("active Hermes profile scope changed")


def register(ctx: Any) -> None:
    """Register native Telegram handlers through the supported public PluginContext surface."""
    def factory(native: Any, adapter: Any) -> None:
        if native is None:
            return
        from telegram.ext import CommandHandler

        from hermes_constants import get_hermes_home
        from gateway.config import Platform, load_gateway_config

        active_home = get_hermes_home()
        adapter_config = getattr(adapter, "config", None)
        adapter_extra = getattr(adapter_config, "extra", None)
        initial_config = load_gateway_config()
        initial_platform = initial_config.platforms.get(Platform.TELEGRAM)
        initial_extra = getattr(initial_platform, "extra", None)
        if not isinstance(adapter_extra, Mapping) or not isinstance(initial_extra, Mapping) or dict(adapter_extra) != dict(initial_extra):
            initial_extra = {}
        initial_settings = initial_extra.get("fleet_pairing_host")
        initial_settings = initial_settings if isinstance(initial_settings, Mapping) else {}
        expected_home = _resolved(initial_settings.get("hermes_home"))
        if expected_home is None or _resolved(active_home) != expected_home:
            expected_home = None

        def effective_extra() -> Mapping[str, Any]:
            if expected_home is None or _resolved(get_hermes_home()) != _resolved(expected_home):
                return {}
            config = load_gateway_config()
            platform_config = config.platforms.get(Platform.TELEGRAM)
            extra = getattr(platform_config, "extra", None)
            adapter_config = getattr(adapter, "config", None)
            adapter_extra = getattr(adapter_config, "extra", None)
            if not isinstance(extra, Mapping) or not isinstance(adapter_extra, Mapping):
                return {}
            # Adapter config and the scoped effective loader must describe the same profile.
            if dict(extra) != dict(adapter_extra):
                return {}
            return extra

        auth_method = getattr(adapter, "_is_callback_user_authorized", None)

        def ordinary_access(update: Any) -> bool:
            user, chat = getattr(update, "effective_user", None), getattr(update, "effective_chat", None)
            if not callable(auth_method) or user is None or chat is None:
                return False
            try:
                decision = auth_method(
                    str(user.id), chat_id=str(chat.id), chat_type="dm",
                    user_name=getattr(user, "username", None),
                )
                return decision is True
            except Exception:
                return False

        dependencies = _production_dependencies(
            lambda: effective_extra().get("fleet_pairing_host", {}),
            ordinary_access,
        )
        effective = effective_extra()
        owners = effective.get("fleet_pairing_owner_user_ids")
        dependencies = Dependencies(
            dependencies.readiness_check, dependencies.issue_invitation,
            dependencies.render_qr, dependencies.cancel_invitation,
            dependencies.current_home, dependencies.ordinary_access,
            owner_provider=lambda: effective_extra().get("fleet_pairing_owner_user_ids"),
        )
        status, issue = build_handlers(owner_config=owners, expected_home=expected_home,
                                      dependencies=dependencies)
        native.add_handler(CommandHandler("fleetstatus", status))
        native.add_handler(CommandHandler("fleetqr", issue))

    ctx.register_platform_handler("telegram", factory)


__all__ = ["Dependencies", "build_handlers", "register"]
