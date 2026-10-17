#!/usr/bin/env python3
"""Offline audit of the exact desktop files included in release installers."""
from __future__ import annotations

import argparse
import io
import plistlib
import zipfile
from pathlib import PurePosixPath
from pathlib import Path
import tarfile
import subprocess


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def ar_members(path: Path) -> dict[str, bytes]:
    with path.open('rb') as stream:
        require(stream.read(8) == b'!<arch>\n', f'{path}: invalid Debian archive')
        members = {}
        while header := stream.read(60):
            require(len(header) == 60 and header[58:60] == bytes((96, 10)), f'{path}: malformed ar header')
            name = header[:16].decode('ascii').strip().rstrip('/')
            size = int(header[48:58].decode('ascii').strip())
            members[name] = stream.read(size)
            require(len(members[name]) == size, f'{path}: truncated ar member {name}')
            if size % 2:
                require(len(stream.read(1)) == 1, f'{path}: missing ar padding')
    return members


def check_deb(root: Path, version: str, arch: str) -> None:
    archive = root / 'dist' / 'ubuntu' / f'taptether-agent_{version}_{arch}.deb'
    require(archive.is_file(), f'Missing Ubuntu package: {archive}')
    ar = ar_members(archive)
    require({'debian-binary', 'control.tar.gz', 'data.tar.gz'} <= ar.keys(), f'{archive}: missing required sections')
    with tarfile.open(fileobj=io.BytesIO(ar['control.tar.gz']), mode='r:gz') as tf:
        control = tf.extractfile('control').read().decode('utf-8')
    for line in ('Package: taptether-agent', f'Version: {version}', f'Architecture: {arch}'):
        require(line in control.splitlines(), f'{archive}: incorrect package metadata: {line}')
    # xdotool is only a legacy X11 fallback, never a required dependency.
    require('Suggests: xdotool' in control.splitlines(),
            f'{archive}: expected optional xdotool suggestion')
    require(not any(line.startswith(('Depends: xdotool', 'Pre-Depends: xdotool'))
                    for line in control.splitlines()),
            f'{archive}: optional xdotool must not block installation')
    sources = {
        'usr/share/taptether/4-ubuntu-desktop-setup.sh': root / 'bin' / '4-ubuntu-desktop-setup.sh',
        'usr/share/taptether/7-tt-update-ubuntu.sh': root / 'bin' / '7-tt-update-ubuntu.sh',
            'usr/share/taptether/7b-tt-ubuntu-release-info.py': root / 'bin' / '7b-tt-ubuntu-release-info.py',
        'usr/share/taptether/9-tt-system-update-ubuntu.sh': root / 'bin' / '9-tt-system-update-ubuntu.sh',
        'usr/share/taptether/taptether_tray.py': root / 'desktop' / 'ubuntu' / 'taptether_tray.py',
        'usr/share/taptether/taptether_screen.py': root / 'desktop' / 'ubuntu' / 'taptether_screen.py',
        'usr/share/taptether/10-tt-ubuntu-screen-session.sh': root / 'bin' / '10-tt-ubuntu-screen-session.sh',
    }
    expected = {'usr/local/bin/taptether-agent', 'usr/bin/taptether-setup',
                'usr/share/taptether/TapTether-icon.png', *sources.keys()}
    with tarfile.open(fileobj=io.BytesIO(ar['data.tar.gz']), mode='r:gz') as tf:
        members = {m.name.rstrip('/'): m for m in tf.getmembers()}
        entries = {name: m for name, m in members.items() if m.isfile()}
        require(expected <= entries.keys(), f'{archive}: missing payload: {sorted(expected - entries.keys())}')
        # A tar archive of files alone may list correctly with dpkg-deb
        # --contents but fail to install on a clean Ubuntu computer:
        # every parent directory must be a real directory entry in data.tar.
        for name in expected:
            for parent in PurePosixPath(name).parents:
                directory = parent.as_posix()
                if directory == '.':
                    continue
                member = members.get(directory)
                require(member is not None and member.isdir(),
                        f'{archive}: missing parent directory: {directory}/')
                require(member.mode & 0o111 == 0o111,
                        f'{archive}: parent directory not traversable: {directory}/')
        for package_name, source in sources.items():
            require(tf.extractfile(entries[package_name]).read() == source.read_bytes(),
                    f'{archive}: outdated bundled helper {package_name}')
        icon = tf.extractfile(entries['usr/share/taptether/TapTether-icon.png']).read()
        require(icon.startswith(b'\x89PNG\r\n\x1a\n'), f'{archive}: invalid icon')
        setup = tf.extractfile(entries['usr/bin/taptether-setup']).read()
        require(b'/usr/share/taptether/4-ubuntu-desktop-setup.sh' in setup,
                f'{archive}: setup command does not invoke packaged installer')
        for entry in expected:
            if entry != 'usr/share/taptether/TapTether-icon.png':
                require(entries[entry].mode & 0o111 != 0,
                        f'{archive}: required executable permission missing for {entry}')
    print(f'PASS Ubuntu {arch}: executable, desktop setup, tray, icon and updater packaged')


def check_macos(root: Path, version: str, arch: str) -> None:
    archive = root / 'dist' / 'macos' / f'TapTetherAgent-macos-{arch}-{version}.tar.gz'
    bundle_zip = root / 'dist' / 'macos' / f'TapTetherAgent-macos-{arch}-{version}.zip'
    core_version = (root / 'INPUT_CORE_VERSION').read_text(encoding='utf-8').strip()
    core_archive = root / 'dist' / 'macos' / f'TapTetherInputCore-macos-{arch}-{core_version}.tar.gz'
    screen_version = (root / 'SCREEN_CORE_VERSION').read_text(encoding='utf-8').strip()
    screen_archive = root / 'dist' / 'macos' / f'TapTetherScreenCore-macos-{arch}-{screen_version}.tar.gz'
    require(archive.is_file() and bundle_zip.is_file(),
            f'Missing macOS agent archive or Finder-friendly app ZIP: {arch}')
    require(core_archive.is_file(), f'Missing macOS Input Core archive: {arch}')
    require(screen_archive.is_file(), f'Missing stable Screen Core archive: {arch}')
    with tarfile.open(screen_archive, mode='r:gz') as tf:
        entries = {m.name: m for m in tf.getmembers()}
        require(entries.keys() == {'taptether-screen-core'},
                f'{screen_archive}: unexpected Screen Core payload')
        require(entries['taptether-screen-core'].isfile() and
                entries['taptether-screen-core'].mode & 0o111,
                f'{screen_archive}: Screen Core is not executable')
    with tarfile.open(core_archive, mode='r:gz') as tf:
        entries = {m.name: m for m in tf.getmembers()}
        require(entries.keys() == {'taptether-input-core'},
                f'{core_archive}: unexpected Input Core payload')
        require(entries['taptether-input-core'].isfile() and
                entries['taptether-input-core'].mode & 0o111,
                f'{core_archive}: Input Core is not executable')
    flat = {'taptether-agent', 'taptetherctl-mac',
            'taptether-agent-update-mac', 'TapTether.icns', 'TapTetherTray'}
    # Legacy 5-member format: existing installed agents require exactly this.
    with tarfile.open(archive, mode='r:gz') as tf:
        entries = {m.name: m for m in tf.getmembers()}
        require(entries.keys() == flat,
                f'{archive}: legacy updater would reject archive members')
        for name in flat:
            require(entries[name].isfile() and entries[name].size > 100,
                    f'{archive}: incomplete payload {name}')
            if name != 'TapTether.icns':
                require(entries[name].mode & 0o111 != 0,
                        f'{archive}: {name} not executable')
        for name, source in (
            ('taptetherctl-mac', root / 'bin' / '4-macos-agent-setup.sh'),
            ('taptether-agent-update-mac', root / 'bin' / '8-tt-update-macos.sh'),
        ):
            require(tf.extractfile(entries[name]).read() == source.read_bytes(),
                    f'{archive}: outdated helper {name}')

    app = 'TapTether Agent.app/Contents/'
    required = {app + 'Info.plist', app + 'MacOS/TapTetherTray',
                app + 'Resources/TapTether.icns',
                app + 'Resources/taptether-agent',
                app + 'Resources/taptether-input-core',
                app + 'Resources/taptether-screen-core',
                app + 'Resources/taptetherctl-mac',
                app + 'Resources/taptether-agent-update-mac',
                app + 'Resources/version.txt'}
    with zipfile.ZipFile(bundle_zip) as zf:
        names = set(zf.namelist())
        require(required <= names,
                f'{bundle_zip}: incomplete standalone macOS app')
        for name in names:
            path = PurePosixPath(name)
            require(not path.is_absolute() and '..' not in path.parts,
                    f'{bundle_zip}: invalid archive path')
        info = plistlib.loads(zf.read(app + 'Info.plist'))
        require(info.get('CFBundleExecutable') == 'TapTetherTray' and
                info.get('CFBundlePackageType') == 'APPL',
                f'{bundle_zip}: invalid macOS app Info.plist')
        require(info.get('CFBundleShortVersionString') == version.split('+')[0],
                f'{bundle_zip}: incorrect app version')
        require(zf.read(app + 'Resources/version.txt').decode().strip() == version,
                f'{bundle_zip}: incorrect packaged version')
        for name, source in (
            ('taptetherctl-mac', root / 'bin' / '4-macos-agent-setup.sh'),
            ('taptether-agent-update-mac', root / 'bin' / '8-tt-update-macos.sh'),
        ):
            require(zf.read(app + 'Resources/' + name) == source.read_bytes(),
                    f'{bundle_zip}: outdated app installer resource {name}')
    print(f'PASS macOS {arch}: compatible tarball and native installable .app ZIP')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=('ubuntu', 'macos', 'all'), default='all')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    version = (root / 'VERSION').read_text(encoding='utf-8').strip()
    for arch in ('amd64', 'arm64'):
        if args.platform in ('ubuntu', 'all'):
            check_deb(root, version, arch)
        if args.platform in ('macos', 'all'):
            check_macos(root, version, arch)
    if args.platform in ('macos', 'all'):
        subprocess.run(
            ['bash', str(root / 'bin' / '4-clean-macos-review-apps.sh')],
            check=True,
        )


if __name__ == '__main__':
    main()
