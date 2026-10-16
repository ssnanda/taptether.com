#!/usr/bin/env bash
# Publish only the current version's IPA, APK and agent installers to one rolling release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO=ssnanda/taptether.com
TAG=current
VERSION="$(cat VERSION)"
STAGE="$ROOT/dist/release"
command -v gh >/dev/null 2>&1 || { echo 'GitHub CLI is required: brew install gh; gh auth login' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 required' >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'Sign in with gh auth login (or set GH_TOKEN in CI)' >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo 'Publish only from main.' >&2; exit 1; }
[[ "$(git remote get-url origin)" == *ssnanda/taptether.com* ]] || { echo 'Refusing unknown Git origin.' >&2; exit 1; }
mkdir -p "$STAGE"
# The stable release folder never retains earlier versions.
find "$STAGE" -maxdepth 1 -type f -name 'TapTether*' -delete
IPA="$ROOT/dist/ios/TapTether-$VERSION-unsigned.ipa"
if [[ -s "$ROOT/dist/ios/TapTether-$VERSION.ipa" ]]; then
  IPA="$ROOT/dist/ios/TapTether-$VERSION.ipa"
fi
HAS_IPA=0
if [[ -s "$IPA" ]]; then
  cp "$IPA" "$STAGE/TapTether.ipa"
  HAS_IPA=1
fi
APK="$ROOT/dist/android/TapTether-$VERSION.apk"
if [[ -s "$APK" ]]; then cp "$APK" "$STAGE/TapTether.apk"; fi
for ARCH in amd64 arm64; do
  DEB="$(printf '%s/dist/ubuntu/taptether-agent_%s_%s.deb' "$ROOT" "$VERSION" "$ARCH")"
  MAC="$(printf '%s/dist/macos/TapTetherAgent-macos-%s-%s.tar.gz' "$ROOT" "$ARCH" "$VERSION")"
  MAC_APP="$(printf '%s/dist/macos/TapTetherAgent-macos-%s-%s.zip' "$ROOT" "$ARCH" "$VERSION")"
  CORE_VERSION="$(cat "$ROOT/INPUT_CORE_VERSION")"
  SCREEN_CORE_VERSION="$(cat "$ROOT/SCREEN_CORE_VERSION")"
  MAC_CORE="$(printf '%s/dist/macos/TapTetherInputCore-macos-%s-%s.tar.gz' "$ROOT" "$ARCH" "$CORE_VERSION")"
  if [[ -s "$DEB" ]]; then cp "$DEB" "$STAGE/TapTetherAgent-Ubuntu-$ARCH.deb"; fi
  if [[ -s "$MAC" ]]; then cp "$MAC" "$STAGE/TapTetherAgent-macOS-$ARCH.tar.gz"; fi
  if [[ -s "$MAC_APP" ]]; then cp "$MAC_APP" "$STAGE/TapTetherAgent-macOS-$ARCH.zip"; fi
  if [[ -s "$MAC_CORE" ]]; then cp "$MAC_CORE" "$STAGE/TapTetherInputCore-macOS-$ARCH.tar.gz"; fi
  MAC_SCREEN="$ROOT/dist/macos/TapTetherScreenCore-macos-$ARCH-$SCREEN_CORE_VERSION.tar.gz"
  if [[ -s "$MAC_SCREEN" ]]; then cp "$MAC_SCREEN" "$STAGE/TapTetherScreenCore-macOS-$ARCH.tar.gz"; fi
  WIN="$ROOT/dist/windows/TapTetherAgent-Windows-$ARCH-$VERSION.zip"
  if [[ -s "$WIN" ]]; then cp "$WIN" "$STAGE/TapTetherAgent-Windows-$ARCH.zip"; fi
done
if [[ "$HAS_IPA" -eq 1 ]]; then
  python3 "$ROOT/bin/6-tt-generate-altstore.py" \
    --ipa "$STAGE/TapTether.ipa" --version-file "$ROOT/VERSION" \
    --output "$ROOT/altstore.json" --icon-output "$STAGE/TapTether-icon.png"
else
  echo 'No current-version IPA found. Skipping altstore.json refresh.'
fi
# Never call this a successful release with missing or mixed-version assets.
# All required files must be produced by the verified agent + mobile jobs.
expected_assets=(
  TapTether-icon.png TapTether.ipa TapTether.apk
  TapTetherAgent-Ubuntu-amd64.deb TapTetherAgent-Ubuntu-arm64.deb
  TapTetherAgent-macOS-amd64.tar.gz TapTetherAgent-macOS-arm64.tar.gz
  TapTetherAgent-macOS-amd64.zip TapTetherAgent-macOS-arm64.zip
  TapTetherInputCore-macOS-amd64.tar.gz TapTetherInputCore-macOS-arm64.tar.gz
  TapTetherScreenCore-macOS-amd64.tar.gz TapTetherScreenCore-macOS-arm64.tar.gz
  TapTetherAgent-Windows-amd64.zip TapTetherAgent-Windows-arm64.zip
)
for asset in "${expected_assets[@]}"; do
  [[ -s "$STAGE/$asset" ]] || {
    echo "Missing required release artifact: $asset" >&2
    exit 1
  }
done
asset_count="$(find "$STAGE" -maxdepth 1 -type f -name 'TapTether*' | wc -l | tr -d ' ')"
[[ "$asset_count" -eq "${#expected_assets[@]}" ]] || {
  echo "Expected exactly ${#expected_assets[@]} TapTether release assets; found $asset_count." >&2
  exit 1
}
# Validation has completed before this release job runs. Remove any extracted
# project-local review bundles so Spotlight sees only the canonical install.
bash "$ROOT/bin/4-clean-macos-review-apps.sh"
VERSION_TAG="v$VERSION"
if gh release view "$VERSION_TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "$VERSION_TAG is already published; bump VERSION to publish another build." >&2
  exit 1
fi
# A unique release is genuinely created when this version is built, so GitHub
# displays its correct publication timestamp. Keep current as a compatibility
# alias for AltStore and existing auto-updaters (their URLs never change).
PUBLISHED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
SOURCE_SHA="$(git rev-parse HEAD)"
NOTES="TapTether $VERSION — build checks completed; publication started $PUBLISHED_AT (UTC).
Source commit: $SOURCE_SHA
Build workflow: https://github.com/$REPO/actions/runs/${GITHUB_RUN_ID:-manual}
All native agents were built and verified before IPA/APK publication.
Unsigned iOS IPA requires AltStore signing."
echo "Publishing new, timestamped release: $VERSION_TAG"
files=()
for asset in "${expected_assets[@]}"; do files+=("$STAGE/$asset"); done
gh release create "$VERSION_TAG" "${files[@]}" -R "$REPO" \
  --target "$SOURCE_SHA" --title "TapTether $VERSION" \
  --notes "$NOTES" --latest
echo "Timestamped latest release: https://github.com/$REPO/releases/tag/$VERSION_TAG"

# Keep the current stable asset URLs used by old clients. Its historical
# published_at timestamp is NOT updated by editing: only the unique version
# release above should receive GitHub's Latest label and fresh date.
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release edit "$TAG" -R "$REPO" --title "TapTether $VERSION (rolling downloads)" \
    --notes "$NOTES" --latest=false
  while IFS=' ' read -r ID NAME; do
    if [[ "$NAME" == TapTether* ]]; then
      gh api --method DELETE "repos/$REPO/releases/assets/$ID" >/dev/null
    fi
  done < <(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[] | "\(.id) \(.name)"')
  gh release upload "$TAG" -R "$REPO" "${files[@]}"
else
  gh release create "$TAG" "${files[@]}" -R "$REPO" \
    --target "$SOURCE_SHA" --title "TapTether $VERSION (rolling downloads)" \
    --notes "$NOTES" --latest=false
fi
echo "Updated stable downloads: https://github.com/$REPO/releases/tag/$TAG"
# Only commit a valid feed after its corresponding IPA is actually uploaded.
# Use a disposable worktree based on the current remote HEAD. The release can
# finish after someone else bumps VERSION; in that case the old AltStore feed
# must not overwrite the newer release (or make a successful release look failed).
if [[ "$HAS_IPA" -eq 1 ]]; then
  FEED_SNAPSHOT="$(mktemp)"
  FEED_WORKTREE="$(mktemp -d)"
  cp "$ROOT/altstore.json" "$FEED_SNAPSHOT"
  cleanup_feed_worktree() {
    git worktree remove --force "$FEED_WORKTREE" >/dev/null 2>&1 || true
    rmdir "$FEED_WORKTREE" >/dev/null 2>&1 || true
    rm -f "$FEED_SNAPSHOT"
  }
  trap cleanup_feed_worktree EXIT
  feed_done=0
  worktree_ready=0
  for attempt in 1 2 3; do
    git fetch --quiet origin main
    remote_version="$(git show origin/main:VERSION | tr -d '\r\n')"
    if [[ "$remote_version" != "$VERSION" ]]; then
      echo "::notice::Release $VERSION assets published, but main is already $remote_version. Skipping stale AltStore feed push."
      feed_done=1
      break
    fi
    if [[ "$worktree_ready" -eq 0 ]]; then
      git worktree add --quiet --detach "$FEED_WORKTREE" origin/main
      worktree_ready=1
    else
      git -C "$FEED_WORKTREE" reset --hard origin/main >/dev/null
    fi
    cp "$FEED_SNAPSHOT" "$FEED_WORKTREE/altstore.json"
    git -C "$FEED_WORKTREE" add -- altstore.json
    if git -C "$FEED_WORKTREE" diff --cached --quiet -- altstore.json; then
      echo 'AltStore feed already matches published IPA.'
      feed_done=1
      break
    fi
    git -C "$FEED_WORKTREE" -c user.name='TapTether Release Bot' \
      -c user.email='actions@users.noreply.github.com' \
      commit -m "chore: publish AltStore feed for $VERSION" -- altstore.json
    if git -C "$FEED_WORKTREE" push origin HEAD:main; then
      echo 'Committed and pushed altstore.json with the published IPA size/version.'
      feed_done=1
      break
    fi
    echo "::warning::main moved during feed publication; retrying ($attempt/3)."
  done
  if [[ "$feed_done" -ne 1 ]]; then
    echo 'AltStore feed push could not be reconciled with main after three attempts.' >&2
    exit 1
  fi
  cleanup_feed_worktree
  trap - EXIT
fi
echo 'Note: private GitHub release assets and raw altstore.json are not anonymously accessible to AltStore.'
