# Archived one-off scripts

This directory holds historical, one-off milestone scripts (prefixes such as
`l1_`, `h1_`, `h2_`, `u1_`..`u4_`, `s2_`/`s3_`, `rt3_`..`rt5_`, `fos5_`,
`fos7_`, `m14_`, `d1_`, `w0_`/`w1_`, plus `m10_validate.sh` and
`m11_validate.sh`, which used to live at the repository root).

**They are unsupported and are not run by CI, the Makefile, or any release
tooling.** They were written for a specific milestone, simulator, device, or
gateway setup and are kept only so history and old references stay
recoverable (they were moved with `git mv`, so `git log --follow` works).
Many assume they live directly under `scripts/` (for example, they compute the
repository root as `$SCRIPT_DIR/..` or call sibling scripts as
`scripts/<name>`), so running one from here may fail without path edits. Do not
copy them into new work; write a new script and wire it into a workflow,
Makefile target, or doc instead.

## Why they moved

A reference audit over the tracked tree (every file except `scripts/archive/`,
`docs/archive/`, and the generated Xcode project) found no workflow, Makefile
target, current doc, source file, or supported script that mentions any of
these files. Scripts that turned out to be referenced stayed in `scripts/`
(for example `u4_device.sh` from `dev_check.sh`, and `h2_uitest.sh`,
`l1_start_serve.sh`, `t3tls_gen_fixtures.sh`, and `fos7_contrast_gate.py` from
source comments).

## Keeping `scripts/` from growing back

`scripts/unreferenced_scripts_guard.sh` (run in CI, self-tested by
`scripts/unreferenced_scripts_guard_test.sh`) fails when a top-level script is
referenced by nothing. To add a script that is deliberately manual, list it with
a reason in `scripts/unreferenced_allowlist.txt`. References from this
directory do not count.
