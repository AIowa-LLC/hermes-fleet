"""Hermes PluginContext + python-telegram-bot integration with an isolated profile fixture."""
from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from owner_control import _production_dependencies, register


@unittest.skipUnless(importlib.util.find_spec("telegram"), "python-telegram-bot is unavailable")
class NativeRegistrationIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_plugin_context_and_ptb_command_dispatch_use_scoped_config(self):
        import yaml
        from telegram import Chat, Message, MessageEntity, Update, User
        from telegram.ext import Application

        from gateway.config import Platform, load_gateway_config
        from hermes_constants import reset_hermes_home_override, set_hermes_home_override
        from hermes_cli.plugins import PluginContext, PluginManager, PluginManifest

        with TemporaryDirectory() as root:
            base = Path(root)
            home, source, runtime = base / "home", base / "source", base / "runtime"
            home.mkdir()
            source.mkdir()
            runtime.mkdir()
            settings = {
                "hermes_home": str(home),
                "source": str(source),
                "runtime_source": str(runtime),
                "manifest": str(base / "release-manifest.json"),
                "trusted_manifest_sha256": "a" * 64,
                "origin": "https://fleet.example.test",
                "approval": str(base / "approval.json"),
            }
            telegram_extra = {
                "fleet_pairing_owner_user_ids": ["12345"],
                "fleet_pairing_host": settings,
            }
            (home / "config.yaml").write_text(yaml.safe_dump({
                "platforms": {"telegram": {"enabled": False, "extra": telegram_extra}},
            }), encoding="utf-8")

            scope_token = set_hermes_home_override(home)
            try:
                effective_config = load_gateway_config()
                adapter_config = effective_config.platforms[Platform.TELEGRAM]
                self.assertEqual(adapter_config.extra, telegram_extra)

                manager = PluginManager(scope_key=str(home))
                manifest = PluginManifest(
                    name="fleet-owner-control", version="0.1.0", source="user",
                    path=str(base / "owner_control"),
                )
                context = PluginContext(manifest, manager)
                register(context)
                factories = manager.get_platform_handler_factories("telegram")
                self.assertTrue(factories)

                application = Application.builder().token(
                    "123456:abcdefghijklmnopqrstuvwxyzABCDEFGHIJK"
                ).build()
                application.bot._bot_user = User(
                    id=123456, is_bot=True, first_name="Test gateway", username="fleet_test_bot",
                )
                authorization = {"allowed": True}
                adapter = SimpleNamespace(
                    config=adapter_config,
                    _is_callback_user_authorized=lambda *_args, **_kwargs: authorization["allowed"],
                )
                factories[0][0](application, adapter)
                commands = {
                    command
                    for handlers in application.handlers.values()
                    for handler in handlers
                    if hasattr(handler, "commands")
                    for command in handler.commands
                }
                self.assertIn("fleetstatus", commands)
                self.assertIn("fleetqr", commands)

                user = User(id=12345, is_bot=False, first_name="Owner")
                chat = Chat(id=12345, type=Chat.PRIVATE)
                msg = Message(
                    message_id=7, date=datetime.now(timezone.utc), chat=chat, from_user=user,
                    text="/fleetstatus",
                    entities=[MessageEntity(MessageEntity.BOT_COMMAND, offset=0, length=12)],
                )
                msg.set_bot(application.bot)
                update = Update(update_id=91001, message=msg)
                update.set_bot(application.bot)

                # Exercise production's documented per-profile SQLite store without calling
                # readiness, the invitation issuer, or the QR display.
                dependencies = _production_dependencies(lambda: settings, lambda _update: True)
                self.assertTrue(dependencies.claim_update(home, update))
                self.assertFalse(dependencies.claim_update(home, update))
                receipt_db = home / "plugin-data" / "fleet-owner-control" / "data.db"
                self.assertTrue(receipt_db.is_file())
                self.assertEqual(receipt_db.stat().st_mode & 0o777, 0o600)

                async def dispatch_native(update_to_dispatch):
                    for handlers in application.handlers.values():
                        for handler in handlers:
                            match = handler.check_update(update_to_dispatch)
                            if match:
                                await handler.callback(update_to_dispatch, SimpleNamespace(args=[]))
                                return True
                    return False

                with patch.object(Message, "reply_text", new=AsyncMock()) as reply:
                    self.assertTrue(await dispatch_native(update))
                self.assertTrue(reply.awaited)
                self.assertIn("Fleet QR pairing is blocked", reply.await_args.args[-1])

                authorization["allowed"] = False
                rejected_message = Message(
                    message_id=8, date=datetime.now(timezone.utc), chat=chat, from_user=user,
                    text="/fleetqr",
                    entities=[MessageEntity(MessageEntity.BOT_COMMAND, offset=0, length=8)],
                )
                rejected_message.set_bot(application.bot)
                rejected = Update(update_id=91002, message=rejected_message)
                with patch.object(Message, "reply_text", new=AsyncMock()) as reply:
                    self.assertTrue(await dispatch_native(rejected))
                self.assertTrue(reply.awaited)
                self.assertIn("configured owner", reply.await_args.args[-1])
            finally:
                reset_hermes_home_override(scope_token)


if __name__ == "__main__":
    unittest.main()
