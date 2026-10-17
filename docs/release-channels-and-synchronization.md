# TapTether release channels: apps and independently updated agents

## Initial coordinated upgrade

TapTether **0.7.7+70** is the coordinated bootstrap release. It ships the
iPhone IPA, Android APK, Ubuntu, macOS and Windows installers together,
including all desktop updater changes. It intentionally skips from the
previous release build 66 to build 70 to establish a shared baseline.

Existing 0.7.5/0.7.6 desktop agents read the legacy **current** feed, so the
first upgrade must remain a normal full release. Both phone apps must also
update once to learn the new platform-specific agent feed. No reinstall or
re-pairing is required.

## From then on

There is still ONE GitHub Actions workflow, with manual choices:

| Task | Builds/releases | Rolling GitHub tag |
| --- | --- | --- |
| release (or VERSION bump to main) | IPA, APK, all platform agents and protected-core artifacts | current |
| agent-ubuntu + agent_version | Ubuntu amd64/arm64 Debian installers only | ubuntu-current |
| agent-macos + agent_version | macOS Intel/ARM agent and Finder application, not Input/Screen Core | macos-current |
| agent-windows + agent_version | Windows amd64/arm64 agent installers only | windows-current |

An agent-only build is checked for syntax, Go behavior, package structure,
version monotonicity and GitHub SHA-256 asset digests. It creates a permanently
versioned release `agent-<platform>-v<version>` as well as the platform's
rolling alias. **It does not modify** the IPA, APK, AltStore feed, `current`,
or installers for other platforms. The agents and phone's Update Agent
dialog select the newest verified platform release (or the latest full
release) without downgrading.

For example, after the coordinated `0.7.7+70` release:
- Ubuntu-only fix: `agent-ubuntu` with `0.7.8+71`.
- macOS-only fix: `agent-macos` with `0.7.9+72`.
- Windows-only fix: `agent-windows` with `0.7.10+73`.
- Next major/full synchronized update: deliberately **skip ahead** to
  `0.8.0+100`, so all phone builds and agents show the same version again.

Platform agents use an independent version counter only as long as the full
release does not need to synchronize. A full release is blocked when its
VERSION is not strictly greater than every published platform-only version.
This prevents a newer agent being overwritten by older full-release binaries.

### Important safeguards

- Authenticated local pairing identities and TLS certificates persist.
- macOS Input Core and Screen Core remain at their explicitly protected
  versions. An ordinary macOS agent-only release never ships new cores.
- The phone's bundled SSH recovery installer stays at the full app's version;
  it is never allowed to downgrade a newer computer agent.
- Existing agents that do not support independent feeds can always upgrade
  through the normal full `current` release before using the new flow.
- An agent-only release cannot be published from a branch other than main;
  the requested version must be newer than both the full and platform-only
  release versions. Build assets are verified before the rolling tag changes.
- No accounts, telemetry, cloud remote-control services or new mobile
  permissions are added.
