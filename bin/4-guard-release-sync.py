#!/usr/bin/env python3
"""Verify future full releases never downgrade an independently updated agent.

Minor platform-only updates can progress independently. Major synchronized
releases deliberately choose a VERSION greater than all platform-only feeds.
"""
from __future__ import annotations
import json
import os
import re
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen

REPO = 'ssnanda/taptether.com'
VALID = re.compile(r'^(\d+)\.(\d+)\.(\d+)\+(\d+)$')
TITLE = re.compile(r'^TapTether(?: Ubuntu| macOS| Windows)? (\d+\.\d+\.\d+\+\d+)(?:\s|$)')
PLATFORMS = ('ubuntu', 'macos', 'windows')

def parts(v: str) -> tuple[int, int, int, int]:
    m = VALID.fullmatch(v)
    if not m:
        raise ValueError('Invalid version: ' + repr(v))
    return tuple(map(int, m.groups()))

def check_sync(version: str, releases: dict[str, str]) -> None:
    target = parts(version)
    conflicts = {tag: v for tag, v in releases.items() if target <= parts(v)}
    if conflicts:
        detail = ', '.join(f'{k}={v}' for k, v in sorted(conflicts.items()))
        raise ValueError(
            f'Full release {version} must exceed every published agent '
            f'release ({detail}). Choose a higher synchronized version '
            '(e.g., the next minor + a skipped build number).'
        )

def current_versions() -> dict[str, str]:
    versions = {}
    for platform in PLATFORMS:
        tag = f'{platform}-current'
        headers = {'User-Agent': 'TapTether-Sync-Release-Guard',
                   'Accept': 'application/vnd.github+json'}
        token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
        if token:
            headers['Authorization'] = 'Bearer ' + token
        request = Request(
            f'https://api.github.com/repos/{REPO}/releases/tags/{tag}',
            headers=headers,
        )
        try:
            with urlopen(request, timeout=15) as result:
                payload = json.load(result)
        except HTTPError as e:
            if e.code == 404:
                continue
            raise
        if payload.get('tag_name') != tag:
            raise ValueError(f'{tag}: unexpected GitHub tag')
        found = TITLE.match(payload.get('name', ''))
        if not found:
            raise ValueError(f'{tag}: release title does not contain a valid version')
        versions[tag] = found.group(1)
    return versions

if __name__ == '__main__':
    from pathlib import Path
    version = Path('VERSION').read_text(encoding='utf-8').strip()
    try:
        check_sync(version, current_versions())
    except ValueError as error:
        raise SystemExit(str(error)) from error
    print(f'PASS: full release {version} is newer than every platform-only agent')
