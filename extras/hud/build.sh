#!/bin/bash
# Build + sign openwispr-hud.
#
# IMPORTANT: sign with the stable Apple Development identity, NOT ad-hoc (`-`).
# TCC pins Input Monitoring + Microphone to the code signature's designated
# requirement. Ad-hoc signing pins the exact code hash, so every rebuild breaks
# the grants and you have to re-authorize in System Settings. Signing with the
# Apple Development cert pins identifier+team, which survives rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${HUD_SIGN_IDENTITY:-Apple Development: Lakshya Bakshi (GBS93G3H9L)}"
APP="openwispr-hud.app"
BIN="$APP/Contents/MacOS/openwispr-hud"

echo "› compiling…"
swiftc -O main.swift -o "$BIN"

echo "› signing as: $IDENTITY"
# NOTE: no --options runtime. Hardened runtime blocks the microphone without the
# com.apple.security.device.audio-input entitlement; this is a local tool so we
# skip hardened runtime entirely. The stable identity still comes from the cert.
codesign --force --sign "$IDENTITY" --identifier com.lucky9.openwispr-hud "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier" | head -2

echo "› restarting launchd agent…"
launchctl kickstart -k "gui/$(id -u)/com.lucky9.openwispr-hud" 2>/dev/null || true
echo "✓ done. log: /tmp/openwispr-hud.log"
