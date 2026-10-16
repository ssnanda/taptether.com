#!/usr/bin/env bash
# Create a native, double-clickable TapTether Agent.app for each Mac architecture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS/Xcode required.' >&2; exit 1; }
version="$(cat "$ROOT/VERSION")"
core_version="$(cat "$ROOT/INPUT_CORE_VERSION")"
screen_core_version="$(cat "$ROOT/SCREEN_CORE_VERSION")"
signing_identity="${TAPTETHER_CODESIGN_IDENTITY:--}"
trash_build_temp() {
  local path="$1" trash destination
  [[ -d "$path" ]] || return 0
  if /usr/bin/osascript -e 'on run argv' \
      -e 'tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)' \
      -e 'end run' -- "$path" >/dev/null 2>&1; then
    return 0
  fi
  # Finder can be unavailable in a headless Actions runner.
  trash="$HOME/.Trash"
  mkdir -p "$trash"
  destination="$trash/taptether-macos-package.$$.${RANDOM}"
  mv "$path" "$destination"
}
python3 "$ROOT/bin/9-tt-brand-icons.py"
mkdir -p "$ROOT/dist/macos"
for arch in amd64 arm64; do
  "$ROOT/bin/2b-tt-agent.sh" darwin "$arch"
  temp="$(mktemp -d)"
  cp "$ROOT/dist/agents/TapTetherAgent-darwin-$arch-$version" "$temp/taptether-agent"
  (cd "$ROOT/agent" && CGO_ENABLED=1 GOOS=darwin GOARCH="$arch" go build -trimpath \
    -ldflags "-s -w -X main.version=$core_version" \
    -o "$temp/taptether-input-core" ./cmd/taptether-input-core)
  (cd "$ROOT/agent" && CGO_ENABLED=1 GOOS=darwin GOARCH="$arch" go build -trimpath \
    -ldflags "-s -w -X main.version=$screen_core_version" \
    -o "$temp/taptether-screen-core" ./cmd/taptether-screen-core)
  cp "$ROOT/bin/4-macos-agent-setup.sh" "$temp/taptetherctl-mac"
  cp "$ROOT/bin/8-tt-update-macos.sh" "$temp/taptether-agent-update-mac"
  cp "$ROOT/dist/branding/TapTether.icns" "$temp/TapTether.icns"
  codesign --force --sign "$signing_identity" --timestamp=none "$temp/taptether-agent"
  codesign --force --sign "$signing_identity" --timestamp=none "$temp/taptether-input-core"
  codesign --force --sign "$signing_identity" --timestamp=none "$temp/taptether-screen-core"
  case "$arch" in
    amd64) swift_target="x86_64-apple-macos12.0" ;;
    arm64) swift_target="arm64-apple-macos12.0" ;;
  esac
  xcrun swiftc -O -target "$swift_target" \
    "$ROOT/desktop/macos/TapTetherTray.swift" -framework AppKit \
    -o "$temp/TapTetherTray"
  chmod 755 "$temp/taptether-agent" "$temp/taptether-input-core" "$temp/taptether-screen-core" "$temp/taptetherctl-mac" \
    "$temp/taptether-agent-update-mac" "$temp/TapTetherTray"
  bundle="$temp/TapTether Agent.app"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  cp "$temp/TapTetherTray" "$bundle/Contents/MacOS/TapTetherTray"
  cp "$temp/TapTether.icns" "$temp/taptether-agent" \
    "$temp/taptether-input-core" "$temp/taptether-screen-core" \
    "$temp/taptetherctl-mac" "$temp/taptether-agent-update-mac" \
    "$bundle/Contents/Resources/"
  printf '%s\n' "$version" > "$bundle/Contents/Resources/version.txt"
  build="${version##*+}"
  cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.taptether.agent.launcher</string>
<key>CFBundleExecutable</key><string>TapTetherTray</string>
<key>CFBundleIconFile</key><string>TapTether.icns</string>
<key>CFBundleName</key><string>TapTether Agent</string>
<key>CFBundleDisplayName</key><string>TapTether Agent</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version%%+*}</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
  plutil -lint "$bundle/Contents/Info.plist" >/dev/null
  # Personal-use build: no Apple Developer certificate or notarization required
  # to package; Gatekeeper may still ask for explicit user approval to run.
  codesign --force --deep --sign "$signing_identity" --timestamp=none "$bundle"
  # Keep the original five-member archive unchanged so existing v0.6.1
  # agents can upgrade with their strict manifest-checking updater.
  out="$ROOT/dist/macos/TapTetherAgent-macos-$arch-$version.tar.gz"
  COPYFILE_DISABLE=1 tar -czf "$out" -C "$temp" \
    taptether-agent taptetherctl-mac taptether-agent-update-mac \
    TapTether.icns TapTetherTray
  core_out="$ROOT/dist/macos/TapTetherInputCore-macos-$arch-$core_version.tar.gz"
  COPYFILE_DISABLE=1 tar -czf "$core_out" -C "$temp" taptether-input-core
  screen_core_out="$ROOT/dist/macos/TapTetherScreenCore-macos-$arch-$screen_core_version.tar.gz"
  COPYFILE_DISABLE=1 tar -czf "$screen_core_out" -C "$temp" taptether-screen-core
  # Separate Finder-friendly artifact: unzip and open the .app, no Terminal.
  app_zip="$ROOT/dist/macos/TapTetherAgent-macos-$arch-$version.zip"
  ditto -c -k --sequesterRsrc --keepParent "$bundle" "$app_zip"
  # Keep generated .app bundles out of Spotlight after packaging. Build
  # scratch remains recoverable in Trash rather than being permanently deleted.
  trash_build_temp "$temp"
  echo "Compatible macOS agent archive: $out"
  echo "Versioned macOS Input Core archive: $core_out"
  echo "Versioned macOS Screen Core archive: $screen_core_out"
  echo "Double-clickable macOS app ZIP: $app_zip"
done
for old in "$ROOT"/dist/macos/TapTetherAgent-macos-*.tar.gz "$ROOT"/dist/macos/TapTetherAgent-macos-*.zip; do
  [[ -f "$old" ]] || continue
  case "$(basename "$old")" in
    "TapTetherAgent-macos-amd64-$version.tar.gz"|"TapTetherAgent-macos-arm64-$version.tar.gz"|"TapTetherAgent-macos-amd64-$version.zip"|"TapTetherAgent-macos-arm64-$version.zip") ;;
    *) rm -f "$old" ;;
  esac
done
for old in "$ROOT"/dist/agents/TapTetherAgent-darwin-*; do
  [[ -f "$old" ]] || continue
  case "$(basename "$old")" in
    "TapTetherAgent-darwin-amd64-$version"|"TapTetherAgent-darwin-arm64-$version") ;;
    *) rm -f "$old" ;;
  esac
done
