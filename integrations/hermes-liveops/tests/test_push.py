"""Offline tests for the push sender: no network, no live relay, no real keys.

Device keys are generated per test run. Secret-shaped strings are assembled at
runtime so no scanner-visible literal is committed.
"""
import base64
import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import socket
import socketserver
import stat
import sys
import tempfile
import threading
import time
from types import ModuleType
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from fastapi import FastAPI
from fastapi.testclient import TestClient

BASE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "fleet_liveops_plugin_push", BASE / "dashboard" / "plugin_api.py")
plugin = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = plugin
spec.loader.exec_module(plugin)
store_lib = plugin.push_module("push_store")
payload_lib = plugin.push_module("push_payload")
sender_lib = plugin.push_module("push_sender")

RELAY = "https://relay.example.invalid"


def new_device_key():
    private = X25519PrivateKey.generate()
    public = private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return private, store_lib.encode_b64url(public)


def registration(public_key, **overrides):
    body = {"relay_url": RELAY, "relay_device_id": secrets.token_urlsafe(16)[:22],
            "send_capability": secrets.token_urlsafe(32), "device_public_key": public_key,
            "key_id": secrets.token_urlsafe(16), "label": "Synthetic phone"}
    body.update(overrides)
    return body


def open_sealed(body, private):
    message = store_lib.decode_b64url(body["ciphertext"])
    return json.loads(payload_lib.hpke_suite().decrypt(message, private, info=payload_lib.INFO))


class FakeCtx:
    profile_name = "synthetic-profile"

    def __init__(self, **settings):
        self.settings, self.hooks, self.unload = settings, {}, []

    def get_config(self, key, default=None):
        return self.settings.get(key, default)

    def register_hook(self, name, callback):
        self.hooks[name] = callback

    def on_unload(self, callback):
        self.unload.append(callback)


class FakeRelay:
    def __init__(self):
        self.calls, self.responses, self.gate = [], [], None

    def post(self, url, body, capability):
        if self.gate is not None:
            self.gate.wait(5)
        self.calls.append({"url": url, "body": body, "capability": capability})
        return self.responses.pop(0) if self.responses else (200, None, None)


class StoreCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "fleet-liveops"
        self.store = store_lib.PushStore(self.root)


class RegistrationStoreTests(StoreCase):
    def test_files_are_private_and_hold_only_registration_fields(self):
        _, public = new_device_key()
        device, created = self.store.add_device(store_lib.validate_registration(registration(public)))
        self.assertTrue(created)
        self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o700)
        path = self.root / "push.json"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        stored = json.loads(path.read_text())["devices"][0]
        self.assertEqual(set(stored), {"id", "created_at", "relay_url", "relay_device_id",
                                       "send_capability", "device_public_key", "key_id", "label"})
        self.assertEqual(stored["id"], device["id"])

    def test_gateway_credentials_cannot_be_registered(self):
        _, public = new_device_key()
        for extra in ("gateway_token", "gateway_url", "token", "cookie"):
            with self.assertRaises(store_lib.StoreError):
                store_lib.validate_registration(registration(public, **{extra: "synthetic"}))

    def test_symlinked_registration_file_is_rejected(self):
        target = self.root.parent / "elsewhere.json"
        target.write_text(json.dumps({"schema": 1, "devices": []}))
        (self.root / "push.json").symlink_to(target)
        with self.assertRaises(store_lib.StoreError):
            self.store.devices()
        _, public = new_device_key()
        with self.assertRaises(store_lib.StoreError):
            self.store.add_device(store_lib.validate_registration(registration(public)))

    def test_symlinked_directory_and_foreign_owner_are_rejected(self):
        link = self.root.parent / "link"
        link.symlink_to(self.root)
        with self.assertRaises(store_lib.StoreError):
            store_lib.PushStore(link)
        _, public = new_device_key()
        self.store.add_device(store_lib.validate_registration(registration(public)))
        with patch.object(store_lib.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(store_lib.StoreError):
                store_lib.PushStore(self.root)
            with self.assertRaises(store_lib.StoreError):
                self.store.devices()

    def test_loose_permissions_are_tightened_on_read(self):
        _, public = new_device_key()
        self.store.add_device(store_lib.validate_registration(registration(public)))
        (self.root / "push.json").chmod(0o666)
        self.assertEqual(len(self.store.devices()), 1)
        self.assertEqual(stat.S_IMODE((self.root / "push.json").stat().st_mode), 0o600)

    def test_upsert_is_idempotent_and_device_count_is_capped(self):
        _, public = new_device_key()
        body = registration(public)
        first, _ = self.store.add_device(store_lib.validate_registration(body))
        again, created = self.store.add_device(store_lib.validate_registration(
            {**body, "label": "Renamed"}))
        self.assertFalse(created)
        self.assertEqual((again["id"], again["label"]), (first["id"], "Renamed"))
        for _ in range(store_lib.MAX_DEVICES - 1):
            self.store.add_device(store_lib.validate_registration(registration(public)))
        with self.assertRaises(store_lib.StoreError) as raised:
            self.store.add_device(store_lib.validate_registration(registration(public)))
        self.assertEqual(raised.exception.code, "too_many_devices")
        self.assertEqual(self.store.remove_device(first["id"])["id"], first["id"])
        self.assertIsNone(self.store.remove_device(first["id"]))

    def test_key_id_must_be_at_least_128_bits_and_unique_per_registration(self):
        _, public = new_device_key()
        with self.assertRaises(store_lib.StoreError):
            store_lib.validate_registration(registration(public, key_id="a" * 21))
        self.assertEqual(store_lib.validate_registration(
            registration(public, key_id="a" * 22))["key_id"], "a" * 22)
        shared = secrets.token_urlsafe(16)
        self.store.add_device(store_lib.validate_registration(registration(public, key_id=shared)))
        with self.assertRaises(store_lib.StoreError) as raised:
            self.store.add_device(store_lib.validate_registration(registration(public, key_id=shared)))
        self.assertEqual(raised.exception.code, "key_id_in_use")
        self.assertEqual(len(self.store.devices()), 1)

    def test_corrupt_file_reads_as_empty(self):
        (self.root / "push.json").write_text("{")
        self.assertEqual(self.store.devices(), [])

    def test_registration_validation(self):
        _, public = new_device_key()
        valid = registration(public)
        self.assertEqual(store_lib.validate_registration(valid)["relay_url"], RELAY)
        bad = [
            {"relay_url": "http://relay.example.invalid"},
            {"relay_url": "https://user:pw@relay.example.invalid"},
            {"relay_url": "https://relay.example.invalid/?q=1"},
            {"relay_url": "https://127.0.0.1"},
            {"relay_url": "https://[::1]"},
            {"relay_url": "https://localhost"},
            {"relay_url": "https://intranet"},
            {"relay_url": "https://relay.example.invalid/../x"},
            {"relay_device_id": "short"},
            {"send_capability": "x" * 8},
            {"key_id": "bad key" + "x" * 20},
            {"key_id": "x" * 21},  # under 128 bits
            {"key_id": "x" * 65},
            {"key_id": ""},
            {"label": "x" * 65},
            {"label": "line\nbreak"},
            {"device_public_key": store_lib.encode_b64url(b"\x01" * 31)},
            {"device_public_key": "not base64 !!"},
            {"device_public_key": store_lib.encode_b64url(b"\0" * 32) + "*"},
        ]
        for override in bad:
            with self.subTest(override=list(override)), self.assertRaises(store_lib.StoreError):
                store_lib.validate_registration({**valid, **override})
        for body in ("text", None, [valid]):
            with self.assertRaises(store_lib.StoreError):
                store_lib.validate_registration(body)
        self.assertEqual(store_lib.normalize_relay_url("https://Relay.Example.invalid:443/v/"),
                         "https://relay.example.invalid/v")


class ResponseTokenTests(StoreCase):
    def test_token_is_single_use_bound_expiring_and_stored_hashed(self):
        now = [1000]
        store = store_lib.PushStore(self.root, clock=lambda: now[0])
        token = store.mint_token(session_key="s", request_id="r1", command_digest="d", expires_at=1100)
        self.assertNotIn(token, (self.root / "push-tokens.json").read_text())
        self.assertEqual(stat.S_IMODE((self.root / "push-tokens.json").stat().st_mode), 0o600)
        with self.assertRaises(store_lib.StoreError) as raised:
            store.consume_token(token, "other-request")
        self.assertEqual(raised.exception.code, "token_mismatch")
        record = store.consume_token(token, "r1")  # a mismatch does not burn the token
        self.assertEqual((record["session_key"], record["digest"]), ("s", "d"))
        with self.assertRaises(store_lib.StoreError) as raised:
            store.consume_token(token, "r1")
        self.assertEqual(raised.exception.code, "invalid_token")
        expiring = store.mint_token(session_key="s", request_id="r1", command_digest="d", expires_at=1100)
        now[0] = 1101
        with self.assertRaises(store_lib.StoreError):
            store.consume_token(expiring, "r1")

    def test_unbound_token_accepts_any_request_id_and_revocation_works(self):
        token = self.store.mint_token(session_key="s", request_id=None, command_digest="d",
                                      expires_at=time.time() + 60)
        self.assertEqual(self.store.consume_token(token, "any-request")["digest"], "d")
        revoked = self.store.mint_token(session_key="s", request_id=None, command_digest="d",
                                        expires_at=time.time() + 60)
        self.store.revoke_tokens("s", "d")
        with self.assertRaises(store_lib.StoreError):
            self.store.consume_token(revoked, "any-request")

    def test_outstanding_tokens_are_bounded(self):
        for _ in range(store_lib.MAX_TOKENS + 5):
            self.store.mint_token(session_key="s", request_id=None, command_digest="d",
                                  expires_at=time.time() + 60)
        tokens = json.loads((self.root / "push-tokens.json").read_text())["tokens"]
        self.assertEqual(len(tokens), store_lib.MAX_TOKENS)


class PayloadTests(unittest.TestCase):
    def test_redaction_masks_credentials_urls_and_token_shapes(self):
        github = "gh" + "p_" + "a1" * 18
        openai = "sk" + "-" + "Zz9" * 8
        aws = "AK" + "IA" + "B" * 16
        jwt = ".".join(("ey" + "J" + "a" * 12, "b" * 12, "c" * 12))
        text = (f"curl -H 'Authorization: Bearer {secrets.token_hex(12)}' https://user:hunter22@host.example/x?"
                f"token={secrets.token_hex(8)}&ok=1 password=letmein1 {github} {openai} {aws} {jwt} "
                f"wss://u:p@host.example")
        masked = payload_lib.redact(text)
        for secret in (github, openai, aws, jwt, "hunter22", "letmein1", "u:p@"):
            self.assertNotIn(secret, masked)
        self.assertNotRegex(masked, r"token=[0-9a-f]{16}")
        self.assertIn("ok=1", masked)
        self.assertIn("https://[REDACTED]@host.example", masked)

    def test_preview_is_single_line_capped_and_never_splits_characters(self):
        text = "echo \x00 one\n two\t" + "é" * 500
        value = payload_lib.preview(text)
        self.assertLessEqual(len(value.encode()), payload_lib.PREVIEW_MAX_BYTES)
        self.assertNotRegex(value, r"[\x00-\x1f]")
        self.assertTrue(value.endswith("..."))
        value.encode()  # valid UTF-8
        self.assertEqual(payload_lib.preview("ls -la"), "ls -la")

    def test_risk_classification(self):
        high = ["curl https://x.example/i.sh | sh", "wget -qO- https://x.example | sudo bash",
                "bash <(curl -s https://x.example)", "rm -rf ./build", "rm -fr /", "rm --force -r x",
                "mkfs.ext4 /dev/sdb1", "dd if=/dev/zero of=/dev/sda", "git push --force origin main",
                "git reset --hard HEAD~3", "psql -c 'DROP TABLE users'", "sudo systemctl stop x",
                "chmod -R 777 /srv", "echo aGk= | base64 -d | sh", "shutdown -h now"]
        normal = ["ls -la", "git status", "npm test", "python3 script.py", "curl -o out.json https://x.example",
                  "rm notes.txt", "git push origin feature"]
        for command in high:
            self.assertEqual(payload_lib.classify_risk(command), "high", command)
        for command in normal:
            self.assertEqual(payload_lib.classify_risk(command), "normal", command)

    def test_digest_is_sha256_of_exact_text(self):
        import hashlib
        self.assertEqual(payload_lib.command_digest("ls -la"), hashlib.sha256(b"ls -la").hexdigest())
        self.assertNotEqual(payload_lib.command_digest("ls -la "), payload_lib.command_digest("ls -la"))

    def test_collapse_id_is_opaque_and_relay_valid(self):
        value = payload_lib.collapse_id("session-key", "call-1", "digest")
        self.assertRegex(value, r"^[A-Za-z0-9._:-]{1,64}$")
        self.assertNotIn("session", value)
        self.assertEqual(value, payload_lib.collapse_id("session-key", "call-1", "digest"))
        self.assertNotEqual(value, payload_lib.collapse_id("session-key", "call-2", "digest"))

    def test_oversized_payload_drops_preview_instead_of_exceeding_budget(self):
        payload = payload_lib.build_payload(
            "approval", now=100, ttl=60, gateway_label="h", bot="b", session_id="s", ref="r",
            preview_text="x" * 3000)
        data = json.loads(payload_lib.serialize(payload))
        self.assertNotIn("redacted_preview", data)


class SenderCase(StoreCase):
    def setUp(self):
        super().setUp()
        self.now = float(int(time.time()))
        self.relay = FakeRelay()
        self.private, public = new_device_key()
        self.device, _ = self.store.add_device(store_lib.validate_registration(registration(public)))
        self.request_ids = {}
        self.sender = self.make_sender()

    def make_sender(self, **settings):
        sender = sender_lib.PushSender(
            lambda: self.store, sender_lib.Settings(enabled=True, **settings), bot="synthetic-bot",
            transport=self.relay, clock=lambda: self.now, rng=lambda: 0.5,
            lookup=lambda session_key, command: self.request_ids.get(command), start_thread=False)
        self.addCleanup(sender.stop)
        return sender

    def approval(self, command="ls -la", **kwargs):
        args = {"command": command, "description": "synthetic", "pattern_key": "p",
                "pattern_keys": ["p"], "session_key": "gateway-session-key", "surface": "gateway",
                "session_id": "stored-session", "turn_id": "turn-1", "tool_call_id": "call-1"}
        args.update(kwargs)
        return args

    def sent(self):
        return [call["body"] for call in self.relay.calls]


class HookBehaviorTests(SenderCase):
    def test_hooks_register_only_when_enabled_and_hpke_is_available(self):
        for settings in ({}, {"push.enabled": False}, {"push.enabled": "true"}):
            ctx = FakeCtx(**settings)
            self.assertIsNone(sender_lib.register(ctx, store_factory=lambda: self.store, start_thread=False))
            self.assertEqual(ctx.hooks, {})
        ctx = FakeCtx(**{"push.enabled": True})
        with patch.object(payload_lib, "hpke_available", return_value=False):
            self.assertIsNone(sender_lib.register(ctx, store_factory=lambda: self.store, start_thread=False))
        self.assertEqual(ctx.hooks, {})
        ctx = FakeCtx(**{"push.enabled": True})
        sender = sender_lib.register(ctx, store_factory=lambda: self.store, start_thread=False)
        self.assertEqual(set(ctx.hooks), {"pre_approval_request", "post_approval_response",
                                          "pre_tool_call", "on_session_end", "subagent_start"})
        self.assertEqual(ctx.unload, [sender.stop])
        again = FakeCtx()
        sender_lib.register(again, store_factory=lambda: self.store, start_thread=False)
        self.assertTrue(sender._stopped)  # a reload retires the previous sender

    def test_plugin_register_never_raises_even_if_push_cannot_start(self):
        package = sys.modules[plugin.PACKAGE]
        package.register(FakeCtx(**{"push.enabled": True}))  # no Hermes runtime here
        broken = FakeCtx()
        broken.get_config = lambda *args: (_ for _ in ()).throw(RuntimeError("boom"))
        package.register(broken)

    def test_hooks_return_none_and_swallow_every_failure(self):
        with patch.object(self.sender, "_enqueue", side_effect=RuntimeError("boom")):
            for hook, kwargs in ((self.sender.on_pre_approval_request, self.approval()),
                                 (self.sender.on_post_approval_response, {**self.approval(), "choice": "x"}),
                                 (self.sender.on_pre_tool_call, {"tool_name": "clarify", "args": {}}),
                                 (self.sender.on_session_end, {"completed": True})):
                self.assertIsNone(hook(**kwargs))
        # Malformed payloads are tolerated too.
        self.assertIsNone(self.sender.on_pre_tool_call(tool_name="clarify", args="not a dict"))
        self.assertIsNone(self.sender.on_pre_approval_request(command=None, session_key=None))
        self.assertIsNone(self.sender.on_session_end())
        self.assertIsNone(self.sender.on_pre_tool_call())

    def test_hooks_do_no_io_and_return_before_anything_is_sent(self):
        self.sender.on_pre_approval_request(**self.approval())
        self.assertEqual(self.relay.calls, [])
        self.assertEqual(self.sender.pending(), 1)

    def test_slow_relay_never_blocks_the_hook_thread_and_worker_survives_failures(self):
        relay, gate = FakeRelay(), threading.Event()
        relay.gate = gate
        calls = {"n": 0}

        def flaky_lookup(session_key, command):
            calls["n"] += 1
            if calls["n"] == 1:
                raise RuntimeError("lookup failed")
            return None

        sender = sender_lib.PushSender(lambda: self.store, sender_lib.Settings(enabled=True),
                                       transport=relay, lookup=flaky_lookup)
        self.addCleanup(sender.stop)
        self.addCleanup(gate.set)
        started = time.monotonic()
        sender.on_pre_approval_request(**self.approval("first"))   # worker will fail on this one
        sender.on_pre_approval_request(**self.approval("second"))
        self.assertLess(time.monotonic() - started, 1.0)
        gate.set()
        deadline = time.monotonic() + 5
        while not relay.calls and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(len(relay.calls), 1)

    def test_queue_is_bounded_and_drops_the_oldest(self):
        for index in range(sender_lib.QUEUE_MAX + 5):
            self.sender.on_session_end(completed=True, session_id=f"s{index}", turn_id="t")
        self.assertEqual(self.sender.pending(), sender_lib.QUEUE_MAX)
        self.assertEqual(self.sender.dropped, 5)
        ids = [job["session_id"] for job in self.sender._jobs]
        self.assertNotIn("s0", ids)
        self.assertIn(f"s{sender_lib.QUEUE_MAX + 4}", ids)

    def test_no_registered_device_means_no_send_and_no_token(self):
        self.store.remove_device(self.device["id"])
        self.sender.on_pre_approval_request(**self.approval())
        self.sender.drain()
        self.assertEqual(self.relay.calls, [])
        self.assertFalse((self.root / "push-tokens.json").exists())


class EventTests(SenderCase):
    def test_approval_produces_one_generic_alert_with_sealed_details(self):
        self.request_ids["ls -la"] = "request-abc"
        self.sender.on_pre_approval_request(**self.approval())
        self.sender.drain()
        self.assertEqual(len(self.relay.calls), 1)
        call = self.relay.calls[0]
        self.assertEqual(call["url"], RELAY + "/v1/send")
        self.assertEqual(call["capability"], self.device["send_capability"])
        body = call["body"]
        self.assertEqual((body["push_type"], body["priority"]), ("alert", 10))
        self.assertEqual(body["alert"], {"title_key": "approval"})
        self.assertEqual(body["relay_device_id"], self.device["relay_device_id"])
        self.assertGreater(body["expiry"], self.now)
        self.assertLessEqual(body["expiry"], self.now + 86400)
        payload = open_sealed(body, self.private)
        self.assertEqual(payload["v"], 1)
        self.assertEqual(payload["kind"], "approval")
        self.assertEqual(payload["gateway_label"] != "", True)
        self.assertEqual((payload["bot"], payload["session_id"]), ("synthetic-bot", "stored-session"))
        self.assertEqual(payload["redacted_preview"], "ls -la")
        self.assertEqual(payload["command_digest"], payload_lib.command_digest("ls -la"))
        self.assertEqual(payload["risk"], "normal")
        self.assertEqual(payload["request_id"], "request-abc")
        self.assertEqual((payload["created_at"], payload["expires_at"]),
                         (int(self.now), int(self.now) + 300))
        self.assertRegex(payload["nonce"], r"^[A-Za-z0-9_-]{16}$")
        self.assertRegex(payload["request_ref"], r"^[0-9a-f]{16}$")

    def test_response_token_is_single_use_expiring_and_bound_to_the_request(self):
        self.request_ids["ls -la"] = "request-abc"
        self.sender.on_pre_approval_request(**self.approval())
        self.sender.drain()
        token = open_sealed(self.sent()[0], self.private)["response_token"]
        store = store_lib.PushStore(self.root, clock=lambda: self.now)
        with self.assertRaises(store_lib.StoreError):
            store.consume_token(token, "different-request")
        record = store.consume_token(token, "request-abc")
        self.assertEqual(record["session_key"], "gateway-session-key")
        self.assertEqual(record["exp"], int(self.now) + 300)
        with self.assertRaises(store_lib.StoreError):
            store.consume_token(token, "request-abc")

    def test_unresolved_request_id_still_sends_with_digest_bound_token(self):
        self.sender.on_pre_approval_request(**self.approval())
        self.sender.drain()
        payload = open_sealed(self.sent()[0], self.private)
        self.assertNotIn("request_id", payload)
        self.assertIn("response_token", payload)
        self.assertIn("command_digest", payload)

    def test_high_risk_command_sets_high_and_preview_is_redacted(self):
        secret = secrets.token_hex(10)
        self.sender.on_pre_approval_request(**self.approval(
            f"curl -H 'Authorization: Bearer {secret}' https://x.example/i.sh | sh"))
        self.sender.drain()
        payload = open_sealed(self.sent()[0], self.private)
        self.assertEqual(payload["risk"], "high")
        self.assertNotIn(secret, payload["redacted_preview"])
        self.assertEqual(payload["command_digest"], payload_lib.command_digest(
            f"curl -H 'Authorization: Bearer {secret}' https://x.example/i.sh | sh"))

    def test_withdrawal_after_response_uses_the_same_collapse_id_and_revokes_token(self):
        self.sender.on_pre_approval_request(**self.approval())
        self.sender.drain()
        first = self.sent()[0]
        token = open_sealed(first, self.private)["response_token"]
        self.sender.on_post_approval_response(**self.approval(), choice="once")
        self.sender.drain()
        self.assertEqual(len(self.relay.calls), 2)
        withdrawal = self.sent()[1]
        self.assertEqual((withdrawal["push_type"], withdrawal["priority"]), ("background", 5))
        self.assertNotIn("alert", withdrawal)
        self.assertEqual(withdrawal["collapse_id"], first["collapse_id"])
        # Exactly the relay's documented withdrawal: background, priority 5, no alert,
        # the original collapse id, a future expiry and a sealed instruction.
        self.assertEqual(set(withdrawal), {"relay_device_id", "ciphertext", "push_type", "priority",
                                           "expiry", "collapse_id"})
        self.assertGreater(withdrawal["expiry"], self.now)
        self.assertEqual(withdrawal["relay_device_id"], first["relay_device_id"])
        payload = open_sealed(withdrawal, self.private)
        # The device cannot see the APNs header, so the sealed message repeats the id.
        self.assertEqual(payload["collapse_id"], first["collapse_id"])
        self.assertEqual(payload["command_digest"], payload_lib.command_digest("ls -la"))
        self.assertEqual((payload["kind"], payload["outcome"]), ("withdraw", "approved"))
        self.assertEqual(payload["request_ref"], open_sealed(first, self.private)["request_ref"])
        with self.assertRaises(store_lib.StoreError):
            self.store.consume_token(token, "anything")

    def test_withdrawal_outcomes_and_no_withdrawal_for_unsent_or_coalesced_requests(self):
        for choice, outcome in (("deny", "denied"), ("timeout", "timeout"), ("cancelled", "cancelled"),
                                ("notify_failed", "cancelled"), ("session", "approved")):
            with self.subTest(choice=choice):
                self.relay.calls.clear()
                call_id = f"call-{choice}"
                self.sender.on_pre_approval_request(**self.approval(tool_call_id=call_id))
                self.sender.on_post_approval_response(**self.approval(tool_call_id=call_id), choice=choice)
                self.sender.drain()
                self.assertEqual(open_sealed(self.sent()[1], self.private)["outcome"], outcome)
        self.relay.calls.clear()
        self.sender.on_post_approval_response(**self.approval(command="never pushed"), choice="once")
        self.sender.on_pre_approval_request(**self.approval(), coalesced=True)
        self.sender.drain()
        self.assertEqual(self.relay.calls, [])

    def test_clarify_is_sent_only_for_the_clarify_tool(self):
        for name in ("terminal", "Clarify", "", None):
            self.assertIsNone(self.sender.on_pre_tool_call(
                tool_name=name, args={"question": "q?"}, session_id="stored-session"))
        self.sender.drain()
        self.assertEqual(self.relay.calls, [])
        self.assertIsNone(self.sender.on_pre_tool_call(
            tool_name="clarify", args={"question": "Which environment?", "choices": ["a", "b"]},
            session_id="stored-session", tool_call_id="c1"))
        self.sender.on_pre_tool_call(tool_name="clarify", session_id="stored-session",
                                     args={"questions": [{"question": "Batch first?"}]})
        self.sender.drain()
        self.assertEqual([body["alert"]["title_key"] for body in self.sent()], ["clarify", "clarify"])
        first, second = (open_sealed(body, self.private) for body in self.sent())
        self.assertEqual((first["kind"], first["redacted_preview"]), ("clarify", "Which environment?"))
        self.assertEqual(second["redacted_preview"], "Batch first?")
        self.assertNotIn("response_token", first)
        self.assertNotIn("command_digest", first)

    def test_cron_is_detected_by_platform_and_done_is_everything_else(self):
        self.sender.on_session_end(completed=True, platform="cron", session_id="cron-1", turn_id="t1")
        self.sender.on_session_end(completed=True, platform="telegram", session_id="chat-1", turn_id="t2")
        self.sender.on_session_end(failed=True, platform="", session_id="chat-2", turn_id="t3")
        self.sender.drain()
        self.assertEqual([body["alert"]["title_key"] for body in self.sent()], ["cron", "done", "done"])
        self.assertEqual([body["priority"] for body in self.sent()], [5, 5, 5])
        payloads = [open_sealed(body, self.private) for body in self.sent()]
        self.assertEqual([p["kind"] for p in payloads], ["cron", "done", "done"])
        self.assertEqual([p["outcome"] for p in payloads], ["completed", "completed", "failed"])
        self.assertTrue(all("redacted_preview" not in p for p in payloads))

    def test_interrupted_incomplete_and_duplicate_turns_are_not_sent(self):
        self.sender.on_session_end(interrupted=True, completed=False, session_id="a", turn_id="t")
        self.sender.on_session_end(completed=False, failed=False, session_id="b", turn_id="t")
        self.sender.on_session_end(completed=True, session_id="c", turn_id="t")
        self.sender.on_session_end(completed=True, session_id="c", turn_id="t")
        self.sender.drain()
        self.assertEqual(len(self.relay.calls), 1)

    def test_per_kind_toggles_disable_events(self):
        sender = self.make_sender(kinds={"approval": False, "clarify": False, "done": False, "cron": False})
        sender.on_pre_approval_request(**self.approval())
        sender.on_pre_tool_call(tool_name="clarify", args={"question": "q"}, session_id="s")
        sender.on_session_end(completed=True, session_id="s", turn_id="t")
        sender.on_session_end(completed=True, platform="cron", session_id="s", turn_id="u")
        sender.drain()
        self.assertEqual(self.relay.calls, [])
        only_cron = self.make_sender(kinds={"approval": False, "clarify": False, "done": False})
        only_cron.on_session_end(completed=True, session_id="s", turn_id="t")
        only_cron.on_session_end(completed=True, platform="cron", session_id="s", turn_id="u")
        only_cron.drain()
        self.assertEqual([body["alert"]["title_key"] for body in self.sent()], ["cron"])

    def test_generic_only_mode_omits_previews_but_keeps_the_digest(self):
        sender = self.make_sender(generic_only=True)
        sender.on_pre_approval_request(**self.approval("echo sensitive-looking text"))
        sender.on_pre_tool_call(tool_name="clarify", args={"question": "Sensitive question?"}, session_id="s")
        sender.drain()
        approval, clarify = (open_sealed(body, self.private) for body in self.sent())
        self.assertNotIn("redacted_preview", approval)
        self.assertNotIn("redacted_preview", clarify)
        self.assertIn("command_digest", approval)

    def test_a_device_with_an_unusable_key_is_skipped_without_affecting_others(self):
        self.store.add_device(store_lib.validate_registration(
            registration(store_lib.encode_b64url(b"\0" * 32))))  # low-order point: cannot be sealed to
        self.sender.on_pre_approval_request(**self.approval())
        self.sender.drain()
        self.assertEqual(len(self.relay.calls), 1)
        self.assertEqual(open_sealed(self.sent()[0], self.private)["kind"], "approval")

    def test_each_device_gets_a_message_only_it_can_open(self):
        other_private, other_public = new_device_key()
        self.store.add_device(store_lib.validate_registration(registration(other_public)))
        self.sender.on_pre_approval_request(**self.approval())
        self.sender.drain()
        first, second = self.sent()
        self.assertNotEqual(first["ciphertext"], second["ciphertext"])
        self.assertEqual(open_sealed(second, other_private)["kind"], "approval")
        with self.assertRaises(Exception):
            open_sealed(first, other_private)

    def test_relay_request_carries_only_ciphertext_and_generic_fields(self):
        self.sender = self.make_sender(gateway_label="Synthetic Gateway Label")
        command = "deploy-super-secret-project --title 'Quarterly session title'"
        self.request_ids[command] = "request-xyz"
        self.sender.on_pre_approval_request(**self.approval(command))
        self.sender.on_pre_tool_call(tool_name="clarify", session_id="stored-session",
                                     args={"question": "What is the private project name?"})
        self.sender.on_session_end(completed=True, session_id="stored-session", turn_id="t")
        self.sender.on_post_approval_response(**self.approval(command), choice="deny")
        self.sender.drain()
        allowed = {"relay_device_id", "ciphertext", "push_type", "priority", "expiry",
                   "collapse_id", "alert"}
        self.assertEqual(len(self.relay.calls), 4)
        payload = open_sealed(self.sent()[0], self.private)
        for call in self.relay.calls:
            body = call["body"]
            self.assertLessEqual(set(body), allowed)
            self.assertRegex(body["ciphertext"], r"^[A-Za-z0-9_-]+$")
            self.assertLessEqual(len(body["ciphertext"]), 3000)
            for private_text in (command, "Quarterly", "private project", "stored-session",
                                 "request-xyz", payload["response_token"], "synthetic-bot",
                                 payload["gateway_label"], self.device["device_public_key"]):
                self.assertNotIn(private_text, json.dumps(body))
            # The capability travels as the bearer credential only, never in the body.
            self.assertNotIn(self.device["send_capability"], json.dumps(body))

    def test_no_secret_material_reaches_the_log(self):
        secret = "sec" + secrets.token_hex(8)
        command = f"echo {secret}"
        self.relay.responses = [(503, None, None), (401, None, None)]
        with self.assertLogs("fleet_liveops.push", level="DEBUG") as logs:
            sender_lib.LOG.warning("sentinel")  # assertLogs needs at least one record
            self.sender.on_pre_approval_request(**self.approval(command))
            self.sender.drain()
            self.now += 100
            self.sender.drain()
        text = "\n".join(logs.output)
        for private_text in (secret, self.device["send_capability"], self.device["device_public_key"],
                             self.device["relay_device_id"], "stored-session", "gateway-session-key"):
            self.assertNotIn(private_text, text)


class ApprovalSurfaceTests(SenderCase):
    """Alert only when a person is asked. Values verified against hermes-agent 30de041b01."""

    def pre(self, surface, **extra):
        kwargs = self.approval(surface=surface, **extra)
        if surface is None:
            del kwargs["surface"]
        self.sender.on_pre_approval_request(**kwargs)
        self.sender.drain()

    def test_surfaces_where_a_person_decides_are_alerted(self):
        for surface in ("gateway", "cli", "mcp-elicitation", "transport:chat", "transport:a-b_c"):
            with self.subTest(surface=surface):
                self.relay.calls.clear()
                self.pre(surface, tool_call_id="call-" + surface)
                self.assertEqual([body["alert"]["title_key"] for body in self.sent()], ["approval"])

    def test_the_smart_guardian_and_unknown_surfaces_are_never_alerted(self):
        for surface in ("smart", "SMART", "", "unknown", "transport", "Gateway", "auto", None, 7):
            with self.subTest(surface=surface):
                self.pre(surface)
        self.assertEqual(self.relay.calls, [])
        self.assertFalse((self.root / "push-tokens.json").exists())

    def test_a_decision_made_by_a_model_is_never_alerted_even_on_a_human_surface(self):
        self.pre("gateway", decided_by="aux_llm")
        self.assertEqual(self.relay.calls, [])

    def test_smart_approve_and_deny_fire_no_alert_and_no_withdrawal(self):
        for verdict in ("smart_approve", "smart_deny"):
            self.pre("smart")
            self.sender.on_post_approval_response(
                **self.approval(surface="smart"), choice=verdict, decided_by="aux_llm")
            self.sender.drain()
        self.assertEqual(self.relay.calls, [])

    def test_smart_escalation_alerts_once_when_it_reaches_a_person(self):
        self.pre("smart")                     # guardian step: no human
        self.pre("gateway")                   # ESCALATE: the prompt a person sees
        self.assertEqual(len(self.relay.calls), 1)
        self.sender.on_post_approval_response(**self.approval(surface="gateway"), choice="once")
        self.sender.drain()
        self.assertEqual(self.sent()[1]["push_type"], "background")

    def test_a_transport_supplied_request_id_is_used(self):
        self.pre("transport:chat", request_id="transport-request-1")
        payload = open_sealed(self.sent()[0], self.private)
        self.assertEqual(payload["request_id"], "transport-request-1")
        record = self.store.consume_token(payload["response_token"], "transport-request-1")
        self.assertEqual(record["request_id"], "transport-request-1")

    def test_post_hook_on_an_unalerted_surface_is_ignored(self):
        self.pre("gateway")
        self.sender.on_post_approval_response(**self.approval(surface="smart"), choice="once")
        self.sender.drain()
        self.assertEqual(len(self.relay.calls), 1)  # no withdrawal from a foreign surface


class DelegatedChildTests(SenderCase):
    def test_child_turn_end_and_cron_alerts_are_suppressed_but_the_parent_is_not(self):
        self.assertIsNone(self.sender.on_subagent_start(
            parent_session_id="parent", child_session_id="child-1", child_role="leaf"))
        self.sender.on_session_end(completed=True, session_id="child-1", turn_id="c1", platform="telegram")
        self.sender.on_session_end(completed=True, session_id="child-1", turn_id="c2", platform="cron")
        self.sender.on_session_end(failed=True, session_id="child-1", turn_id="c3")
        self.sender.on_session_end(completed=True, session_id="parent", turn_id="p1", platform="telegram")
        self.sender.drain()
        self.assertEqual([open_sealed(body, self.private)["session_id"] for body in self.sent()], ["parent"])

    def test_suppression_survives_subagent_stop_ordering_and_ignores_bad_ids(self):
        for bad in (None, "", 5, ["x"]):
            self.assertIsNone(self.sender.on_subagent_start(child_session_id=bad))
        self.assertEqual(self.sender._children, {})
        self.sender.on_subagent_start(child_session_id="child-2")
        self.sender.on_session_end(completed=True, session_id="child-2", turn_id="t")  # stop never seen
        self.sender.on_session_end(completed=True, session_id="other", turn_id="t")
        self.sender.drain()
        self.assertEqual(len(self.relay.calls), 1)

    def test_child_tracking_is_bounded(self):
        for index in range(sender_lib.CHILDREN_MAX + 10):
            self.sender.on_subagent_start(child_session_id=f"c{index}")
        self.assertEqual(len(self.sender._children), sender_lib.CHILDREN_MAX)
        self.assertNotIn("c0", self.sender._children)
        self.assertIn(f"c{sender_lib.CHILDREN_MAX + 9}", self.sender._children)

    def test_child_approvals_are_still_alerted_because_a_person_must_decide(self):
        self.sender.on_subagent_start(child_session_id="child-3")
        self.sender.on_pre_approval_request(**self.approval(session_id="child-3"))
        self.sender.drain()
        self.assertEqual(len(self.relay.calls), 1)


class DeliveryTests(SenderCase):
    def send_one(self):
        self.sender.on_session_end(completed=True, session_id="s", turn_id="t")
        self.sender.drain()

    def test_transient_failures_retry_with_jittered_capped_backoff(self):
        self.relay.responses = [(503, None, None), (429, 7.0, "rate_limited"), (0, None, None)]
        self.send_one()
        self.assertEqual(len(self.relay.calls), 1)
        job = self.sender._jobs[0]
        self.assertAlmostEqual(job["not_before"] - self.now, 1.0)  # base * 2**0 * (0.5 + 0.5)
        self.sender.drain()
        self.assertEqual(len(self.relay.calls), 1)  # not ready yet
        self.now += 2
        self.sender.drain()
        self.assertAlmostEqual(self.sender._jobs[0]["not_before"] - self.now, 7.0)  # Retry-After wins
        self.now += 8
        self.sender.drain()
        self.assertAlmostEqual(self.sender._jobs[0]["not_before"] - self.now, 4.0)
        self.now += 5
        self.sender.drain()  # the fourth answer is the default 200
        self.assertEqual((len(self.relay.calls), self.sender.pending()), (4, 0))

    def test_retries_are_capped(self):
        self.relay.responses = [(503, None, None)] * 20
        self.send_one()
        for _ in range(20):
            self.now += 100
            self.sender.drain()
        self.assertEqual(len(self.relay.calls), sender_lib.MAX_ATTEMPTS)
        self.assertEqual(self.sender.pending(), 0)

    def test_unknown_device_is_retried_but_other_404_is_not(self):
        self.relay.responses = [(404, None, "unknown_device")]
        self.send_one()
        self.assertEqual(self.sender.pending(), 1)
        self.now += 10
        self.sender.drain()
        self.assertEqual((len(self.relay.calls), self.sender.pending()), (2, 0))
        self.relay.calls.clear()
        self.relay.responses = [(404, None, "other")]
        self.sender.on_session_end(completed=True, session_id="s2", turn_id="t")
        self.sender.drain()
        self.assertEqual(self.sender.pending(), 0)

    def test_permanent_rejections_are_not_retried(self):
        for status in (400, 401, 413, 415, 422):
            self.relay.calls.clear()
            self.relay.responses = [(status, None, "invalid_field")]
            self.sender.on_session_end(completed=True, session_id=f"s{status}", turn_id="t")
            self.sender.drain()
            self.assertEqual((len(self.relay.calls), self.sender.pending()), (1, 0), status)
        self.assertEqual(len(self.store.devices()), 1)

    def test_unregistered_device_is_removed_and_no_longer_pushed_to(self):
        self.relay.responses = [(410, None, "unregistered")]
        self.send_one()
        self.assertEqual(self.store.devices(), [])
        self.relay.calls.clear()
        self.sender.on_session_end(completed=True, session_id="again", turn_id="t")
        self.sender.drain()
        self.assertEqual(self.relay.calls, [])

    def test_expired_messages_are_dropped_instead_of_sent(self):
        self.relay.responses = [(503, None, None)]
        self.send_one()
        self.now += 7 * 3600  # past the 6 hour done/cron lifetime
        self.sender.drain()
        self.assertEqual((len(self.relay.calls), self.sender.pending()), (1, 0))

    def test_expiry_is_always_within_the_relay_window(self):
        sender = self.make_sender(ttl={"approval": 10 ** 9})
        self.assertEqual(sender.settings.ttl["approval"], 24 * 3600)
        sender.on_pre_approval_request(**self.approval())
        sender.on_session_end(completed=True, session_id="s", turn_id="t")
        sender.drain()
        for body in self.sent():
            self.assertGreater(body["expiry"], self.now)
            self.assertLessEqual(body["expiry"], self.now + 24 * 3600)


class SettingsTests(unittest.TestCase):
    def test_defaults_are_off_and_generic_values_are_clamped(self):
        settings = sender_lib.Settings.from_context(FakeCtx())
        self.assertFalse(settings.enabled)
        self.assertFalse(settings.generic_only)
        self.assertEqual(settings.kinds, {"approval": True, "clarify": True, "done": True, "cron": True})
        custom = sender_lib.Settings.from_context(FakeCtx(**{
            "push.enabled": True, "push.generic_only": True, "push.kinds.cron": False,
            "push.approval_ttl_seconds": 1, "push.clarify_ttl_seconds": True,
            "push.gateway_label": "L" * 100}))
        self.assertTrue(custom.enabled and custom.generic_only)
        self.assertFalse(custom.kinds["cron"])
        self.assertEqual(custom.ttl["approval"], 30)
        self.assertEqual(custom.ttl["clarify"], sender_lib.DEFAULT_TTL["clarify"])
        self.assertEqual(len(custom.gateway_label), 64)


class RelayClientTests(unittest.TestCase):
    """The real HTTP client against a loopback stub. No external network."""

    def setUp(self):
        outer = self
        self.requests, self.reply = [], (200, {}, b"{}")

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                outer.requests.append({"path": self.path, "body": self.rfile.read(length),
                                       "headers": dict(self.headers)})
                status, headers, data = outer.reply
                self.send_response(status)
                for key, value in headers.items():
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            do_DELETE = do_POST

            def log_message(self, *args):
                pass

        class Server(http.server.ThreadingHTTPServer):
            def server_bind(self):  # skip the reverse-DNS lookup HTTPServer does, which can stall
                socketserver.TCPServer.server_bind(self)
                self.server_name, self.server_port = "127.0.0.1", self.server_address[1]

        self.server = Server(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/v1/send"
        self.client = sender_lib.RelayClient(timeout=3)

    def test_posts_json_with_bearer_capability(self):
        capability = secrets.token_urlsafe(32)
        self.assertEqual(self.client.post(self.url, {"a": 1}, capability), (200, None, None))
        request = self.requests[0]
        self.assertEqual(json.loads(request["body"]), {"a": 1})
        self.assertEqual(request["headers"]["Authorization"], "Bearer " + capability)
        self.assertEqual(request["headers"]["Content-Type"], "application/json")

    def test_delete_uses_the_capability_and_sends_no_body(self):
        capability = secrets.token_urlsafe(32)
        self.reply = (204, {}, b"")
        url = self.url.replace("/v1/send", "/v1/register/abc")
        self.assertEqual(self.client.delete(url, capability), (204, None, None))
        request = self.requests[0]
        self.assertEqual((request["path"], request["body"]), ("/v1/register/abc", b""))
        self.assertEqual(request["headers"]["Authorization"], "Bearer " + capability)
        self.assertNotIn("Content-Type", request["headers"])
        device = {"relay_url": self.url.replace("/v1/send", "/"), "relay_device_id": "abc",
                  "send_capability": capability}
        self.assertTrue(sender_lib.unregister_at_relay(device, self.client))
        self.reply = (401, {}, b'{"error":"invalid_capability"}')
        self.assertFalse(sender_lib.unregister_at_relay(device, self.client))

    def test_error_codes_and_retry_after_are_parsed(self):
        self.reply = (429, {"Retry-After": "12"}, b'{"error":"rate_limited","message":"x"}')
        self.assertEqual(self.client.post(self.url, {}, "c" * 40), (429, 12.0, "rate_limited"))
        self.reply = (410, {}, b"not json")
        self.assertEqual(self.client.post(self.url, {}, "c" * 40), (410, None, None))

    def test_redirects_are_never_followed(self):
        self.reply = (307, {"Location": self.url + "/elsewhere"}, b"")
        status, _, _ = self.client.post(self.url, {}, "c" * 40)
        self.assertEqual(status, 307)
        self.assertEqual(len(self.requests), 1)


class RelayClientFailureTests(unittest.TestCase):
    def test_connection_failure_is_a_transient_status_zero(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()  # nothing listens here now
        self.assertEqual(
            sender_lib.RelayClient(timeout=3).post(
                f"http://127.0.0.1:{port}/v1/send", {}, "c" * 40), (0, None, None))


class FakeRelayClient:
    """Stands in for RelayClient on the de-registration path."""

    def __init__(self, status=204):
        self.status, self.deleted = status, []

    def delete(self, url, capability):
        self.deleted.append((url, capability))
        return self.status, None, None


class DashboardTests(StoreCase):
    def setUp(self):
        super().setUp()
        app = FastAPI()
        app.include_router(plugin.router, prefix="/api/plugins/fleet-liveops")
        patcher = patch.object(plugin, "reporting_directory", return_value=self.root)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.relay_client = FakeRelayClient()
        relay_patch = patch.object(plugin, "relay_client", return_value=self.relay_client)
        relay_patch.start()
        self.addCleanup(relay_patch.stop)
        self.client = TestClient(app)
        self.base = "/api/plugins/fleet-liveops/push"
        self.private, self.public = new_device_key()

    def test_register_list_and_unregister(self):
        body = registration(self.public)
        created = self.client.post(f"{self.base}/register", json=body)
        self.assertEqual(created.status_code, 201)
        listing = self.client.get(f"{self.base}/registrations").json()
        self.assertEqual(listing["max_devices"], store_lib.MAX_DEVICES)
        self.assertEqual(listing["devices"], [created.json()])
        exposed = json.dumps([created.json(), listing])
        for private_value in (body["send_capability"], body["device_public_key"],
                              body["relay_device_id"], body["key_id"]):
            self.assertNotIn(private_value, exposed)
        self.assertEqual(created.json()["relay_host"], "relay.example.invalid")
        self.assertEqual(self.client.post(f"{self.base}/register", json=body).status_code, 200)
        self.assertEqual(len(self.client.get(f"{self.base}/registrations").json()["devices"]), 1)
        self.assertEqual(stat.S_IMODE((self.root / "push.json").stat().st_mode), 0o600)
        identifier = created.json()["id"]
        removed = self.client.delete(f"{self.base}/register/{identifier}")
        self.assertEqual((removed.status_code, removed.json()),
                         (200, {"removed": True, "relay_unregistered": True}))
        self.assertEqual(self.client.delete(f"{self.base}/register/{identifier}").status_code, 404)
        self.assertEqual(self.client.delete(f"{self.base}/register/..%2Fpush").status_code, 404)
        self.assertEqual(self.client.get(f"{self.base}/registrations").json()["devices"], [])
        self.assertEqual(len(self.relay_client.deleted), 1)  # only the real removal reached the relay

    def test_unregistering_also_deregisters_at_the_relay_with_the_capability(self):
        body = registration(self.public)
        identifier = self.client.post(f"{self.base}/register", json=body).json()["id"]
        self.client.delete(f"{self.base}/register/{identifier}")
        self.assertEqual(self.relay_client.deleted, [
            (f"{RELAY}/v1/register/{body['relay_device_id']}", body["send_capability"])])

    def test_local_removal_survives_a_relay_failure_and_reports_it(self):
        identifier = self.client.post(f"{self.base}/register",
                                      json=registration(self.public)).json()["id"]
        for status in (0, 500, 401):
            self.client.post(f"{self.base}/register", json=registration(self.public))
            self.relay_client.status = status
            target = self.client.get(f"{self.base}/registrations").json()["devices"][-1]["id"]
            response = self.client.delete(f"{self.base}/register/{target}")
            self.assertEqual((response.status_code, response.json()),
                             (200, {"removed": True, "relay_unregistered": False}))
        self.assertEqual(len(self.client.get(f"{self.base}/registrations").json()["devices"]), 1)
        self.assertEqual(self.client.get(f"{self.base}/registrations").json()["devices"][0]["id"],
                         identifier)

    def test_short_or_malformed_key_ids_get_a_400(self):
        for key_id in ("short", "x" * 21, "x" * 65, "has space " + "x" * 20, ""):
            response = self.client.post(f"{self.base}/register",
                                        json=registration(self.public, key_id=key_id))
            self.assertEqual((response.status_code, response.json()), (400, {"error": "invalid_field"}))
        ok = self.client.post(f"{self.base}/register",
                              json=registration(self.public, key_id="k" * 22))
        self.assertEqual(ok.status_code, 201)
        self.assertEqual(self.client.post(f"{self.base}/register",
                                          json=registration(self.public, key_id="k" * 64)).status_code,
                         201)

    def test_a_key_id_cannot_be_reused_by_another_registration(self):
        body = registration(self.public)
        self.assertEqual(self.client.post(f"{self.base}/register", json=body).status_code, 201)
        clash = self.client.post(f"{self.base}/register",
                                 json=registration(self.public, key_id=body["key_id"]))
        self.assertEqual((clash.status_code, clash.json()), (409, {"error": "key_id_in_use"}))
        # Refreshing the same registration with its own key id is fine.
        self.assertEqual(self.client.post(f"{self.base}/register", json=body).status_code, 200)

    def test_invalid_registrations_are_rejected_without_echoing_input(self):
        secret = "echo-canary-" + secrets.token_hex(6)
        for body in ({**registration(self.public), "gateway_token": secret},
                     registration(self.public, relay_url="http://" + secret + ".example"),
                     registration(self.public, send_capability=secret + "!")):
            response = self.client.post(f"{self.base}/register", json=body)
            self.assertEqual(response.status_code, 400)
            self.assertEqual(response.json(), {"error": "invalid_field"})
            self.assertNotIn(secret, response.text)
        self.assertEqual(self.client.post(f"{self.base}/register", content=b"[1]").status_code, 400)
        self.assertEqual(self.client.post(f"{self.base}/register", content=b"x" * 9000).status_code, 400)
        self.assertEqual(self.client.get(f"{self.base}/registrations").json()["devices"], [])

    def test_registration_count_is_capped(self):
        for _ in range(store_lib.MAX_DEVICES):
            self.assertEqual(self.client.post(f"{self.base}/register",
                                              json=registration(self.public)).status_code, 201)
        over = self.client.post(f"{self.base}/register", json=registration(self.public))
        self.assertEqual((over.status_code, over.json()), (409, {"error": "too_many_devices"}))

    def test_push_files_are_not_mistaken_for_live_reporting_snapshots(self):
        self.client.post(f"{self.base}/register", json=registration(self.public))
        self.store.mint_token(session_key="s", request_id="r", command_digest="d",
                              expires_at=time.time() + 60)
        plugin.publish(self.root, {"schema": 1, "written_at": time.time(), "sessions": [{
            "id": "fleet:a:1", "session_key": "k", "status": "working", "last_active": 1,
            "subagents": []}]}, publisher="a")
        result = plugin.aggregate(self.root, time.time())
        self.assertEqual((result["publishers"], result["stale_publishers"]), (1, 0))
        self.assertNotIn("send_capability", json.dumps(result))


class RespondEndpointTests(SenderCase):
    """End to end: the sender mints a token, the app spends it exactly once."""

    def setUp(self):
        super().setUp()
        self.pending = {}
        self.resolved = []
        approval = ModuleType("tools.approval")
        approval.list_gateway_approvals = lambda key: list(self.pending.get(key, []))
        approval.resolve_gateway_approval = self.resolve
        tools = ModuleType("tools")
        tools.approval = approval
        patcher = patch.dict(sys.modules, {"tools": tools, "tools.approval": approval})
        patcher.start()
        self.addCleanup(patcher.stop)
        app = FastAPI()
        app.include_router(plugin.router, prefix="/api/plugins/fleet-liveops")
        directory = patch.object(plugin, "reporting_directory", return_value=self.root)
        directory.start()
        self.addCleanup(directory.stop)
        self.client = TestClient(app)
        self.url = "/api/plugins/fleet-liveops/push/respond"
        self.command = "ls -la"
        self.request_ids[self.command] = "request-abc"
        self.pending["gateway-session-key"] = [{"request_id": "request-abc", "command": self.command}]
        self.sender.on_pre_approval_request(**self.approval(self.command))
        self.sender.drain()
        self.token = open_sealed(self.sent()[0], self.private)["response_token"]

    def resolve(self, session_key, choice, request_id=None, **kwargs):
        self.resolved.append((session_key, choice, request_id))
        return 1

    def respond(self, **overrides):
        body = {"token": self.token, "request_id": "request-abc", "choice": "once"}
        body.update(overrides)
        return self.client.post(self.url, json=body)

    def test_valid_token_resolves_exactly_one_request_exactly_once(self):
        response = self.respond()
        self.assertEqual((response.status_code, response.json()), (200, {"resolved": 1}))
        self.assertEqual(self.resolved, [("gateway-session-key", "once", "request-abc")])
        replay = self.respond()
        self.assertEqual((replay.status_code, replay.json()), (401, {"error": "invalid_token"}))
        self.assertEqual(len(self.resolved), 1)

    def test_deny_is_allowed_but_session_and_always_are_not(self):
        for choice in ("session", "always", "all", "", None):
            self.assertEqual(self.respond(choice=choice).status_code, 400)
        self.assertEqual(self.resolved, [])
        self.assertEqual(self.respond(choice="deny").status_code, 200)
        self.assertEqual(self.resolved[0][1], "deny")

    def test_token_for_another_request_is_refused_and_not_burned(self):
        response = self.respond(request_id="request-other")
        self.assertEqual((response.status_code, response.json()), (409, {"error": "token_mismatch"}))
        self.assertEqual(self.resolved, [])
        self.assertEqual(self.respond().status_code, 200)

    def test_unknown_or_malformed_requests_are_refused(self):
        self.assertEqual(self.respond(token="x" * 43).status_code, 401)
        self.assertEqual(self.client.post(self.url, json={"token": self.token}).status_code, 400)
        self.assertEqual(self.client.post(self.url, json={
            "token": self.token, "request_id": "request-abc", "choice": "once",
            "all": True}).status_code, 400)
        self.assertEqual(self.resolved, [])

    def test_changed_command_or_missing_request_is_not_resolved(self):
        self.pending["gateway-session-key"] = [{"request_id": "request-abc", "command": "rm -rf ./x"}]
        response = self.respond()
        self.assertEqual((response.status_code, response.json()), (409, {"error": "not_pending"}))
        self.assertEqual(self.resolved, [])
        self.assertEqual(self.respond().status_code, 401)  # the token is spent regardless

    def test_withdrawn_request_token_is_revoked(self):
        self.sender.on_post_approval_response(**self.approval(self.command), choice="timeout")
        self.sender.drain()
        self.assertEqual(self.respond().status_code, 401)
        self.assertEqual(self.resolved, [])

    def test_expired_token_is_refused(self):
        late = store_lib.PushStore(self.root, clock=lambda: self.now + 10_000)
        with patch.object(plugin, "push_store", return_value=late):
            self.assertEqual(self.respond().status_code, 401)
        self.assertEqual(self.resolved, [])


if __name__ == "__main__":
    unittest.main()


