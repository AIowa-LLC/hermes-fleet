## Summary

<!-- What changed and why? -->

## Validation

- [ ] `xcodegen generate`
- [ ] Relevant Swift/package tests
- [ ] `bash scripts/public_safety_guard.sh`
- [ ] `gitleaks detect --source . --no-git`
- [ ] App/UI validation where applicable

## Privacy and security

- [ ] No credentials, tokens, private endpoints, device identifiers, private IPs, hostnames, or personal filesystem paths are included.
- [ ] Live gateway/device checks are optional and are not required for ordinary CI.
- [ ] Security-sensitive changes follow `SECURITY.md`.

## Notes

<!-- Mention limitations, follow-up work, or screenshots. -->
