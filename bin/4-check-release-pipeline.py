#!/usr/bin/env python3
"""Static checks for TapTether's single gated automatic/manual workflow."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
folder = ROOT / ".github" / "workflows"
workflow_files = sorted(folder.glob("*.yml")) + sorted(folder.glob("*.yaml"))
assert len(workflow_files) == 1 and workflow_files[0].name == "taptether.yml", (
    "Expected exactly one maintained Actions workflow: taptether.yml"
)

workflow = workflow_files[0].read_text(encoding="utf-8")
publisher = (ROOT / "bin" / "6-tt-publish-latest.sh").read_text(encoding="utf-8")
stage = (ROOT / "bin" / "2e-tt-stage-mobile-agents.sh").read_text(encoding="utf-8")

assert "workflow_dispatch:" in workflow
assert "schedule:" in workflow
assert "task:" in workflow
assert all(f"- {mode}" in workflow for mode in ("release", "build", "validate"))
assert "          - cleanup" not in workflow
assert "  push:\n    branches: [main, fix/v0.6-remote-scan-mac-details]" in workflow, (
    "Main production releases and explicit branch-only Windows validation"
)
assert "github.ref == 'refs/heads/main'" in workflow
assert "    paths:\n      - VERSION" in workflow, (
    "Automatically run releases only for explicit VERSION changes"
)
assert "github.event_name == 'push' || inputs.task == 'release'" in workflow

assert "  validate:" in workflow
assert "  build-ubuntu:" in workflow
assert "    needs: validate" in workflow
assert "github.event_name == 'push' || inputs.task == 'release' || inputs.task == 'build'" in workflow
assert "  build-and-publish:" in workflow
assert "    needs: [build-ubuntu, build-windows]" in workflow
assert "  build-windows:" in workflow
assert "run: bash bin/2c-tt-windows.sh" in workflow
# All scripts invoked directly by a release build must have an executable
# Git mode; bash-invoked scripts are permitted to be non-executable.
for script in (
    "bin/2b-tt-agent.sh",
    "bin/2b-tt-ubuntu.sh",
    "bin/2b-tt-deb.sh",
    "bin/2b-tt-macos.sh",
    "bin/2e-tt-stage-mobile-agents.sh",
):
    assert (ROOT / script).stat().st_mode & 0o111, (
        f"{script} must be executable in Git; check chmod +x"
    )
ubuntu_builder = (ROOT / "bin" / "2b-tt-ubuntu.sh").read_text(encoding="utf-8")
assert 'bash "$ROOT/bin/2b-tt-deb.sh"' in ubuntu_builder, (
    "Invoke the Debian package builder via bash to avoid exit 126"
)

provisioner = (ROOT / "app" / "lib" / "ssh_provisioner.dart").read_text(encoding="utf-8")
deb_builder = (ROOT / "bin" / "2b-tt-deb.sh").read_text(encoding="utf-8")
assert 'dpkg --install' in provisioner, (
    "Install private-mode staged Ubuntu packages directly with dpkg"
)
assert 'apt-get install -y --no-install-recommends' not in provisioner, (
    "Never hand inaccessible private-mode staged packages to _apt"
)
assert "'Suggests: xdotool" in deb_builder
assert "'Depends: xdotool" not in deb_builder

assert "Verify Ubuntu packages with native dpkg" in workflow
assert 'sudo dpkg --install "dist/ubuntu/taptether-agent_' in workflow
assert "dpkg-deb --info" in workflow

assert "python3 bin/4-test-deb-packaging.py" in workflow, (
    "Run offline Debian payload regression test before expensive agent builds"
)
assert "python3 bin/4-test-macos-uninstall.py" in workflow, (
    "Run safe macOS uninstall regression test before builds"
)
assert "python3 bin/4-test-macos-input-core.py" in workflow
assert "run: bash bin/2b-tt-ubuntu.sh" in workflow
assert "run: bash bin/2b-tt-macos.sh" in workflow
assert "run: bash bin/2a-tt-ipa.sh --no-publish" in workflow
assert "run: bash bin/2a-tt-apk.sh --no-publish" in workflow
assert "run: bash bin/6-tt-publish-latest.sh" in workflow
assert "if: ${{ (github.event_name == 'push' && github.ref == 'refs/heads/main') || inputs.task == 'release' }}" in workflow
assert "if: ${{ inputs.task == 'build' }}" in workflow
assert "TapTether-complete-build-" in workflow
assert "retention-days: 1" in workflow

assert "name: TapTether-Ubuntu-installers" in workflow
assert "actions/download-artifact@" in workflow
assert "TAPTETHER_USE_PREBUILT_AGENTS: '1'" in workflow
assert "TAPTETHER_USE_PREBUILT_AGENTS:-0" in stage
assert "gh release create \"$VERSION_TAG\"" in publisher
# A concurrent VERSION bump must not fail a completed binary release or roll
# an older altstore.json over a newer version.
assert 'git show origin/main:VERSION' in publisher
assert 'git worktree add --quiet --detach' in publisher
assert 'git -C "$FEED_WORKTREE" push origin HEAD:main' in publisher
assert 'if [[ "$remote_version" != "$VERSION" ]]; then' in publisher
assert 'git push origin HEAD:main' not in publisher
assert "--latest=false" in publisher
assert "expected_assets=(" in publisher
assert "already published" in publisher
assert "release-v0.6.2-request" not in workflow

assert "  cleanup-history:" in workflow
assert "    needs: build-and-publish" in workflow
assert "always() && (github.event_name == 'schedule'" in workflow
assert "inputs.task == 'cleanup'" not in workflow
assert "needs.build-and-publish.result == 'success'" in workflow

# Regression guards: the Mac Finder installer must report and recover from
# launchd failures without copying raw pairing details or logs.
mac_setup = (ROOT / "bin" / "4-macos-agent-setup.sh").read_text(encoding="utf-8")
mac_tray = (ROOT / "desktop" / "macos" / "TapTetherTray.swift").read_text(
    encoding="utf-8")
assert "diagnostics) diagnostics" in mac_setup
assert 'uninstall) uninstall_agent "${2:-}"' in mac_setup
assert 'trash_path "$TRAY_BUNDLE"' in mac_setup
assert 'trash_path "$CONF"' in mac_setup
assert 'codesign --verify "$APP"' in mac_setup
assert "Repair Accessibility…" in mac_tray
assert "Uninstall TapTether…" in mac_tray
assert 'add(menu, "Quit TapTether", #selector(quitMenu))' in mac_tray
assert 'task.arguments = [controller, "stop"]' in mac_tray
assert 'coreRemaining' in mac_tray
assert "Quit menu (agent stays running)" not in mac_tray
assert 'erase ? "--erase-pairing" : "--keep-pairing"' in mac_tray
assert "restart) start_agent" in mac_setup
assert "launchctl bootstrap" in mac_setup
assert "Privacy: no passwords, pairing tokens" in mac_setup
# Regression: a running macOS updater was truncated by the installer using
# cp directly over its live script. Require same-directory rename instead.
assert "atomic_install_helper" in mac_setup
assert 'mv -f "$staged" "$destination"' in mac_setup
assert 'atomic_install_helper "$0" "$CTL" 755' in mac_setup
assert 'atomic_install_helper "$SELF/taptether-agent-update-mac" "$UPDATER" 700' in mac_setup
assert 'then cp "$0" "$CTL"' not in mac_setup
assert "  pairing\n}" not in mac_setup  # no private token printed on updates
assert "Copy diagnostics" in mac_tray
assert "Open Accessibility settings" in mac_tray

# All desktop tray menus must perform updates, not merely display a CLI hint.
ubuntu_tray = (ROOT / "desktop" / "ubuntu" / "taptether_tray.py").read_text(
    encoding="utf-8")
win_tray = (ROOT / "desktop" / "windows" / "TapTetherTray.ps1").read_text(
    encoding="utf-8")
win_installer = (ROOT / "desktop" / "windows" / "Install-TapTether.ps1").read_text(
    encoding="utf-8")
win_updater = (ROOT / "desktop" / "windows" / "Update-TapTether.ps1").read_text(
    encoding="utf-8")
assert 'title: "Check for Updates…"' in mac_tray
assert 'task.arguments = [controller, "update"]' in mac_tray
assert 'task.standardOutput = FileHandle.nullDevice' in mac_tray
assert "update_from_tray" in ubuntu_tray
assert 'add_menu_item(m, "Check for Updates…", update_from_tray)' in ubuntu_tray
assert 'taptether-update.service' in ubuntu_tray
assert "Check for Updates..." in win_tray
assert "Update-TapTether.ps1" in win_tray
assert "TapTetherTray.ps1" in win_installer and "TapTetherTray.ps1" in win_updater
assert "TapTetherTray.ps1" in workflow
assert "PowerShell syntax" in workflow
# Every desktop has one dynamic Start/Stop, Pair, Update, Settings and Quit.
assert 'startStopItem?.title = isRunning ? "Stop TapTether" : "Start TapTether"' in mac_tray
assert 'add(menu, "Pair Device", #selector(pairingInstructions))' in mac_tray
assert 'let settingsMenu = NSMenu(title: "Settings")' in mac_tray
assert 'add(menu, "Quit TapTether", #selector(quitMenu))' in mac_tray
assert 'start_stop.set_label("Stop TapTether" if active else "Start TapTether")' in ubuntu_tray
assert 'add_menu_item(m, "Pair Device", pair_device)' in ubuntu_tray
assert 'settings_item.set_submenu(settings)' in ubuntu_tray
assert 'add_menu_item(m, "Quit TapTether", quit_taptether)' in ubuntu_tray
assert 'if service_control("stop"):' in ubuntu_tray
assert '$startStopItem.Text = if ($isRunning)' in win_tray
assert "$pairingItem = $menu.Items.Add('Pair Device')" in win_tray
assert "$settingsItem = [System.Windows.Forms.ToolStripMenuItem]::new('Settings')" in win_tray
assert "$quitItem = $menu.Items.Add('Quit TapTether')" in win_tray
assert 'if (Stop-ManagedAgent)' in win_tray

# DHCP recovery must not depend only on UDP discovery or Bonjour. An
# untrusted open port is authenticated using the stored pinned phone pairing.
recovery = (ROOT / "app" / "lib" / "device_recovery.dart").read_text(
    encoding="utf-8")
mobile = (ROOT / "app" / "lib" / "main.dart").read_text(encoding="utf-8")
assert "probeAgentControlPorts" in recovery
assert "Socket.connect(ip, 48321" in recovery
assert "_pingSavedDevice(device, phone, atHost: ip)" in mobile
assert "forceRecovery: true" in mobile

# Explicit Scan IPs/Discover must reconcile saved computers immediately.
# Background agents never need to poll the phone.
scan_screen = (ROOT / "app" / "lib" / "lan_scan_screen.dart").read_text(encoding="utf-8")
scan_logic = (ROOT / "app" / "lib" / "lan_scan.dart").read_text(encoding="utf-8")
mobile = (ROOT / "app" / "lib" / "main.dart").read_text(encoding="utf-8")
assert "verifyPairedAgent: _reconcileScannedAgent" in mobile
assert "Future<String?> _reconcileScannedAgent" in mobile
assert "await _pingSavedDevice(saved, phone, atHost: ip)" in mobile
assert "await deviceStore.upsert(verified)" in mobile
assert "_reconcileDiscoveredAgents(result)" in mobile
assert "onAgentFound: _showAgentCandidate" in scan_screen
assert "await Future.wait(_pendingVerifications)" in scan_screen
assert "onAgentFound?.call(candidate)" in scan_logic

# Guard against regressing the broken 0.6.7 remote class and F-key parser.
remote = (ROOT / "app" / "lib" / "main.dart").read_text(encoding="utf-8")
assert remote.count("Widget _connectedControls()") == 1
assert remote.count("Widget build(BuildContext context)") == 2
assert "if (RegExp(r'^f(?:[1-9]|1[0-2])$').hasMatch(id)) return id;" in remote
assert "}).hasMatch(id)) return id;" not in remote

# Presentation mode shares only authenticated LAN keyboard commands; no
# screen-reading or note capture is part of the 0.6.9 feature.
presentation = (ROOT / "app" / "lib" / "presentation_mode.dart").read_text(
    encoding="utf-8")
layout = (ROOT / "app" / "lib" / "remote_layout_settings.dart").read_text(
    encoding="utf-8")
assert 'Widget _immersiveLandscapeRemote()' in remote
assert "MediaQuery.orientationOf(context) == Orientation.landscape" in remote
assert "ValueKey('landscape-keyboard')" in remote
assert "Keyboard & shortcuts" in remote
assert "keyboardExpanded" in layout
assert 'MediaQuery.orientationOf(context) == Orientation.landscape' in remote
assert 'Widget _presentationView(bool landscape)' in remote
assert 'SegmentedButton<String>' in remote
assert "value: 'presentation'" in remote and "value: 'media'" in remote
assert 'PresentationShortcuts.start' in presentation
assert "static const next = 'Right';" in presentation
assert "static const previous = 'Left';" in presentation
assert "static const stop = 'Escape';" in presentation
assert "static const blankToggle = 'b';" in presentation
assert "this.presentationMode = false" in layout
assert "this.presentationApp = 'powerPoint'" in layout

# Dashboard/discovery release guards. A previously hard-coded home subnet
# must not silently return through either the scanner or device installer.
lan = (ROOT / "app" / "lib" / "lan_scan.dart").read_text(encoding="utf-8")
scan_screen = (ROOT / "app" / "lib" / "lan_scan_screen.dart").read_text(encoding="utf-8")
installer = (ROOT / "app" / "lib" / "install_agent_screen.dart").read_text(encoding="utf-8")
devices = (ROOT / "app" / "lib" / "device_visibility.dart").read_text(encoding="utf-8")
agent_main = (ROOT / "agent" / "cmd" / "taptether-agent" / "main.go").read_text(
    encoding="utf-8")
assert "rangeFromWifi(" in lan and "getWifiSubmask()" in lan
assert "lanRangeContains(" in lan
assert "_network!.scanPrefixes" in scan_screen
assert "InstallAgentScreen" in installer and "Computer OS" in installer
assert "knownPlatform" in installer and "Download Windows agent" in installer
assert "visibleSavedDevices(" in devices and "showOffline" in devices
assert "Timer.periodic(const Duration(seconds: 60)" in remote
assert "RefreshHeartbeats" not in remote or "_refreshHeartbeats()" in remote
assert "'hostname'" not in agent_main or '"hostname": hostname' in agent_main
assert '"platform": runtime.GOOS' in agent_main
assert "deviceLocations" in remote and "NetworkLocationStore" in remote

# macOS and Ubuntu install/update are performed from the phone using
# checksum-verified same-build assets and per-host trusted SSH identities.
mac_ssh = (ROOT / "app" / "lib" / "macos_ssh_provisioner.dart").read_text(
    encoding="utf-8")
ssh_ui = (ROOT / "app" / "lib" / "ubuntu_install_screen.dart").read_text(
    encoding="utf-8")
device_manager = (ROOT / "app" / "lib" / "device_manager_screen.dart").read_text(
    encoding="utf-8")
assert "MacSshProvisioner" in mac_ssh
assert "sha256.convert(archive)" in mac_ssh
assert "rememberAuthenticated(input.host" in mac_ssh
assert "updateOnly" in mac_ssh and "updateOnly" in provisioner
assert "macosPairingFromOutput" in mac_ssh
assert "MacSshProvisioner.install" in ssh_ui
assert "UbuntuSshProvisioner.install" in ssh_ui
assert "Update Agent" in device_manager
assert "onUpdate: updateSavedAgent" in remote
assert "requestUpdate()" in remote
assert "updateSavedAgent" in remote
assert "macos" in stage and 'TapTetherAgent-macos-' in stage
mac_test = (ROOT / "app" / "test" /
    "macos_ssh_provisioner_test.dart").read_text(encoding="utf-8")
assert "macosPairingFromOutput" in mac_test
assert "macosArchiveArchitecture" in mac_test
assert "mergeDiscoveredAgents(" in lan
assert "checkPrivateLanIp(" in lan
assert "device.scanSubtitle" in scan_screen
assert "Check a specific computer" in scan_screen


print("PASS: one Actions workflow, auto Release on VERSION, three manual choices")
print("PASS: validate -> Ubuntu/Windows/macOS agents -> IPA/APK -> publish")
print("PASS: weekly cleanup and immutable version-tagged Latest releases")
