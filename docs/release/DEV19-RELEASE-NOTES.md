# DEV19 — final public TestFlight candidate

Status: candidate, not uploaded. Upload, external distribution, and App Store
submission are separate decisions.

| Field | Value |
|---|---|
| App | Hermes Fleet (production identity) |
| Bundle ID | `com.aiowa.hermesfleet` |
| Version (build) | `0.2.0` (`98` — see "Build number") |
| IPA SHA-256 | `fc73f5be15430c183f37cf4b874b1037efe5e310f7d37af15df0252c1b39d76b` (20,281,022 bytes) |
| Baseline | DEV18 `3ff41b79d10ea35ef9af4dda26d46a3c6b99725f` (owner-verified) |
| Source commit | `250e3ec232cc0187bb55019a769bb6ed69158d9e` |
| Export method | `app-store-connect` (`scripts/release_export_options.plist`), not TestFlight Internal Only |

## What changed since DEV18

### Long chats open again (#188)
- Bot Chats with more than ~20,000 messages used to fail with "too long to reload".
  Fleet now detects that refusal, reopens the chat without its full transcript, and
  loads the newest 200 messages over the gateway's paged history route. Older
  messages load on demand with **Load earlier messages** at the top of the chat;
  your reading position is kept (verified by the new `LongChatPagingUITests`
  suite against a synthetic 25,000-message chat — it caught and fixed a
  scroll-jump during this build).
- Chats that opened before are unchanged: the paged path is used only when the
  gateway refuses the normal reload.
- If the gateway cannot page history, the chat still opens, new messages work, and
  Fleet explains how to see earlier history (update Hermes, or use Hermes Desktop).

### Group chats match 1:1 chats
- Long-press a group message to **Copy Message**.
- **Find in Conversation** in group chats (search, next/previous, jump to match).
- The **Latest** button now floats bottom-right like 1:1 chats and respects Reduce Motion.
- Retry buttons stay visible but disabled while a send is in flight or unavailable.

### Feel
- One consistent haptic vocabulary: send, approve, deny, refresh finished,
  pairing finished, copy, selection, and a failure tap when a send or turn fails.
- A **Thinking** placeholder appears in the assistant's spot before the first
  words arrive, a soft caret follows streaming text, and a light tap marks the
  first token. All motion is static under Reduce Motion.
- Cold-load lists (Chats, Bots, Gateways) show placeholder rows instead of a
  bare spinner; stacked notices are ordered by severity and offer a recovery
  action where one exists.

### Clearer words
- HTTP gateway warning explains what Fleet can and can't verify (#62). When the
  warning appears, and the confirmation it requires, are unchanged.
- Sign-in errors, empty states and error messages use plain sentences with a
  next step. Raw technical error text no longer reaches the screen.

### Accessibility
- 44-point minimum tap targets on header, composer, drawer and gateway-row controls.
- Decorative icons hidden from VoiceOver; section headers announced as headers.
- Reduce Motion honored by the copy confirmation, Latest jump, presence and
  loading placeholders.
- At the largest text sizes (AX4/AX5) the drawer compose pill, Chats floating
  pill, conversation header and composer buttons stop growing so the message
  field, header identity and lists keep their room; message text and list rows
  still scale fully.

## Known limitations
- **Long chats under the 20k limit but over 16 MB in one history response** can still
  fail to load fully; paging switches on only after the oversized-frame signal.
- After a stream gap in a paged chat, the replay engine's best-effort
  full-history fetch may still be attempted (it fails safely; the paged refetch follows).
- "Load earlier messages" is discarded if a newest-page refresh lands while it
  is in flight; tap again.
- Older paged messages show tool rows by name only (no 80-char context preview).
- Group-chat Find lives in the room header (scrolls with the transcript), and group
  bot replies have no per-reply regenerate (the group wire carries no turn id).
- At AX5 the conversation header truncates the bot name ("D…"); the name and
  status remain available to VoiceOver and in the ⋯ menu.
- Seven accessibility audit items are deferred with reasons in
  `docs/release/DEV19-A11Y-AUDIT.md` (chip-zone AX5 clamp, combined error
  banners hiding Dismiss from VoiceOver, partial Chats-row audit, decorative
  chevrons in two text buttons).
- Raw-error cleanup covers FleetUI surfaces; typed onboarding enrollment
  errors keep their existing (technical) wording.
- Multilingual voice (#185), offline outbox, Inbox, iPad layout, Liquid Glass,
  push and Live Activities remain deferred.

## Build number
Local records top out at production `0.2.0 (97)` (RELEASES.md, local archives). App
Store Connect was not readable from this machine (not signed in), so `98` is
**unverified** against ASC. If ASC already holds 98 for 0.2.0, re-archive with the
next free number: `bash scripts/archive_and_export.sh <N> <sha>`.

## Public TestFlight — What to Test

> Thanks for testing Hermes Fleet! This is the last public beta before the App Store.
>
> Please try:
> - **Long Bot Chats**: open your longest chat. It should open on the newest messages.
>   Tap **Load earlier messages** at the top to page back. Your place should stay put.
> - **Group chats**: long-press a message to copy it, use the magnifying glass to find
>   text, and try the **Latest** button after scrolling up.
> - **Approvals and sends**: approve or deny a request and send a few messages; you
>   should feel a light tap for each, and a distinct tap if something fails.
> - **While a bot is thinking**: watch for the "Thinking" row before the reply starts.
> - **Adding a gateway over HTTP**: read the new warning and tell us if it's clear.
> - **Accessibility**: try VoiceOver, Larger Text, and Reduce Motion on the main screens.
>
> Tell us about anything confusing, slow, or broken using TestFlight's feedback
> (take a screenshot to attach one).
