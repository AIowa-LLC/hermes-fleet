#!/bin/bash
# t_eb5455f2: final secret scan on staged changes before commit.
set -u
cd <repo-root> || exit 1
echo "=== [1] scan staged diff for credential-like values ==="
git diff --cached | grep -nE "BEGIN (RSA |OPENSSH |EC )|PRIVATE KEY|api[_-]?key\s*[:=]|secret\s*[:=]|password\s*[:=]\s*['\"][^'\"]{6,}|username\s*[:=]\s*['\"][a-z0-9]{6,}|token\s*[:=]\s*['\"][A-Za-z0-9_-]{12,}|hermes_session_at=" | grep -viE "hermes_session_at=at-123|sessionToken: String\?|func .*password|forHTTPHeaderField: \"X-Hermes|\.cred|readCreds|passwordText|usernameText|hasPrefix\(\"password|hasPrefix\(\"username|sessionCookie: sessionCookie|password: credential" | head -20 || echo "  (no credential-like values in staged diff)"

echo "=== [2] confirm .cred values are NOT in the repo ==="
if git diff --cached | grep -qE "$(sed -n 's/^password=//p' /tmp/hermes_lan_surface/.cred 2>/dev/null | head -c 12)"; then
  echo "  WARNING: password value found in staged diff!"
else
  echo "  OK: no .cred password value in staged diff"
fi
echo "=== Done ==="
