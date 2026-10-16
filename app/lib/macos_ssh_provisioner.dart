import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';

import 'phone_ssh_keys.dart';
import 'ssh_host_trust.dart';
import 'ssh_provisioner.dart';
import 'ubuntu_install_validation.dart';

/// Identifies the prebuilt, SHA-verified macOS package without trusting
/// remote host names or user-provided archive paths.
String macosArchiveArchitecture(String uname, String machine) {
  if (uname.trim() != 'Darwin') {
    throw StateError('[MAC-OS] Remote Login is not connected to macOS.');
  }
  switch (machine.trim()) {
    case 'arm64':
      return 'arm64';
    case 'x86_64':
      return 'amd64';
    default:
      throw StateError('[MAC-ARCH] This Mac architecture is not supported.');
  }
}

({String token, String fingerprint}) macosPairingFromOutput(String output) {
  final token = RegExp(r'Pairing token \(PRIVATE\):\s*([a-fA-F0-9]{48})')
      .firstMatch(output)?.group(1);
  final pin = RegExp(r'TLS SHA-256 fingerprint:\s*([A-Fa-f0-9]{64})')
      .firstMatch(output)?.group(1);
  if (token == null || pin == null) {
    throw StateError('[MAC-PAIRING] Agent installed, but pairing information '
        'was not available. Check the service on the Mac and retry.');
  }
  return (token: token.toLowerCase(), fingerprint: pin.toUpperCase());
}

/// macOS installs/updates are per-user launchd services, never sudo.
/// Requires Remote Login enabled and a logged-in graphical user session.
/// Preserves agent configuration, pairing identity and SSH trust on update.
class MacSshProvisioner {
  static Future<InstalledAgent> install(
    SshInstallRequest input, {
    bool updateOnly = false,
    void Function(String stage)? onProgress,
    SshHostTrustStore? hostTrustStore,
  }) async {
    void progress(String step) => onProgress?.call(step);
    progress('Checking Mac SSH connection details');
    if (!validUbuntuLanIp(input.host)) {
      throw const FormatException('Enter a private LAN IPv4 address.');
    }
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}$')
        .hasMatch(input.username) || input.username.startsWith('-')) {
      throw const FormatException('Enter the Mac short account username.');
    }
    if (input.loginMethod == SshLoginMethod.password &&
        input.sshPassword.isEmpty) {
      throw const FormatException('Enter the Mac SSH login password.');
    }
    if (input.loginMethod == SshLoginMethod.phoneKey &&
        !await PhoneSshKeyStore().exists) {
      throw const FormatException('Select or create a phone SSH key first.');
    }

    final trust = hostTrustStore ?? SshHostTrustStore();
    final expected = await trust.trustedFingerprint(input.host);
    final identities = input.loginMethod == SshLoginMethod.phoneKey
        ? await PhoneSshKeyStore().authenticationIdentities(id: input.sshKeyId)
        : null;
    progress('Connecting to macOS Remote Login');
    final socket = await SSHSocket.connect(input.host, 22)
        .timeout(const Duration(seconds: 10));
    String? fingerprint;
    var keyChanged = false;
    final client = SSHClient(
      socket,
      username: input.username,
      identities: identities,
      onPasswordRequest: input.loginMethod == SshLoginMethod.password
          ? () => input.sshPassword : null,
      handshakeTimeout: const Duration(seconds: 12),
      authTimeout: const Duration(seconds: 12),
      onVerifyHostKey: (_, raw) {
        final observed = utf8.decode(raw);
        fingerprint = observed;
        if (!SshHostTrustStore.validFingerprint(observed)) return false;
        if (expected != null && expected != observed) {
          keyChanged = true;
          return false;
        }
        return true;
      },
    );
    String? stage;
    SftpClient? sftp;
    try {
      progress('Verifying SSH host identity and signing in');
      try {
        await client.authenticated.timeout(const Duration(seconds: 20));
      } catch (_) {
        if (keyChanged) {
          throw StateError('[SSH-IDENTITY] The Mac SSH host identity changed. '
              'TapTether blocked the connection.');
        }
        throw StateError('[SSH-LOGIN] Mac SSH login failed. Turn on Remote '
            'Login under System Settings > General > Sharing; verify the '
            'username, password or the authorized phone SSH key.');
      }
      if (fingerprint == null) {
        throw StateError('[SSH-IDENTITY] Cannot verify the Mac SSH key.');
      }
      await trust.rememberAuthenticated(input.host, fingerprint!);
      if (input.loginMethod == SshLoginMethod.password &&
          input.authorizePhoneKey) {
        await UbuntuSshProvisioner.authorizePhoneKey(
            client, input.sshKeyId);
      }

      progress('Checking macOS architecture');
      final platform = await client.runWithResult('uname -s; uname -m');
      if (platform.exitCode != 0) {
        throw StateError('[MAC-OS] Could not inspect the Mac system.');
      }
      final lines = utf8.decode(platform.stdout).trim().split(RegExp(r'\s+'));
      if (lines.length != 2) {
        throw StateError('[MAC-OS] Mac platform information was incomplete.');
      }
      final arch = macosArchiveArchitecture(lines[0], lines[1]);
      if (updateOnly) {
        final existing = await client.runWithResult(
            'test -x "\$HOME/.local/bin/taptether-agent"');
        if (existing.exitCode != 0) {
          throw StateError('[NOT-INSTALLED] No TapTether agent was found on '
              'this Mac. Choose Install Agent rather than Update Agent.');
        }
      }

      final decoded = jsonDecode(
          await rootBundle.loadString('assets/agents/manifest.json'));
      if (decoded is! Map || decoded['installers'] is! List) {
        throw StateError('[MAC-PACKAGE] Installer manifest is unavailable.');
      }
      final matched = (decoded['installers'] as List)
          .whereType<Map>()
          .where((item) =>
              item['platform'] == 'macos' && item['arch'] == arch)
          .toList();
      if (matched.length != 1) {
        throw StateError('[MAC-PACKAGE] Matching Mac installer is not '
            'bundled with this phone app. Install the latest phone build.');
      }
      final entry = matched.single;
      final filename = entry['filename'];
      final asset = entry['asset'];
      final expectedSha = entry['sha256'];
      if (filename is! String || asset is! String ||
          expectedSha is! String ||
          !RegExp('^TapTetherAgent-macos-$arch-[0-9A-Za-z.+_-]+\\.tar\\.gz\$')
              .hasMatch(filename) ||
          asset != 'assets/agents/$filename' ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedSha)) {
        throw StateError('[MAC-PACKAGE] Installer metadata is invalid.');
      }
      progress('Verifying bundled Mac installer SHA-256');
      final bundle = await rootBundle.load(asset);
      final archive = bundle.buffer.asUint8List(
          bundle.offsetInBytes, bundle.lengthInBytes);
      if (sha256.convert(archive).toString() != expectedSha.toLowerCase()) {
        throw StateError('[MAC-PACKAGE] The bundled installer hash does not '
            'match the release manifest.');
      }

      // Screen Core is separately signed and versioned, outside the legacy
      // five-entry Mac updater archive. Verify on the phone before transfer.
      final coreRows = decoded['screenCores'];
      if (coreRows is! List) {
        throw StateError('[MAC-SCREEN-CORE] Screen Core package is missing.');
      }
      final coreMatches = coreRows.whereType<Map>().where((item) =>
          item['platform'] == 'macos' && item['arch'] == arch).toList();
      if (coreMatches.length != 1) {
        throw StateError('[MAC-SCREEN-CORE] Screen Core for this Mac is missing.');
      }
      final coreEntry = coreMatches.single;
      final coreName = coreEntry['filename'];
      final coreAsset = coreEntry['asset'];
      final coreDigest = coreEntry['sha256'];
      if (coreName is! String || coreAsset is! String ||
          coreDigest is! String ||
          !coreName.startsWith('TapTetherScreenCore-macos-$arch-') ||
          !coreName.endsWith('.tar.gz') ||
          coreAsset != 'assets/agents/$coreName' ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(coreDigest)) {
        throw StateError('[MAC-SCREEN-CORE] Invalid Screen Core metadata.');
      }
      final coreData = await rootBundle.load(coreAsset);
      final coreArchive = coreData.buffer.asUint8List(
          coreData.offsetInBytes, coreData.lengthInBytes);
      if (sha256.convert(coreArchive).toString() != coreDigest.toLowerCase()) {
        throw StateError('[MAC-SCREEN-CORE] Screen Core SHA-256 mismatch.');
      }

      final make = await client.runWithResult(
          'mktemp -d /tmp/taptether-mac.XXXXXXXX');
      if (make.exitCode != 0) {
        throw StateError('[MAC-STAGE] Cannot create a temporary Mac folder.');
      }
      stage = utf8.decode(make.stdout).trim();
      if (!RegExp(r'^/tmp/taptether-mac\.[A-Za-z0-9]{8}$')
          .hasMatch(stage)) {
        throw StateError('[MAC-STAGE] Unexpected staging directory.');
      }
      progress('Uploading Mac agent over encrypted SSH');
      sftp = await client.sftp();
      final output = await sftp.open('$stage/$filename',
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.write | SftpFileOpenMode.truncate);
      try {
        await output.writeBytes(archive);
      } finally {
        await output.close();
      }

      progress('Staging independently approved Screen Core');
      final coreOutput = await sftp.open('$stage/$coreName',
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.write | SftpFileOpenMode.truncate);
      try {
        await coreOutput.writeBytes(coreArchive);
      } finally {
        await coreOutput.close();
      }

      progress('Checking archive and installing user LaunchAgent');
      final cmd = '''
set -e
cd '$stage'
tar -tzf '$filename' > archive-list.txt
for f in taptether-agent taptetherctl-mac taptether-agent-update-mac TapTether.icns TapTetherTray; do
  grep -Fxq "\$f" archive-list.txt || exit 52
done
test "\$(wc -l < archive-list.txt | tr -d ' ')" -eq 5 || exit 52
tar -xzf '$filename'
test "\$(tar -tzf '$coreName')" = 'taptether-screen-core' || exit 52
tar -xzf '$coreName'
chmod 755 taptether-agent taptetherctl-mac taptether-agent-update-mac TapTetherTray taptether-screen-core
bash taptetherctl-mac install > install.log 2>&1 || exit 53
cat install.log
''';
      // Mac agent setup prints pairing tokens. Hold it only in memory;
      // never expose raw stdout/stderr in the mobile diagnostic report.
      final session = await client.execute(cmd);
      final collected = <int>[];
      await Future.wait([
        session.stdout.forEach(collected.addAll),
        session.stderr.forEach(collected.addAll),
      ]).timeout(const Duration(minutes: 5));
      final result = await session.waitForExit(
          timeout: const Duration(seconds: 12));
      if (result != 0) {
        if (result == 52) {
          throw StateError('[MAC-ARCHIVE] Bundled agent archive could not '
              'be verified on the Mac.');
        }
        if (result == 53) {
          throw StateError('[MAC-LAUNCHD] The Mac installer could not start '
              'the background service. Sign in to the Mac desktop, verify '
              'Remote Login and retry. Open Agent Diagnostics locally if '
              'it still fails.');
        }
        throw StateError('[MAC-INSTALL] Remote Mac installation failed '
            'during archive extraction or setup.');
      }

      progress('Reading pairing details and preserving identity');
      final pairing = macosPairingFromOutput(
          utf8.decode(collected, allowMalformed: true));
      return InstalledAgent(input.host, pairing.token, pairing.fingerprint);
    } finally {
      if (sftp != null) await sftp.close();
      if (stage != null) {
        try {
          await client.run("rm -rf -- '$stage'");
        } catch (_) {
          // Cleanup is best-effort and must not shadow the primary failure.
        }
      }
      await client.close();
    }
  }
}
