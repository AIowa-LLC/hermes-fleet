# Hermes Fleet RC evidence report

Public-safe template. Replace placeholders only with evidence from the exact candidate. Do not include UDIDs, credentials, tokens, private hostnames, account identifiers, signing identifiers, or local filesystem paths.

## Candidate identity

- Candidate Git SHA: `<full or short SHA>`
- Branch/tag intent: `<release candidate; no public tag required>`
- App version: `<marketing version>`
- Build: `<build number>`
- Configuration: `Release / RC`
- Device class: `<supported iPhone model class>`
- Device OS: `<iOS version>`
- Gateway/path class: `<synthetic description, e.g. LAN HTTPS gateway>`
- Test date/time: `<date and timezone>`

## Repository and deterministic validation

| Check | Exact command | Exit code | Result/evidence |
|---|---|---:|---|
| RC preflight | `bash scripts/rc_preflight.sh` | | |
| UI inventory | `bash scripts/c1_ui_matrix.sh --audit` | | |
| Static guards | `bash scripts/c1_static.sh` | | |
| Package/hosted tests | `<command>` | | |
| Deterministic UI selection | `<exact shard or class command>` | | |

## RC journey results

Use PASS, FAIL, or HOLD. Link only to public-safe screenshots, recordings, or redacted logs.

| Journey | Result | Evidence reference | Defect/issue |
|---|---|---|---|
| Install, launch, onboarding, lifecycle | | | |
| Gateway manual + QR setup, persistence, fail-closed errors | | | |
| Direct chat: existing/new session and reconnect | | | |
| Skills/slash commands and approval | | | |
| Bots, avatar, Pet, image/shape, relaunch | | | |
| Groups, RoomLink, older history/Latest | | | |
| Attachments, microphone, speech, voice | | | |
| App Lock and Face ID lifecycle | | | |
| Failure recovery and reconciliation | | | |

## Environmental suite accounting

Copy every environmental class from `scripts/c1_ui_matrix.sh` and record its exact command, result, and evidence. Use N/A only with a concrete external-beta reason; never silently skip.

| Suite | Result (PASS/FAIL/HOLD/N/A) | Exact command | Evidence or concrete N/A reason |
|---|---|---|---|
| `<environmental suite>` | | | |

## Defects and release decision

| Defect / issue | Affected journey | Severity/blocking status | Re-run evidence |
|---|---|---|---|
| `<none or issue link>` | | | |

- Unresolved risks: `<none or concise list>`
- Final RC decision: `PASS / FAIL / HOLD`
- Decision owner: `<name or role>`
- Decision date: `<date>`

This report records evidence; it does not authorize distribution by itself. Upload, submission, public release, and tester distribution require separate explicit authorization.
