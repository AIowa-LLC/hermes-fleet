#!/usr/bin/env python3
"""Positive/negative fixtures for security_hygiene_guard.py (synthetic sources)."""
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "guard", Path(__file__).with_name("security_hygiene_guard.py")
)
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


def run(source: str, package: str = "FleetUI") -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        src = root / "Packages" / package / "Sources" / package
        src.mkdir(parents=True)
        (src / "Sample.swift").write_text(source, encoding="utf-8")
        # Test targets must never be scanned.
        tests = root / "Packages" / package / "Tests" / f"{package}Tests"
        tests.mkdir(parents=True)
        (tests / "SampleTests.swift").write_text(
            'let x = env["HERMES_FLEET_APP_LOCK"]\n', encoding="utf-8"
        )
        return guard.check(root)


class LockOverrideTests(unittest.TestCase):
    def test_unguarded_read_fails(self) -> None:
        self.assertTrue(run('let m = env["HERMES_FLEET_APP_LOCK"]\n'))

    def test_unguarded_lock_prefix_read_fails(self) -> None:
        self.assertTrue(run('let m = env["HERMES_FLEET_LOCK_RESET"]\n'))

    def test_debug_guarded_read_passes(self) -> None:
        self.assertEqual(
            run('#if DEBUG\nlet m = env["HERMES_FLEET_APP_LOCK"]\n#endif\n'), []
        )

    def test_debug_and_simulator_condition_passes(self) -> None:
        self.assertEqual(
            run(
                "#if DEBUG && targetEnvironment(simulator)\n"
                'let m = env["HERMES_FLEET_LOCK_AUTH"]\n#endif\n'
            ),
            [],
        )

    def test_else_branch_of_debug_fails(self) -> None:
        self.assertTrue(
            run('#if DEBUG\nlet a = 1\n#else\nlet m = env["HERMES_FLEET_APP_LOCK"]\n#endif\n')
        )

    def test_not_debug_fails(self) -> None:
        self.assertTrue(run('#if !DEBUG\nlet m = env["HERMES_FLEET_APP_LOCK"]\n#endif\n'))

    def test_debug_or_other_fails(self) -> None:
        self.assertTrue(
            run('#if DEBUG || STAGING\nlet m = env["HERMES_FLEET_APP_LOCK"]\n#endif\n')
        )

    def test_read_after_endif_fails(self) -> None:
        self.assertTrue(
            run('#if DEBUG\nlet a = 1\n#endif\nlet m = env["HERMES_FLEET_APP_LOCK"]\n')
        )

    def test_nested_non_debug_inside_debug_passes(self) -> None:
        self.assertEqual(
            run(
                "#if DEBUG\n#if os(iOS)\n"
                'let m = env["HERMES_FLEET_APP_LOCK"]\n#endif\n#endif\n'
            ),
            [],
        )

    def test_comment_mention_is_ignored(self) -> None:
        self.assertEqual(run("/// Reads HERMES_FLEET_APP_LOCK in DEBUG only.\n"), [])

    def test_unrelated_env_var_is_not_a_lock_override(self) -> None:
        self.assertEqual(run('let m = env["HERMES_FLEET_NAV_RESET"]\n'), [])


class LogPrivacyTests(unittest.TestCase):
    def test_public_url_fails(self) -> None:
        self.assertTrue(
            run('log.info("x \\(Redaction.redactedURL(self.baseURL), privacy: .public)")\n')
        )

    def test_public_host_fails(self) -> None:
        self.assertTrue(run('log.info("x \\(url.host ?? "", privacy: .public)")\n'))

    def test_public_session_id_fails(self) -> None:
        self.assertTrue(run('log.info("x \\(sessionID, privacy: .public)")\n'))

    def test_public_title_fails(self) -> None:
        self.assertTrue(run('log.info("x \\(session.title, privacy: .public)")\n'))

    def test_public_status_code_passes(self) -> None:
        self.assertEqual(run('log.error("x \\(http.statusCode, privacy: .public)")\n'), [])

    def test_private_url_passes(self) -> None:
        self.assertEqual(
            run('log.info("x \\(Redaction.redactedURL(self.baseURL), privacy: .private)")\n'), []
        )

    def test_default_privacy_passes(self) -> None:
        self.assertEqual(run('log.info("x \\(url)")\n'), [])

    def test_second_interpolation_on_line_is_checked(self) -> None:
        self.assertTrue(
            run('log.info("\\(n, privacy: .public) \\(gatewayURL, privacy: .public)")\n')
        )


class RepoTreeTest(unittest.TestCase):
    def test_current_tree_is_clean(self) -> None:
        self.assertEqual(guard.check(Path(__file__).resolve().parent.parent), [])


if __name__ == "__main__":
    unittest.main()
