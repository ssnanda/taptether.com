#!/usr/bin/env bash
# Explicit update check/installation for installed macOS TapTether LaunchAgent.
set -euo pipefail
MODE="$1"
[[ "$MODE" == check || "$MODE" == update ]] || { echo 'Usage: taptether-agent-update-mac {check|update}' >&2; exit 2; }
command -v python3 >/dev/null || { echo 'Python 3 required' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl required' >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS only' >&2; exit 1; }
arch="$(uname -m)"
case "$arch" in x86_64) arch=amd64;; arm64) ;; *) echo "Unsupported Mac: $arch" >&2; exit 1;; esac
bin="$HOME/.local/bin/taptether-agent"
current="$("$bin" --version 2>/dev/null || echo 0.0.0+0)"
info="$(python3 - "$arch" "$current" <<'PY'
import json, re, sys, urllib.error, urllib.request
arch, installed = sys.argv[1:]
repo = "ssnanda/taptether.com"
def parts(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)\+(\d+)", v)
    if not m: raise SystemExit("Invalid TapTether version: " + v)
    return tuple(int(x) for x in m.groups())
def fetch(tag):
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/tags/{tag}",
        headers={"Accept": "application/vnd.github+json",
                 "User-Agent": "TapTether-macOS-Updater"})
    with urllib.request.urlopen(req, timeout=12) as response:
        return json.load(response)
def verify(data, tag):
    if data.get("tag_name") != tag:
        raise SystemExit("Unexpected release tag")
    match = re.match(r"^TapTether(?: macOS)? (\d+\.\d+\.\d+\+\d+)(?:\s|$)", data.get("name", ""))
    if not match: raise SystemExit(f"{tag}: version metadata unavailable")
    name = f"TapTetherAgent-macOS-{arch}.tar.gz"
    assets = [a for a in data.get("assets", []) if a.get("name") == name]
    if len(assets) != 1: raise SystemExit(f"{tag}: expected agent archive missing")
    asset = assets[0]
    digest = asset.get("digest", "")
    if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
        raise SystemExit(f"{tag}: invalid SHA-256")
    url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
    if asset.get("browser_download_url") != url:
        raise SystemExit(f"{tag}: unexpected asset URL")
    return match.group(1), digest[7:].lower(), url
options = [verify(fetch("current"), "current")]
try:
    options.append(verify(fetch("macos-current"), "macos-current"))
except urllib.error.HTTPError as exc:
    if exc.code != 404: raise
latest, digest, url = max(options, key=lambda item: parts(item[0]))
print("\t".join((latest, "yes" if parts(latest) > parts(installed) else "no", digest, url)))
PY
)"
IFS=$'\t' read -r latest newer digest url <<<"$info"
printf 'TapTether Mac installed: %s | latest published: %s\n' "$current" "$latest"
if [[ "$newer" != yes ]]; then echo 'Already up to date.'; exit 0; fi
if [[ "$MODE" == check ]]; then echo 'Update available. Run taptetherctl-mac update.'; exit 0; fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
archive="$tmp/mac-agent.tar.gz"
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --connect-timeout 12 --max-time 180 --retry 2 "$url" -o "$archive"
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$digest" ]] || { echo 'SHA-256 mismatch; aborting' >&2; exit 1; }
# Permit only five expected installer members. Never extract arbitrary paths.
members="$(tar -tzf "$archive" | LC_ALL=C sort)"
expected="$(printf '%s\n' TapTether.icns TapTetherTray taptether-agent taptether-agent-update-mac taptetherctl-mac | LC_ALL=C sort)"
[[ "$members" == "$expected" ]] || { echo 'Unexpected archive files; aborting' >&2; exit 1; }
tar -xzf "$archive" -C "$tmp"
chmod 700 "$tmp/taptetherctl-mac"
chmod 755 "$tmp/taptether-agent" "$tmp/TapTetherTray"
echo "Verified macOS archive SHA-256. Installing $latest..."
"$tmp/taptetherctl-mac" install
