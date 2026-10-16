# Secure gateway first-use review

A secure (`https`) gateway is trusted by pinning the SHA-256 of its certificate's
SubjectPublicKeyInfo. The first key is never accepted implicitly: the user
reviews the key the endpoint actually presents and explicitly confirms it.

## Flow

1. **Review.** In Add/Edit Gateway, *Review Certificate* performs a TLS
   handshake only (`TLSPresentedKeyProbe`). The challenge is cancelled as soon as
   the key is read, so no request and no credential is ever sent.
2. **Confirm.** The sheet shows the gateway name, the address and the full
   fingerprint, with the instruction to compare it against a trusted source (the
   gateway operator or its console). *Trust This Key* creates a `TLSKeyReview`
   bound to that endpoint and that key; *Cancel* discards it.
3. **Save.** `AppEnvironment` validates the review (same endpoint, not older
   than five minutes) before registering anything, then stores a first-use
   approval bound to exactly that key. The credential is saved afterwards.
4. **Connect.** `TLSTrustEvaluator` consumes the approval only when the key
   presented now equals the approved key, and writes the pin with
   compare-and-set. The decision runs under one lock, so concurrent connections
   converge on one pin; none can overwrite an established pin.

## Fail-closed cases

| Case | Result |
| --- | --- |
| No review for a secure endpoint | Save refused; nothing registered |
| Review for a different endpoint, or address edited after review | Refused (`endpointChanged`) |
| Review older than five minutes, or from the future | Refused (`stale`) |
| Cancelled review | Nothing stored |
| Key differs at connect time from the approved key | Connection cancelled; no pin; approval kept |
| Endpoint edited on an existing gateway | Old pin and approval cleared; a new review is required |
| Pin store has no approval seam | Deny-all approvals (never "trust first") |
| Legacy unbound approval left in the Keychain | Ignored; never counts as approval |

There is no unapproved or unbound first-use path.

## Limits

The review proves only that the user confirmed the displayed key; the user must
actually compare it with a trusted source. The first handshake that shows the
fingerprint and the later connection are separate network events, which is why
the approval is bound to the key rather than to the review alone.
