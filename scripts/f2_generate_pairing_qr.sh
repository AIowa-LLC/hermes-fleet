#!/bin/bash
# f2_generate_pairing_qr.sh — F2 gateway-side pairing QR (v1 payload).
#
# Renders the QR that the Hermes Fleet iOS app's "Scan Pairing Code" button
# consumes. One invocation = one short-lived pairing code:
#
#   SECRET=$(openssl rand -hex 21)   # 42-char scoped pairing secret
#   bash scripts/f2_generate_pairing_qr.sh http://YOUR-GATEWAY:8642 fleet-operator "$SECRET"
#
# SECURITY (F2 card):
#   - The QR is credential material on screen. Generate a FRESH scoped
#     credential per pairing (never reuse), show the QR only on explicit user
#     action (this script IS that action), and revoke the credential after
#     the phone has paired.
#   - The payload is built by scripts/f2_pairing_payload.swift (same shape +
#     escaping as FleetCore PairingPayload.encoded()) and piped straight to
#     the renderer; it is never echoed to the terminal or written to disk.
#   - Terminal display uses `qrencode -t ANSIUTF8` when installed; otherwise
#     a CoreImage renderer writes a PNG to a temp dir opened in Preview
#     (deleted on script exit).
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/f2_generate_pairing_qr.sh <gateway-url> <username> <password>
USAGE
  exit 64
}

[ "$#" -eq 3 ] || usage
URL="$1"; USER="$2"; PASS="$3"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PAYLOAD="$(swift "$REPO_ROOT/scripts/f2_pairing_payload.swift" "$URL" "$USER" "$PASS")"

if command -v qrencode >/dev/null 2>&1; then
  echo "Hermes Fleet — gateway pairing QR (scan with the app's 'Scan Pairing Code')"
  echo "Endpoint: $URL   User: $USER"
  echo
  printf '%s' "$PAYLOAD" | qrencode -t ANSIUTF8 -m 2
  echo
  echo "This code carries the pairing credential — regenerate per pairing; revoke after use."
  exit 0
fi

TMP_DIR="$(mktemp -t hermes_pairing)"
TMP_PNG="$TMP_DIR/qr.png"
swift - "$PAYLOAD" "$TMP_PNG" <<'SWIFT'
import Foundation
import CoreImage.CIFilterBuiltins
import AppKit

let args = CommandLine.arguments
let text = args[1], outPath = args[2]
let filter = CIFilter.qrCodeGenerator()
filter.message = Data(text.utf8)
filter.correctionLevel = "M"
guard let output = filter.outputImage else { exit(1) }
let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
let context = CIContext()
guard let cg = context.createCGImage(scaled, from: scaled.extent) else { exit(1) }
let rep = NSBitmapImageRep(cgImage: cg)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: outPath))
SWIFT
echo "QR written to $TMP_PNG (opening in Preview; deleted when this script exits)"
open -a Preview "$TMP_PNG" || open "$TMP_PNG"
trap 'rm -rf "$TMP_DIR"' EXIT
sleep 5
