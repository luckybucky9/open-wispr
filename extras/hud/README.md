# openwispr-hud

A tiny always-on-top, click-through voice-reactive badge for open-wispr — visual
feedback the daemon itself doesn't (yet) provide. 64×24 pill at bottom-center:
five bars show a live waveform (red) while the push-to-talk hotkey is held, then a
short "processing" bounce (blue) on release before fading out.

Currently a **standalone sidecar app**, not wired into the daemon:

- Reads the configured hotkey from `~/.config/open-wispr/config.json`
  (`hotkey.keyCode`; keyCode 63 = Globe/fn, detected via `maskSecondaryFn` on
  `flagsChanged`) so it stays in sync with `open-wispr set-hotkey`.
- Watches that key with its own CGEvent tap (needs Input Monitoring) and meters
  levels with its own AVAudioEngine mic session (needs Microphone). It never
  talks to the open-wispr process.
- Modifier-only hotkeys other than fn (e.g. rightoption) aren't handled by the tap.

The long-term intent is to fold this into the daemon's recording lifecycle so the
duplicate event tap, duplicate mic capture, and extra TCC grants disappear.

## Build & run

```sh
./build.sh    # compile, sign, restart the launchd agent
```

Deployed via a launchd agent (`com.lucky9.openwispr-hud`, RunAtLoad + KeepAlive)
pointing at `openwispr-hud.app/Contents/MacOS/openwispr-hud`. Logs to
`/tmp/openwispr-hud.log`. Preview without the daemon: `--demo`.

## Signing — two hard-won rules

1. **Sign with a stable developer identity, not ad-hoc.** TCC pins the
   Microphone and Input Monitoring grants to the signature's designated
   requirement. Ad-hoc signing pins the exact code hash, so every rebuild
   silently invalidates the grants (the badge just stops appearing). A real
   Apple Development cert pins identifier+team, which survives rebuilds.
   Override the default identity with `HUD_SIGN_IDENTITY`.
2. **No hardened runtime** (`--options runtime`). Without the
   `com.apple.security.device.audio-input` entitlement it blocks the mic with
   no prompt: `requestAccess` returns false, the engine runs, and the buffers
   are silent — a flat waveform with no error anywhere.
