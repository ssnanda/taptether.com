# TapTether macOS Screen Core

## Why it is a separate program
macOS Screen Recording consent is tied to the approved executable/code identity.
The regularly updated `taptether-agent` cannot reliably retain consent after
its signed binary changes. Versioned `taptether-screen-core` is a separate
per-user LaunchAgent in `~/.local/bin/`, initially installed once and preserved
during subsequent agent updates, following the Input Core lifecycle.

## Interaction
1. The phone authenticates to the regular agent via paired identity, HTTPS,
   pinned certificate and private-LAN enforcement.
2. The agent alone contacts the Screen Core UNIX socket under
   `~/Library/Application Support/taptether/screen-core` with a local secret.
3. The Core verifies peer UID, executable path, owner and signing team.
4. A single in-memory ScreenCaptureKit frame is returned with bounded metadata
   and bytes. The agent forwards snapshots or the existing MJPEG live stream.
5. No recording files, screen audio, cloud relay or persistent frame cache.

The core owns macOS Screen Recording consent. Input Core continues to own
Accessibility consent; neither executable is overwritten on regular updates.

## First migration on a Mac
- Install / Repair using the new TapTether Agent.app or the phone's macOS SSH
  installer. The existing legacy five-member update tar remains compatible.
- The installer stages the separately signed Screen Core and starts its own
  per-user LaunchAgent. Pairing and Input Core are not reset.
- On the first Snapshot or Live request, open **System Settings → Privacy &
  Security → Screen & System Audio Recording** and allow
  `taptether-screen-core`. A restart of the Screen Core may be necessary.
- After that, regular agent updates keep Screen Core 1.0.0 untouched. An
  explicit `upgrade-screen-core --authorize VERSION` is the only replacement
  path; a replacement might require new macOS consent.

When no Screen Core has been migrated yet, macOS retains the 0.7.0 legacy
agent capture path to avoid breaking existing local setups. If Screen Core has
been installed but is unavailable, the app reports an error rather than
silently requesting capture permission on a new agent executable.

## Release checks
- macOS 14+ screenshot consent grants, denies and revocations on a real user
  desktop; capture the first permission prompt and ensure it names the Core.
- Update the regular agent repeatedly and confirm the Screen Core executable
  hash and Screen Recording entry remain unchanged.
- Exercise 15-second snapshots, post-tap refresh, Live interaction and
  app background cancellation after migration.
- Verify arm64/amd64 binaries, authorized peer checks, one-time SSH staging,
  Finder install and downgrade fallback. Ensure no frames touch the filesystem.
- Keep Screen Core in draft until physical on-device validation completes.
