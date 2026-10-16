import 'package:flutter/material.dart';
import 'computer_store.dart';
import 'discovery.dart';
import 'network_location.dart';

/// Lists devices with previously verified TLS fingerprints and phone identity.
/// Discovery alone is never treated as trusted pairing.
class DeviceManagerScreen extends StatefulWidget {
  const DeviceManagerScreen({super.key, required this.store,
    required this.onConnect, required this.onUpdate});
  final ComputerStore store;
  final Future<void> Function(SavedComputer) onConnect;
  final Future<void> Function(SavedComputer) onUpdate;
  @override
  State<DeviceManagerScreen> createState() => _DeviceManagerScreenState();
}

class _DeviceManagerScreenState extends State<DeviceManagerScreen> {
  List<SavedComputer> _computers = [];
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final updated = await widget.store.read();
      if (mounted) {
        setState(() {
          _computers = updated;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Cannot load saved computers: $e');
    }
  }

  Future<String?> _ask(String title, String label, String initial) async {
    final field = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: field, autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.pop(dialog, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, field.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    field.dispose();
    return value;
  }

  Future<void> _edit(SavedComputer device, {String? name, String? host, String? location}) async {
    if (_busy) return;
    final nextName = (name ?? device.name).trim();
    final nextHost = (host ?? device.host).trim();
    if (nextName.isEmpty || nextName.length > 80 ||
        !isPrivateIPv4(nextHost)) {
      setState(() => _error = 'Use a name (1–80 characters) and a private LAN IPv4 address.');
      return;
    }
    if (_computers.any((other) => other.id != device.id &&
        other.host == nextHost)) {
      setState(() => _error = 'Another saved device uses that IP address.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await widget.store.upsert(SavedComputer(
        id: device.id, name: nextName, host: nextHost,
        token: device.token, fingerprint: device.fingerprint,
        platform: device.platform, deviceId: device.deviceId,
        customName: name == null ? device.customName : true,
        macAddress: device.macAddress,
        location: location ?? device.location,
      ));
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(SavedComputer device) async {
    final approved = await showDialog<bool>(context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Forget ${device.name}?'),
        content: const Text(
          'Erases this phone’s saved pairing data and TLS pin. '
          'The phone is not revoked on the computer. '
          'Revoke it separately using the agent controls if needed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Forget')),
        ],
      ),
    );
    if (approved != true || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.store.remove(device.id);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(SavedComputer device, String action) async {
    switch (action) {
      case 'connect':
        await widget.onConnect(device);
        if (mounted) Navigator.pop(context);
        return;
      case 'update':
        await widget.onUpdate(device);
        if (mounted) await _refresh();
        return;
      case 'rename':
        final name = await _ask('Rename device', 'Display name', device.name);
        if (name != null && mounted) await _edit(device, name: name);
        return;
      case 'address':
        final host = await _ask('Update LAN address',
            'Private IPv4', device.host);
        if (host != null && mounted) await _edit(device, host: host);
        return;
      case 'home':
      case 'office':
      case 'other':
        await _edit(device, location: action);
        return;
      case 'forget':
        await _forget(device);
        return;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Manage Devices')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Expanded(child: Text(
            '${_computers.length} saved ${_computers.length == 1 ? 'computer' : 'computers'}',
            style: Theme.of(context).textTheme.titleMedium)),
          TextButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.add),
            label: const Text('Add computer'),
          ),
        ]),
        const SizedBox(height: 8),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Padding(
          padding: const EdgeInsets.all(8),
          child: Text(_error!, style: TextStyle(
              color: Theme.of(context).colorScheme.error)),
        ),
        if (_computers.isEmpty) const Card(child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('No paired computers. Add one using verified '
            'agent pairing information or a QR code.'),
        )),
        for (final device in _computers)
          Card(child: ListTile(
            leading: Icon(device.platform == 'darwin'
                ? Icons.laptop_mac : Icons.computer),
            title: Text(device.name, maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: Text('${device.host} · ${deviceLocations[device.location]!}'
                '${device.macAddress.isEmpty ? '' : ' · MAC: ${device.macAddress}'}',
                maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: _busy ? null : () => _action(device, 'connect'),
            trailing: PopupMenuButton<String>(
              tooltip: 'Manage ${device.name}', enabled: !_busy,
              onSelected: (action) => _action(device, action),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'connect', child: Text('Connect')),
                if (device.platform == 'linux' || device.platform == 'darwin' ||
                    device.platform == 'windows')
                  const PopupMenuItem(
                    value: 'update',
                    child: Row(children: [
                      Icon(Icons.system_update_alt),
                      SizedBox(width: 8),
                      Text('Update Agent'),
                    ]),
                  ),
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                const PopupMenuItem(value: 'address', child: Text('Change LAN address')),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'home', child: Text('Location: Home')),
                const PopupMenuItem(value: 'office', child: Text('Location: Office')),
                const PopupMenuItem(value: 'other', child: Text('Location: Other')),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'forget', child: Text('Forget device')),
              ],
            ),
          )),
        const SizedBox(height: 12),
        const ExpansionTile(
          title: Text('How device trust is preserved'),
          childrenPadding: EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [Text('Saved connections retain their verified TLS '
              'fingerprint and authentication. Changing an address does '
              'not trust a different computer.')],
        ),
      ],
    ),
  );
}
