import 'dart:async';

import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'lan_scan.dart';
import 'computer_store.dart';
import 'scan_report.dart';

/// Injecting a scanner permits deterministic tests of authenticated
/// scan-to-paired-device reconciliation without touching real network hosts.
typedef LanRangeScanner = Future<List<LanHost>> Function(
  String prefix, {
  void Function(int completed, int total)? onProgress,
  void Function(LanHost candidate)? onAgentFound,
  void Function(String ip, List<int> respondingPorts)? onProbe,
  bool Function()? cancelled,
  required int startHost,
  int? endHost,
});

/// Manual on-device /24 scan. No internet API, cloud account or analytics.
class LanScanScreen extends StatefulWidget {
  const LanScanScreen({
    super.key, this.initialIp, this.knownComputers = const [],
    this.macResolver,
    this.verifyPairedAgent,
    this.scanRange,
    this.initialNetwork,
    this.networkDetector,
  });
  final String? initialIp;
  final List<SavedComputer> knownComputers;
  final Future<Map<String, String>> Function()? macResolver;
  /// Triggered only on explicit user scan. The caller authenticates this IP
  /// with a saved TLS certificate pin AND paired-phone credentials before
  /// returning the matching computer name or changing a saved record.
  final Future<String?> Function(String ip)? verifyPairedAgent;
  final LanRangeScanner? scanRange;
  final DetectedLanRange? initialNetwork;
  final Future<DetectedLanRange?> Function()? networkDetector;

  @override
  State<LanScanScreen> createState() => _LanScanScreenState();
}

class _LanScanScreenState extends State<LanScanScreen>
    with WidgetsBindingObserver {
  final _prefix = TextEditingController();
  final _specificIp = TextEditingController();
  DetectedLanRange? _network;
  StreamSubscription<List<ConnectivityResult>>? _connectivityChanges;
  bool _networkChecked = false;

  Future<DetectedLanRange?> _activeNetwork() =>
      widget.networkDetector?.call() ?? detectLanRange();
  bool _checkingSpecificIp = false;
  String? _notRespondingIp;
  bool _editedPrefix = false;
  List<LanHost> _hosts = [];
  Map<String, String> _cachedMacs = {};
  final Map<String, String> _verifiedAgents = {};
  final Set<String> _startedVerification = {};
  final List<Future<void>> _pendingVerifications = [];
  final ScanReport _report = ScanReport();
  bool _busy = false;
  bool _cancel = false;
  int _completed = 0;
  int _total = 254;
  bool _scanWholeNetwork = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadDefault());
    if (widget.networkDetector == null) {
      _connectivityChanges = Connectivity().onConnectivityChanged.listen(
        (transports) {
          if (!localDiscoveryTransport(transports)) {
            _cancel = true;
            if (mounted) setState(() {
              _network = null;
              _networkChecked = true;
              _hosts = [];
              _error = 'Connect to Wi-Fi to scan nearby computers.';
            });
          } else {
            if (_busy) _cancel = true;
            unawaited(_loadDefault());
          }
        },
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_loadDefault());
  }

  Future<void> _loadDefault() async {
    final range = await _activeNetwork();
    if (!mounted) return;
    setState(() {
      _networkChecked = true;
      _network = range;
      if (!_editedPrefix) {
        _prefix.text = range?.activePrefix ??
            (prefixFromIp(widget.initialIp ?? '') ?? '');
      }
      if (_specificIp.text.isEmpty &&
          widget.initialIp != null && widget.initialIp!.isNotEmpty) {
        _specificIp.text = widget.initialIp!;
      }
    });
  }

  @override
  void dispose() {
    _cancel = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_connectivityChanges?.cancel());
    _prefix.dispose();
    _specificIp.dispose();
    super.dispose();
  }

  void _verifyCandidate(LanHost candidate) {
    if (_cancel || !mounted || widget.verifyPairedAgent == null) return;
    if (!candidate.openPorts.contains(48321) && !candidate.agentAnnounced) {
      return;
    }
    if (!_startedVerification.add(candidate.ip)) return;
    final task = _authenticateCandidate(candidate.ip);
    _pendingVerifications.add(task);
  }

  Future<void> _authenticateCandidate(String ip) async {
    try {
      final name = await widget.verifyPairedAgent!(ip);
      if (mounted && !_cancel) {
        _report.add(name == null
            ? '$ip: no matching authenticated saved pairing'
            : '$ip: existing paired computer verified');
        if (name != null) setState(() => _verifiedAgents[ip] = name);
      }
    } catch (_) {
      // A foreign service or an unpaired agent must never interrupt IP Scan.
      _report.add('$ip: authentication check did not complete');
    }
  }

  void _showAgentCandidate(LanHost host) {
    _verifyCandidate(host);
    if (!mounted || _cancel || _hosts.any((item) => item.ip == host.ip)) {
      return;
    }
    // A listening TapTether port can appear while other IPs are still being
    // scanned. Show the candidate immediately while verification runs.
    setState(() {
      _hosts = [..._hosts, host]..sort((a, b) {
        final left = a.ip.split('.').map(int.parse).toList();
        final right = b.ip.split('.').map(int.parse).toList();
        for (var i = 0; i < 4; i++) {
          final diff = left[i].compareTo(right[i]);
          if (diff != 0) return diff;
        }
        return 0;
      });
    });
  }

  Future<void> _startScan() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final wifi = await _activeNetwork();
    if (!mounted) return;
    if (wifi == null) {
      _report.clear();
      _report.add('IP scan skipped: no active Wi-Fi network');
      setState(() {
        _network = null;
        _networkChecked = true;
        _error = 'Connect to Wi-Fi to scan nearby computers. '
            'Cellular networks are not scanned.';
      });
      return;
    }
    _network = wifi;
    if (!_editedPrefix) _prefix.text = wifi.activePrefix;
    final prefix = _prefix.text.trim();
    if (!validPrivate24Prefix(prefix)) {
      setState(() => _error = 'Enter a private IPv4 /24 prefix (e.g. 192.168.1).');
      return;
    }
    // Full-network mode uses the detected CIDR, including the .0/.255
    // addresses that are usable inside a /23 or /22. A custom prefix is
    // always a single /24; selecting one disables full-network mode.
    final wholeNetwork = _scanWholeNetwork &&
        wifi.scanPrefixes.length <= 8;
    final targets = wholeNetwork ? _network!.scanPrefixes : [prefix];
    final bounds = <({int startHost, int endHost})>[
      for (final target in targets)
        wholeNetwork
            ? scanPrefixBounds(_network!, target)
            : (startHost: 1, endHost: 254),
    ];
    final total = bounds.fold<int>(0,
        (count, b) => count + b.endHost - b.startHost + 1);
    _report.clear();
    _report.add('Scan IPs started · Wi-Fi: ${_network?.ip ?? "unknown"} · '
        'Detected CIDR: ${_network?.cidr ?? "unknown"}');
    _report.add('Mode: ${wholeNetwork ? "entire Wi-Fi CIDR" : "single /24"} · '
        'TCP ports: ${lanScanPorts.join(", ")} · Timeout per probe: 450ms');
    for (var i = 0; i < targets.length; i++) {
      _report.add('Planned range: ${targets[i]}.${bounds[i].startHost} - '
          '${targets[i]}.${bounds[i].endHost}');
    }
    setState(() {
      _error = null;
      _hosts = [];
      _cachedMacs = {};
      _verifiedAgents.clear();
      _startedVerification.clear();
      _pendingVerifications.clear();
      _completed = 0;
      _total = total;
      _cancel = false;
      _busy = true;
    });
    try {
      final found = <String, LanHost>{};
      var scannedBefore = 0;
      for (var index = 0; index < targets.length && !_cancel; index++) {
        final target = targets[index];
        final bound = bounds[index];
        _report.add('Scanning $target.0/24 '
            '(host suffixes ${bound.startHost}-${bound.endHost})');
        final group = await (widget.scanRange ?? scanPrivate24)(target,
          startHost: bound.startHost,
          endHost: bound.endHost,
          cancelled: () => _cancel,
          onAgentFound: _showAgentCandidate,
          onProbe: (ip, ports) {
            // A nonresponsive private address is not a meaningful result.
            if (ports.isNotEmpty) {
              _report.add('$ip: TCP open ${ports.join(", ")}');
            }
          },
          onProgress: (done, _) {
            if (mounted) {
              setState(() => _completed = scannedBefore + done);
            }
          },
        );
        _report.add('Range $target.0/24 finished: '
            '${group.length} responsive/announced device(s)');
        scannedBefore += bound.endHost - bound.startHost + 1;
        for (final computer in group) {
          found[computer.ip] = computer;
          _verifyCandidate(computer);
        }
        if (mounted) {
          setState(() {
            _hosts = found.values.toList()..sort((a, b) {
              final aa = a.ip.split('.').map(int.parse).toList();
              final bb = b.ip.split('.').map(int.parse).toList();
              for (var i = 0; i < 4; i++) {
                final diff = aa[i].compareTo(bb[i]);
                if (diff != 0) return diff;
              }
              return 0;
            });
          });
        }
      }
      // Do not declare the scan finished while identity checks are in
      // flight. Results are saved as soon as each individual match succeeds.
      if (!_cancel) {
        await Future.wait(_pendingVerifications);
      }
      _report.add(_cancel
          ? 'Scan stopped early: $_completed of $_total addresses checked'
          : 'IP scan completed: $_completed of $_total addresses checked · '
              '${found.length} discovered device(s) · '
              '${_verifiedAgents.length} paired computer(s) authenticated');
      // A paired, authenticated desktop can read its own ARP cache;
      // mobile iOS cannot directly inspect other devices' MAC addresses.
      if (!_cancel && widget.macResolver != null) {
        final neighbors = await widget.macResolver!();
        if (mounted) setState(() => _cachedMacs = neighbors);
      }
    } catch (_) {
      _report.add('Scan error: scan did not finish (details withheld)');
      if (mounted) {
        setState(() => _error =
            'The scan could not finish. Check Wi-Fi or local-network permission.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkSpecificIp() async {
    if (_checkingSpecificIp || _busy) return;
    final ip = _specificIp.text.trim();
    if (!validPrivate24Prefix(prefixFromIp(ip) ?? '')) {
      setState(() => _error = 'Enter a private IPv4 address, e.g. 192.168.1.77');
      return;
    }
    final wifi = await _activeNetwork();
    if (!mounted) return;
    if (wifi == null) {
      _report.clear();
      _report.add('Manual IP check skipped: no active Wi-Fi network');
      setState(() => _error = 'Connect to Wi-Fi before checking a LAN IP.');
      return;
    }
    _report.add('Manual IP check: $ip · TCP ports ${lanScanPorts.join(", ")}');
    setState(() {
      _checkingSpecificIp = true;
      _notRespondingIp = null;
      _error = null;
    });
    try {
      final found = await checkPrivateLanIp(ip);
      if (!mounted) return;
      _report.add(found == null
          ? '$ip: no tested service responded'
          : '$ip: TCP open ${found.openPorts.join(", ")}'
              '${found.agentAnnounced ? " · agent UDP reply" : ""}');
      _verifyCandidate(found ??
          LanHost(ip: ip, hostname: ip, openPorts: const []));
      setState(() {
        if (found == null) {
          _notRespondingIp = ip;
        } else {
          _hosts = [
            for (final item in _hosts)
              if (item.ip != found.ip) item,
            found,
          ]..sort((a, b) {
            final left = a.ip.split('.').map(int.parse).toList();
            final right = b.ip.split('.').map(int.parse).toList();
            for (var i = 0; i < 4; i++) {
              final diff = left[i].compareTo(right[i]);
              if (diff != 0) return diff;
            }
            return 0;
          });
        }
      });
    } catch (_) {
      _report.add('$ip: manual check failed');
      if (mounted) {
        setState(() => _error = 'Unable to check that LAN IP. '
            'Verify Wi-Fi and local-network permissions.');
      }
    } finally {
      if (mounted) setState(() => _checkingSpecificIp = false);
    }
  }

  String _subtitle(LanHost device) {
    final matches = widget.knownComputers.where((e) =>
        e.host == device.ip && e.macAddress.isNotEmpty);
    final mac = device.macAddress ?? _cachedMacs[device.ip] ??
        (matches.isNotEmpty ? matches.first.macAddress : null);
    final verified = _verifiedAgents[device.ip];
    return '${verified == null ? device.scanSubtitle : 'Paired: $verified · Verified agent'}'
        '${mac == null || mac.isEmpty ? '' : '\nMAC: $mac'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan local network')),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 4),
          if (_networkChecked && _network == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(children: [
                const Icon(Icons.wifi_off, size: 24),
                const SizedBox(width: 12),
                const Expanded(child: Text(
                  'Wi-Fi required for local discovery. Connect to a '
                  'Wi-Fi network to scan. Cellular networks are not scanned.')),
              ]),
            ),
          if (_network != null) ...[ 
            Text('Phone Wi-Fi: ${_network!.ip} · Network: ${_network!.cidr}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (_network!.scanPrefixes.length > 1 &&
                _network!.scanPrefixes.length <= 8)
              SwitchListTile.adaptive(
                key: const ValueKey('scan-whole-network'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Scan entire Wi-Fi network'),
                subtitle: Text('${_network!.cidr} · '
                    '${_network!.scanPrefixes.length} ranges'),
                value: _scanWholeNetwork,
                onChanged: _busy ? null : (value) => setState(() {
                  _scanWholeNetwork = value;
                  if (value) {
                    _editedPrefix = false;
                    _prefix.text = _network!.activePrefix;
                  }
                }),
              ),
            if (_network!.scanPrefixes.length > 1)
              DropdownButtonFormField<String>(
                key: const ValueKey('lan-range-picker'),
                initialValue: _network!.scanPrefixes.contains(_prefix.text)
                    ? _prefix.text : _network!.activePrefix,
                decoration: const InputDecoration(
                  labelText: 'Choose nearby /24 scan range',
                  isDense: true,
                ),
                items: [
                  for (final value in _network!.scanPrefixes)
                    DropdownMenuItem(value: value, child: Text('$value.0/24')),
                ],
                onChanged: _busy ? null : (selected) {
                  if (selected != null) {
                    setState(() {
                      _editedPrefix = true;
                      _scanWholeNetwork = false;
                      _prefix.text = selected;
                    });
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _prefix,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {
              _editedPrefix = true;
              _scanWholeNetwork = false;
            }),
            decoration: const InputDecoration(
              labelText: 'Network prefix',
              hintText: '192.168.1',
              helperText: 'Detects the Wi-Fi subnet; you can also choose a /24 range.',
            ),
          ),
          const SizedBox(height: 12),
          if (_busy) ...[
            LinearProgressIndicator(value: _completed / _total),
            const SizedBox(height: 10),
            Text('Checking $_completed of $_total addresses…'),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: () => _cancel = true,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop scan')),
          ] else
            FilledButton.icon(
              onPressed: _network == null ? null : _startScan,
              icon: const Icon(Icons.radar),
              label: const Text('Start IP scan'),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(
                color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 18),
          Text('Check a specific computer',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(
              key: const ValueKey('check-specific-ip'),
              controller: _specificIp,
              enabled: !_busy && !_checkingSpecificIp,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Computer IP',
                hintText: '192.168.1.77',
              ),
            )),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _busy || _checkingSpecificIp || _network == null
                  ? null : _checkSpecificIp,
              child: Text(_checkingSpecificIp ? 'Checking…' : 'Check IP'),
            ),
          ]),
          if (_notRespondingIp != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('No tested services responded at $_notRespondingIp. '
                      'The computer may still be online with its ports '
                      'closed. This is not proof that it is offline.'),
                  TextButton(
                    onPressed: () => Navigator.pop(context, _notRespondingIp),
                    child: const Text('Use this IP for pairing anyway'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          if (_verifiedAgents.isNotEmpty) ...[
            Text(
              '${_verifiedAgents.length} existing paired computer(s) verified',
              key: const ValueKey('scan-verified-pairs'),
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 8),
          ],
          Text('Devices found: ${_hosts.length}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!_busy && _hosts.isEmpty && _error == null)
            const Text('No devices detected yet. Some networks block discovery '
                'and devices with closed ports may not appear.'),
          for (final device in _hosts)
            Card(child: ListTile(
              leading: Icon(device.platform == 'darwin'
                  ? Icons.laptop_mac
                  : device.agentAnnounced || device.openPorts.contains(48321)
                      ? Icons.desktop_windows_outlined
                      : Icons.devices_other_outlined),
              title: Text(_verifiedAgents[device.ip] ?? device.displayName),
              subtitle: Text(_subtitle(device)),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(context, device.ip),
            )),
          const SizedBox(height: 16),
          ScanReportPanel(
            title: 'Full Scan Output',
            report: _report,
          ),
          const SizedBox(height: 8),
          const ExpansionTile(
            title: Text('About scan results'),
            childrenPadding: EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [Text('Network scans find addresses, not trusted '
                'identities. Tap a result to use its IP for pairing. '
                'A missing or stale MAC address does not establish '
                'whether a computer is online or authorized.')],
          ),
        ],
      )),
    );
  }
}
