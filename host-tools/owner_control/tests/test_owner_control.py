"""Synthetic tests for the standalone owner-control plugin; no Hermes core imports or live effects."""
from __future__ import annotations

import asyncio
import sqlite3
from pathlib import Path
from tempfile import TemporaryDirectory
import threading
from types import SimpleNamespace
import unittest

from owner_control import Dependencies, _claim_receipt, build_handlers


class OwnerControlTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = TemporaryDirectory()
        self.home = Path(self.temp.name) / "home"
        self.runtime = Path(self.temp.name) / "runtime"
        self.home.mkdir()
        self.runtime.mkdir()
        self.current_home = self.home
        self.issued = []
        self.cancelled = []
        self.rendered = []
        self.cancel_result = True
        self.claimed = set()
        self.claim_update = self.claim_once
        self.ready = self.report()
        self.dependencies = Dependencies(
            readiness_check=lambda _home: self.ready,
            issue_invitation=self.issue,
            render_qr=self.render,
            cancel_invitation=self.cancel,
            current_home=lambda: self.current_home,
            ordinary_access=lambda _update: True,
            claim_update=self.claim_update,
        )
        self.status, self.qr = build_handlers(
            owner_config=["12345"], expected_home=self.home, dependencies=self.dependencies,
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def report(self) -> dict:
        origin = "https://fleet.example.test"
        return {
            "issuer_ready": True,
            "home_matches": True,
            "runtime_matches": True,
            "https_origin_verified": True,
            "system_tls_trusted": True,
            "phone_reachability_verified": True,
            "local_display_ready": True,
            "service_runtime_verified": True,
            "home": str(self.home),
            "runtime_dir": str(self.runtime),
            "origin": origin,
            "release_id": "sha256:synthetic",
            "blockers": (),
        }

    def issue(self, _home: Path) -> tuple[str, str]:
        invitation_id = "invite_123"
        self.issued.append(invitation_id)
        return invitation_id, f"https://fleet.example.test/pair#v=1&i={invitation_id}&s=syntheticsecret"

    def render(self, link: str, invitation_id: str, _home: Path, _runtime: Path) -> bool:
        self.rendered.append((link, invitation_id))
        return True

    def cancel(self, _home: Path, invitation_id: str) -> bool:
        self.cancelled.append(invitation_id)
        return self.cancel_result

    def claim_once(self, _home: Path, update) -> bool:
        key = (update.update_id, update.effective_user.id)
        if key in self.claimed:
            return False
        self.claimed.add(key)
        return True

    @staticmethod
    def update(*, user_id=12345, chat_id=12345, chat_type="private", is_bot=False,
               message_fields=None, update_id=1):
        replies = []

        async def reply_text(text):
            replies.append(text)

        user = SimpleNamespace(id=user_id, is_bot=is_bot)
        chat = SimpleNamespace(id=chat_id, type=chat_type)
        message = SimpleNamespace(reply_text=reply_text, from_user=user, chat=chat,
                                  **(message_fields or {}))
        update = SimpleNamespace(update_id=update_id, message=message, effective_message=message,
                                 effective_user=user, effective_chat=chat)
        return update, replies

    def test_owner_private_request_issues_and_displays_without_returning_link(self):
        update, replies = self.update()
        asyncio.run(self.qr(update, None))

        self.assertEqual(self.issued, ["invite_123"])
        self.assertEqual(self.rendered[0][1], "invite_123")
        self.assertNotIn("syntheticsecret", "\n".join(replies))
        self.assertNotIn("fleet.example.test", "\n".join(replies))
        self.assertEqual(self.cancelled, [])
        self.assertIn("opening privately", replies[0])
        self.assertIn("display finished", replies[-1])

    def test_group_or_nonowner_cannot_issue(self):
        for update, _replies in (
            self.update(chat_id=-100, chat_type="group"),
            self.update(user_id=77777, chat_id=77777),
            self.update(user_id=None),
            self.update(is_bot=True),
        ):
            asyncio.run(self.qr(update, None))
        self.assertEqual(self.issued, [])

    def test_owner_must_also_pass_ordinary_gateway_access(self):
        self.dependencies = Dependencies(
            self.dependencies.readiness_check, self.dependencies.issue_invitation,
            self.dependencies.render_qr, self.dependencies.cancel_invitation,
            self.dependencies.current_home, ordinary_access=lambda _update: False,
            claim_update=self.claim_update,
        )
        _status, qr = build_handlers(owner_config=["12345"], expected_home=self.home,
                                     dependencies=self.dependencies)
        update, _ = self.update()
        asyncio.run(qr(update, None))
        self.assertEqual(self.issued, [])

    def test_status_never_issues(self):
        update, replies = self.update()
        asyncio.run(self.status(update, None))
        self.assertIn("host checks are ready", replies[-1])
        self.assertEqual(self.issued, [])
        self.assertEqual(self.claimed, set())

    def test_same_native_update_is_not_issued_twice(self):
        update, _ = self.update(update_id=123)
        asyncio.run(self.qr(update, None))
        asyncio.run(self.qr(update, None))
        self.assertEqual(len(self.issued), 1)

    def test_native_update_receipt_survives_handler_restart(self):
        database = Path(self.temp.name) / "receipt.db"

        def persistent_claim(home, update):
            conn = sqlite3.connect(database)
            try:
                return _claim_receipt(conn, home, 444, update.effective_user.id, update.update_id)
            except Exception:
                conn.rollback()
                return False
            finally:
                conn.close()

        deps = Dependencies(
            self.dependencies.readiness_check, self.dependencies.issue_invitation,
            self.dependencies.render_qr, self.dependencies.cancel_invitation,
            self.dependencies.current_home, ordinary_access=lambda _update: True,
            claim_update=persistent_claim,
        )
        _status, first_qr = build_handlers(owner_config=["12345"], expected_home=self.home,
                                           dependencies=deps)
        update, _ = self.update(update_id=876543)
        asyncio.run(first_qr(update, None))
        _status, restarted_qr = build_handlers(owner_config=["12345"], expected_home=self.home,
                                               dependencies=deps)
        _replayed, replies = self.update(update_id=876543)
        asyncio.run(restarted_qr(_replayed, None))
        self.assertEqual(len(self.issued), 1)
        self.assertIn("already handled", replies[-1])

    def test_not_ready_does_not_create_replay_store(self):
        database = Path(self.temp.name) / "receipt.db"

        def persistent_claim(home, update):
            conn = sqlite3.connect(database)
            try:
                return _claim_receipt(conn, home, 444, update.effective_user.id, update.update_id)
            finally:
                conn.close()

        self.ready["service_runtime_verified"] = False
        deps = Dependencies(
            self.dependencies.readiness_check, self.dependencies.issue_invitation,
            self.dependencies.render_qr, self.dependencies.cancel_invitation,
            self.dependencies.current_home, ordinary_access=lambda _update: True,
            claim_update=persistent_claim,
        )
        _status, qr = build_handlers(owner_config=["12345"], expected_home=self.home,
                                     dependencies=deps)
        update, _ = self.update(update_id=876544)
        asyncio.run(qr(update, None))
        self.assertFalse(database.exists())

    def test_concurrent_commands_from_owner_do_not_mint_duplicate_invitations(self):
        display_started, display_done = threading.Event(), threading.Event()

        def blocking_display(*_args):
            display_started.set()
            display_done.wait(timeout=2)
            return True

        deps = Dependencies(
            self.dependencies.readiness_check, self.dependencies.issue_invitation,
            blocking_display, self.dependencies.cancel_invitation,
            self.dependencies.current_home, ordinary_access=lambda _update: True,
            claim_update=self.claim_update,
        )
        _status, qr = build_handlers(owner_config=["12345"], expected_home=self.home, dependencies=deps)

        async def run_pair():
            first, first_replies = self.update(update_id=201)
            second, second_replies = self.update(update_id=202)
            task = asyncio.create_task(qr(first, None))
            started = await asyncio.to_thread(display_started.wait, 1)
            self.assertTrue(started)
            await qr(second, None)
            display_done.set()
            await task
            return first_replies, second_replies

        _first_replies, second_replies = asyncio.run(run_pair())
        self.assertEqual(len(self.issued), 1)
        self.assertIn("previous Fleet QR request", second_replies[-1])

    def test_forwarded_commands_are_rejected(self):
        update, _ = self.update(message_fields={"forward_origin": object()})
        asyncio.run(self.qr(update, None))
        self.assertEqual(self.issued, [])
        self.assertEqual(self.claimed, set())

    def test_missing_or_broad_owner_config_fails_closed(self):
        for config in (None, [], ["*"], ["12345", "all"], True):
            status, qr = build_handlers(owner_config=config, expected_home=self.home,
                                        dependencies=self.dependencies)
            update, _ = self.update()
            asyncio.run(qr(update, None))
            self.assertEqual(self.issued, [])

    def test_profile_scope_mismatch_blocks_status_and_issuance(self):
        self.current_home = self.runtime
        update, replies = self.update()
        asyncio.run(self.status(update, None))
        self.assertIn("blocked", replies[-1])
        update, _ = self.update()
        asyncio.run(self.qr(update, None))
        self.assertEqual(self.issued, [])

    def test_readiness_failure_blocks_issuance(self):
        self.ready["service_runtime_verified"] = False
        update, replies = self.update()
        asyncio.run(self.qr(update, None))
        self.assertEqual(self.issued, [])
        self.assertIn("running dashboard service", replies[-1])

    def test_contradictory_helper_report_fails_closed(self):
        self.ready["blockers"] = ["issuer_ready"]
        update, replies = self.update(update_id=150)
        asyncio.run(self.qr(update, None))
        self.assertEqual(self.issued, [])
        self.assertIn("could not be verified", replies[-1])

    def test_missing_private_owner_observation_blocks_issuance(self):
        self.ready["phone_reachability_verified"] = False
        update, _ = self.update()
        asyncio.run(self.qr(update, None))
        self.assertEqual(self.issued, [])

    def test_display_failure_cancels_exact_invitation(self):
        self.dependencies = Dependencies(
            self.dependencies.readiness_check, self.dependencies.issue_invitation,
            lambda *_args: False, self.dependencies.cancel_invitation,
            self.dependencies.current_home, ordinary_access=lambda _update: True,
            claim_update=self.claim_update,
        )
        _status, qr = build_handlers(owner_config=["12345"], expected_home=self.home,
                                    dependencies=self.dependencies)
        update, replies = self.update()
        asyncio.run(qr(update, None))
        self.assertEqual(self.cancelled, ["invite_123"])
        self.assertNotIn("syntheticsecret", "\n".join(replies))

    def test_issuer_origin_mismatch_cancels_and_never_displays_link(self):
        deps = Dependencies(
            self.dependencies.readiness_check,
            lambda _home: ("invite_123", "https://other.example.test/pair#v=1&i=invite_123&s=secret"),
            self.dependencies.render_qr, self.dependencies.cancel_invitation,
            self.dependencies.current_home, ordinary_access=lambda _update: True,
            claim_update=self.claim_update,
        )
        _status, qr = build_handlers(owner_config=["12345"], expected_home=self.home, dependencies=deps)
        update, replies = self.update()
        asyncio.run(qr(update, None))
        self.assertEqual(self.cancelled, ["invite_123"])
        self.assertEqual(self.rendered, [])
        self.assertNotIn("secret", "\n".join(replies))
        self.assertIn("invitation was cancelled", replies[-1])

    def test_failed_cancellation_is_disclosed(self):
        self.cancel_result = False
        deps = Dependencies(
            self.dependencies.readiness_check,
            lambda _home: ("invite_123", "https://other.example.test/pair#v=1&i=invite_123&s=secret"),
            self.dependencies.render_qr, self.cancel,
            self.dependencies.current_home, ordinary_access=lambda _update: True,
            claim_update=self.claim_update,
        )
        _status, qr = build_handlers(owner_config=["12345"], expected_home=self.home, dependencies=deps)
        update, replies = self.update(update_id=301)
        asyncio.run(qr(update, None))
        self.assertNotIn("invitation was cancelled", replies[-1])
        self.assertIn("could not be confirmed", replies[-1])

    def test_issuer_without_cancel_id_discloses_unconfirmed_cleanup(self):
        deps = Dependencies(
            self.dependencies.readiness_check,
            lambda _home: ("", "https://fleet.example.test/pair#v=1&i=invite_123&s=secret"),
            self.dependencies.render_qr, self.cancel,
            self.dependencies.current_home, ordinary_access=lambda _update: True,
            claim_update=self.claim_update,
        )
        _status, qr = build_handlers(owner_config=["12345"], expected_home=self.home, dependencies=deps)
        update, replies = self.update(update_id=302)
        asyncio.run(qr(update, None))
        self.assertIn("cannot confirm cancellation", replies[-1])
        self.assertEqual(self.cancelled, [])


if __name__ == "__main__":
    unittest.main()
