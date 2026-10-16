#!/usr/bin/env python3
"""Cheap source-level invariants for the split macOS Input Core lifecycle."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETUP = (ROOT / "bin/4-macos-agent-setup.sh").read_text()
BUILD = (ROOT / "bin/2b-tt-macos.sh").read_text()
TRAY = (ROOT / "desktop/macos/TapTetherTray.swift").read_text()
UPDATER = (ROOT / "bin/8-tt-update-macos.sh").read_text()
CLEANUP = (ROOT / "bin/4-clean-macos-review-apps.sh").read_text()
PUBLISH = (ROOT / "bin/6-tt-publish-latest.sh").read_text()

assert '[[ -x "$CORE" && -z "$requested" ]]' in SETUP
assert 'Preserved TapTether Input Core' in SETUP
assert 'upgrade-core)' in SETUP and '--authorize' in SETUP
assert 'com.taptether.input-core' in SETUP
assert 'ipc.token' in SETUP and 'chmod 600' in SETUP
assert 'launchctl bootout "$TARGET/$CORE_LABEL"' in SETUP
assert 'taptether-input-core' in BUILD
assert 'TapTetherInputCore-macos-' in BUILD
assert 'taptether-input-core' not in UPDATER  # routine updater is agent-only
assert 'taptether-input-core' in TRAY
assert 'coreRemaining' in TRAY
assert 'CANONICAL="$HOME/Applications/TapTether Agent.app"' in CLEANUP
assert "find \"$ROOT/dist\" -type d -name '*.app'" in CLEANUP
assert 'delete (POSIX file' in CLEANUP and 'rm -rf' not in CLEANUP
assert 'bash "$ROOT/bin/4-clean-macos-review-apps.sh"' in PUBLISH
# Stable Screen Core is an independent signed process and socket:
# no new macOS Screen Recording prompts on normal agent binary updates.
SCREEN = (ROOT / "agent" / "cmd" / "taptether-screen-core" / "main.go").read_text()
SCREEN_PROXY = (ROOT / "agent" / "cmd" / "taptether-agent" / "screen_capture_darwin.go").read_text()
SCREEN_VERSION = (ROOT / "SCREEN_CORE_VERSION").read_text().strip()
MAC_STAGE = (ROOT / "bin" / "2e-tt-stage-mobile-agents.sh").read_text()
MAC_SSH = (ROOT / "app" / "lib" / "macos_ssh_provisioner.dart").read_text()
assert SCREEN_VERSION == "1.0.0"
assert "LOCAL_PEERPID" in SCREEN and "getpeereid" in SCREEN
assert "codesign" in SCREEN and "verifySigningPeer" in SCREEN
assert "subtle.ConstantTimeCompare" in SCREEN
assert "screencap.Capture()" in SCREEN
assert "taptether-screen-core" in SCREEN_PROXY
assert "captureScreenFrame" in (ROOT / "agent" / "cmd" / "taptether-agent" / "screen_http.go").read_text()
assert "Preserved TapTether Screen Core" in SETUP
assert "com.taptether.screen-core" in SETUP
assert "upgrade-screen-core" in SETUP
assert "taptether-screen-core" in BUILD
assert "taptether-screen-core" not in UPDATER
assert "screenCores" in MAC_STAGE and "screenCores" in MAC_SSH
assert "coreArchive" in MAC_SSH and "sha256.convert(coreArchive)" in MAC_SSH

print("PASS: stable Input Core preservation, explicit upgrade, migration, diagnostics,")
print("      complete Quit, agent-only updates, and review-app cleanup invariants")
