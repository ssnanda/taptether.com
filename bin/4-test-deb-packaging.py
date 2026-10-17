#!/usr/bin/env python3
"""Fast offline regression test for TapTether Debian payload directory entries.

Builds both packages with harmless dummy ELF headers in a temporary fixture.
No Go, Flutter, sudo, package installation, or network access required.
The production package builder and production package audit are both exercised.
"""
from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory


def main() -> None:
    repo = Path(__file__).resolve().parent.parent
    version = (repo / "VERSION").read_text(encoding="utf-8").strip()
    with TemporaryDirectory(prefix="taptether-deb-test-") as temp:
        fake = Path(temp)
        (fake / "VERSION").write_text(version + "\n", encoding="utf-8")
        for item in (
            "bin/2b-tt-deb.sh",
            "bin/4-validate-desktop-installers.py",
            "bin/4-ubuntu-desktop-setup.sh",
            "bin/7-tt-update-ubuntu.sh",
            "bin/7b-tt-ubuntu-release-info.py",
            "bin/9-tt-system-update-ubuntu.sh",
            "desktop/ubuntu/taptether_tray.py",
            "desktop/ubuntu/taptether_screen.py",
            "bin/10-tt-ubuntu-screen-session.sh",
            "assets/branding/TapTether-agent.png",
        ):
            target = fake / item
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(repo / item, target)
        agent_dir = fake / "dist" / "agents"
        agent_dir.mkdir(parents=True)
        for arch in ("amd64", "arm64"):
            (agent_dir / f"TapTetherAgent-linux-{arch}-{version}").write_bytes(
                b"\x7fELF" + bytes(2048)
            )
        subprocess.run(
            ["bash", str(fake / "bin/2b-tt-deb.sh")],
            check=True, stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            [sys.executable, str(fake / "bin/4-validate-desktop-installers.py"),
             "--platform", "ubuntu"],
            check=True, stdout=subprocess.DEVNULL,
        )
        print("PASS: both .debs explicitly contain all parent directories")


if __name__ == "__main__":
    main()
