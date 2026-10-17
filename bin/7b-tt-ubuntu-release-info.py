#!/usr/bin/env python3
"""Select the newest trusted Ubuntu agent package without affecting mobile releases.

Both the full TapTether `current` feed and the Ubuntu-only `ubuntu-current`
feed are considered. The version, exact URL and GitHub SHA-256 digest must
agree with the selected feed. Never fall back to an unverified download.
"""
from __future__ import annotations

import json
import re
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen

REPO = "ssnanda/taptether.com"
VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)\+(\d+)$")
TITLE = re.compile(r"^TapTether(?: Ubuntu)? (\d+\.\d+\.\d+\+\d+)(?:\s|$)")
DIGEST = re.compile(r"sha256:([0-9a-fA-F]{64})")


def parts(version: str) -> tuple[int, int, int, int]:
    match = VERSION.fullmatch(version)
    if not match:
        raise ValueError("Invalid TapTether agent version: " + repr(version))
    return tuple(int(x) for x in match.groups())


def validated_release(data: dict, tag: str, arch: str) -> tuple[str, str, str]:
    if data.get("tag_name") != tag:
        raise ValueError(f"Unexpected GitHub release tag for {tag}")
    match = TITLE.match(data.get("name", ""))
    if not match:
        raise ValueError(f"Missing exact version in GitHub {tag} release title")
    version = match.group(1)
    expected_name = f"TapTetherAgent-Ubuntu-{arch}.deb"
    matches = [a for a in data.get("assets", []) if a.get("name") == expected_name]
    if len(matches) != 1:
        raise ValueError(f"{tag}: exactly one {expected_name} must exist")
    asset = matches[0]
    digest = DIGEST.fullmatch(asset.get("digest", ""))
    if not digest:
        raise ValueError(f"{tag}: GitHub SHA-256 digest missing/invalid")
    url = f"https://github.com/{REPO}/releases/download/{tag}/{expected_name}"
    if asset.get("browser_download_url") != url:
        raise ValueError(f"{tag}: unexpected download URL")
    return version, digest.group(1).lower(), url


def select_release(
    releases: dict[str, dict], arch: str, installed: str
) -> tuple[str, str, str, str]:
    installed_parts = parts(installed)
    options = [validated_release(data, tag, arch)
               for tag, data in releases.items()]
    if not options:
        raise ValueError("No trusted Ubuntu agent release is available")
    version, digest, url = max(options, key=lambda x: parts(x[0]))
    newer = "yes" if parts(version) > installed_parts else "no"
    return version, newer, digest, url


def fetch_release(tag: str) -> dict:
    url = f"https://api.github.com/repos/{REPO}/releases/tags/{tag}"
    request = Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "TapTether-Ubuntu-Trusted-Updater",
    })
    with urlopen(request, timeout=12) as response:
        return json.load(response)


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in ("amd64", "arm64"):
        raise SystemExit("Usage: 7b-tt-ubuntu-release-info.py amd64|arm64 INSTALLED_VERSION")
    arch, installed = sys.argv[1:]
    releases = {"current": fetch_release("current")}
    try:
        releases["ubuntu-current"] = fetch_release("ubuntu-current")
    except HTTPError as error:
        if error.code != 404:
            raise  # Fail closed for rate limits or inconsistent responses.
    try:
        print("\t".join(select_release(releases, arch, installed)))
    except ValueError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
