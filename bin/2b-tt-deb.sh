#!/usr/bin/env bash
# Portable Debian package builder: avoids macOS ar/ranlib's Mach-O symbol index.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required for .deb packaging.' >&2; exit 1; }
python3 - "$ROOT" <<'TT_DEB_PY'
from __future__ import annotations

import io
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile
import tempfile

root = Path(sys.argv[1])
version = (root / 'VERSION').read_text(encoding='utf-8').strip()
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+', version):
    raise SystemExit(f'Invalid package version: {version!r}')

output_dir = root / 'dist' / 'ubuntu'
output_dir.mkdir(parents=True, exist_ok=True)


def tar_gz(members):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz', format=tarfile.USTAR_FORMAT) as archive:
        directories = set()
        for path, content, mode in members:
            # dpkg requires each parent directory to be declared in data.tar,
            # not just implied by a file name. Missing entries break fresh
            # Ubuntu installs with 'unable to create ... No such file'.
            for parent in reversed(PurePosixPath(path).parents):
                directory = parent.as_posix()
                if directory == '.' or directory in directories:
                    continue
                entry = tarfile.TarInfo(directory + '/')
                entry.type = tarfile.DIRTYPE
                entry.mode = 0o755
                entry.uid = entry.gid = entry.mtime = 0
                entry.uname = entry.gname = 'root'
                archive.addfile(entry)
                directories.add(directory)
            entry = tarfile.TarInfo(path)
            entry.size = len(content)
            entry.mode = mode
            entry.uid = entry.gid = entry.mtime = 0
            entry.uname = entry.gname = 'root'
            archive.addfile(entry, io.BytesIO(content))
    return buffer.getvalue()


def write_ar_member(fh, name, data):
    if len(name) > 15:
        raise ValueError(f'Debian archive member name too long: {name}')
    header = (
        f'{name + "/":<16}'
        f'{0:<12}'
        f'{0:<6}'
        f'{0:<6}'
        f'{"100644":<8}'
        f'{len(data):<10}'
        '`\n'
    ).encode('ascii')
    if len(header) != 60:
        raise AssertionError('Invalid ar header length')
    fh.write(header)
    fh.write(data)
    if len(data) % 2:
        fh.write(b'\n')


for arch in ('amd64', 'arm64'):
    binary_path = root / 'dist' / 'agents' / f'TapTetherAgent-linux-{arch}-{version}'
    if not binary_path.is_file():
        raise SystemExit(f'Missing {binary_path}; run ./bin/2b-tt-ubuntu.sh first')
    binary = binary_path.read_bytes()
    if len(binary) < 1024 or not binary.startswith(b'\x7fELF'):
        raise SystemExit(f'Not a plausible Linux ELF executable: {binary_path}')
    control = (
        'Package: taptether-agent\n'
        f'Version: {version}\n'
        'Section: utils\n'
        'Priority: optional\n'
        f'Architecture: {arch}\n'
        'Maintainer: TapTether <support@taptether.com>\n'
        'Suggests: xdotool\n'
        'Description: TapTether Wayland/X11 virtual keyboard, mouse and volume agent\n'
        ' A local HTTPS remote input agent with native Linux uinput support.\n'
        ' No cloud account or telemetry.\n'
    ).encode('utf-8')
    # Complete desktop resources travel with every downloadable Ubuntu .deb.
    # Only the desktop user may run taptether-setup install, not dpkg postinst.
    payload = [('usr/local/bin/taptether-agent', binary, 0o755)]
    for dest, source in (
        ('usr/share/taptether/4-ubuntu-desktop-setup.sh', root / 'bin' / '4-ubuntu-desktop-setup.sh'),
        ('usr/share/taptether/7-tt-update-ubuntu.sh', root / 'bin' / '7-tt-update-ubuntu.sh'),
        ('usr/share/taptether/7b-tt-ubuntu-release-info.py', root / 'bin' / '7b-tt-ubuntu-release-info.py'),
        ('usr/share/taptether/9-tt-system-update-ubuntu.sh', root / 'bin' / '9-tt-system-update-ubuntu.sh'),
        ('usr/share/taptether/taptether_tray.py', root / 'desktop' / 'ubuntu' / 'taptether_tray.py'),
        ('usr/share/taptether/taptether_screen.py', root / 'desktop' / 'ubuntu' / 'taptether_screen.py'),
        ('usr/share/taptether/10-tt-ubuntu-screen-session.sh', root / 'bin' / '10-tt-ubuntu-screen-session.sh'),
    ):
        if not source.is_file() or source.stat().st_size < 100:
            raise SystemExit(f'Missing required desktop resource: {source}')
        payload.append((dest, source.read_bytes(), 0o755))
    icon = next((
        candidate for candidate in (
            root / 'dist' / 'branding' / 'TapTether-icon.png',
            root / 'assets' / 'branding' / 'TapTether-agent.png',
        ) if candidate.is_file()
    ), None)
    if icon is None or not icon.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):
        raise SystemExit('A valid TapTether PNG icon is required for .deb packaging.')
    payload.append(('usr/share/taptether/TapTether-icon.png', icon.read_bytes(), 0o644))
    payload.append((
        'usr/bin/taptether-setup',
        b'#!/bin/sh\nexec /bin/bash /usr/share/taptether/4-ubuntu-desktop-setup.sh "$@"\n',
        0o755,
    ))
    members = (
        ('debian-binary', b'2.0\n'),
        ('control.tar.gz', tar_gz([('control', control, 0o644)])),
        ('data.tar.gz', tar_gz(payload)),
    )
    output = output_dir / f'taptether-agent_{version}_{arch}.deb'
    fd, temp_path = tempfile.mkstemp(prefix=f'.taptether-{arch}-', suffix='.deb', dir=output_dir)
    try:
        with os.fdopen(fd, 'wb') as fh:
            fh.write(b'!<arch>\n')
            for name, data in members:
                write_ar_member(fh, name, data)
        if os.path.getsize(temp_path) < 1024:
            raise RuntimeError(f'Unexpectedly small package: {temp_path}')
        os.replace(temp_path, output)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)
    print(f'Debian package: {output} ({output.stat().st_size:,} bytes)')
TT_DEB_PY
