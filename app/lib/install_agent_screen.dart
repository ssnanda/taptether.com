import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'discovery.dart';
import 'lan_scan.dart';
import 'ssh_provisioner.dart';
import 'ubuntu_install_screen.dart';

/// Single OS-aware installer entry. Existing authenticated device metadata
/// selects the platform; for a fresh/unpaired host the user chooses the OS.
/// Windows has no supported agent installer yet and never assumes SSH.
class InstallAgentScreen extends StatefulWidget {
  const InstallAgentScreen({
    super.key,
    required this.initialHost,
    required this.onInstalled,
    this.knownPlatform,
    this.updateOnly = false,
  });

  final String initialHost;
  final String? knownPlatform;
  final bool updateOnly;
  final Future<bool> Function(InstalledAgent, String) onInstalled;

  @override
  State<InstallAgentScreen> createState() => _InstallAgentScreenState();
}

class _InstallAgentScreenState extends State<InstallAgentScreen> {
  late final _address = TextEditingController(text: widget.initialHost);
  String? _platform;

  @override
  void initState() {
    super.initState();
    if (const {'linux', 'darwin', 'windows'}.contains(widget.knownPlatform)) {
      _platform = widget.knownPlatform;
    }
    unawaited(_loadCurrentNetwork());
  }

  Future<void> _loadCurrentNetwork() async {
    if (isPrivateIPv4(_address.text.trim())) return;
    final local = await detectLanRange();
    if (mounted && local != null && !isPrivateIPv4(_address.text.trim())) {
      setState(() {
        _address.text = '${local.activePrefix}.';
        _address.selection = TextSelection.collapsed(
          offset: _address.text.length);
      });
    }
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _sshInstallOrUpdate() async {
    final ip = _address.text.trim();
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => UbuntuInstallScreen(
        initialHost: ip,
        isMac: _platform == 'darwin',
        updateOnly: widget.updateOnly,
        onInstalled: (installed) => widget.onInstalled(installed, _platform!),
      ),
    ));
  }

  Future<void> _openMacDownload() async {
    const link = 'https://github.com/ssnanda/taptether.com/releases/latest';
    final ok = await launchUrl(Uri.parse(link),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not open the releases page.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.updateOnly ? 'Update Agent' : 'Install Agent')),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(widget.updateOnly ? 'Update a computer' : 'Connect a computer',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Choose a computer and operating system.'),
          const SizedBox(height: 12),
          TextField(
            controller: _address,
            keyboardType: TextInputType.url,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              LengthLimitingTextInputFormatter(15),
            ],
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Computer LAN IP',
              helperText: 'The local network prefix is filled automatically',
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            key: const ValueKey('install-platform'),
            initialValue: _platform,
            decoration: const InputDecoration(labelText: 'Computer OS'),
            items: const [
              DropdownMenuItem(value: 'linux', child: Text('Ubuntu / Linux')),
              DropdownMenuItem(value: 'darwin', child: Text('macOS')),
              DropdownMenuItem(value: 'windows', child: Text('Windows')),
            ],
            onChanged: (value) => setState(() => _platform = value),
          ),
          const SizedBox(height: 18),
          if (_platform == null)
            const Text('Choose a computer OS to see its installation method. '
                'An unpaired computer cannot be identified securely from '
                'its IP address alone.'),
          if (_platform == 'linux') ...[
            const SizedBox(height: 6),
            FilledButton.icon(
              onPressed: isPrivateIPv4(_address.text.trim())
                  ? _sshInstallOrUpdate : null,
              icon: const Icon(Icons.terminal),
              label: Text(widget.updateOnly ? 'Update over SSH' : 'Install over SSH'),
            ),
            const ExpansionTile(
              title: Text('Ubuntu setup requirements'),
              childrenPadding: EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: [Text('SSH must be enabled on the computer. Use '
                  'your saved phone SSH key or computer password. '
                  'Updates preserve pairing credentials.')],
            ),
          ],
          if (_platform == 'darwin') ...[
            const SizedBox(height: 6),
            FilledButton.icon(
              onPressed: isPrivateIPv4(_address.text.trim())
                  ? _sshInstallOrUpdate : null,
              icon: const Icon(Icons.terminal),
              label: Text(widget.updateOnly
                  ? 'Update Mac over SSH' : 'Install Mac over SSH'),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: _openMacDownload,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Manual macOS download (optional)'),
            ),
            const ExpansionTile(
              title: Text('macOS setup requirements'),
              childrenPadding: EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: [Text('Enable Remote Login in System Settings → '
                  'General → Sharing on the Mac. Installation uses a '
                  'saved SSH key or your Mac password and preserves pairing. '
                  'A signed-in desktop session is required.')],
            ),
          ],
          if (_platform == 'windows') ...[
            const SizedBox(height: 6),
            FilledButton.icon(
              onPressed: _openMacDownload,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Download Windows agent'),
            ),
            const ExpansionTile(
              title: Text('Windows setup instructions'),
              childrenPadding: EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: [Text('No SSH is required. Download and extract the '
                  'Windows agent ZIP, run Install-TapTether.cmd and then '
                  'Show-Pairing.cmd. Pair with the private token and '
                  'verified TLS fingerprint shown by the agent.')],
            ),
            if (widget.updateOnly)
              const Text('For paired Windows computers with the new agent, '
                  'use My Devices → Update Agent. Older versions can be '
                  'upgraded locally by running the downloaded installer.'),
          ],
        ],
      )),
    );
  }
}
