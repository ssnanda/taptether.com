import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'phone_ssh_keys.dart';
import 'app_security.dart';

class SshKeyScreen extends StatefulWidget {
  const SshKeyScreen({super.key});
  @override
  State<SshKeyScreen> createState() => _SshKeyScreenState();
}

class _SshKeyScreenState extends State<SshKeyScreen> {
  final _store = PhoneSshKeyStore();
  List<SavedSshKey> _keys = [];
  String? _selected, _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final keys = await _store.listKeys();
      final selected = await _store.selectedId();
      if (mounted) {
        setState(() {
          _keys = keys;
          _selected = selected;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read SSH keys: $e');
    }
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    final field = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: field, autofocus: true, maxLength: 60,
          decoration: const InputDecoration(labelText: 'Key name'),
          onSubmitted: (value) => Navigator.pop(dialog, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, field.text),
              child: const Text('Save')),
        ],
      ),
    );
    field.dispose();
    return result;
  }

  Future<bool> _confirm(String title, String details, String action) async =>
      await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(details),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
              child: Text(action)),
        ],
      )) ?? false;

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await action();
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final name = await _askName('Create SSH key',
        initial: 'My SSH key ${_keys.length + 1}');
    if (name == null || !mounted) return;
    await _perform(() async { await _store.generateNamed(name); });
  }

  Future<String?> _askPassphrase() async {
    final field = TextEditingController();
    final value = await showDialog<String>(context: context, builder: (dialog) =>
        AlertDialog(
          title: const Text('Unlock imported SSH key'),
          content: TextField(controller: field, obscureText: true,
            decoration: const InputDecoration(labelText: 'Private-key passphrase')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog),
                child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialog, field.text),
                child: const Text('Unlock')),
          ],
        ));
    field.dispose();
    return value;
  }

  Future<void> _import() async {
    if (_busy) return;
    final files = await FilePicker.platform.pickFiles(
        type: FileType.any, allowMultiple: false, withData: true);
    if (files == null || files.files.isEmpty || !mounted) return;
    final bytes = files.files.single.bytes;
    if (bytes == null || bytes.length > 1024 * 1024) {
      setState(() => _error = 'Choose an OpenSSH private key below 1 MB.');
      return;
    }
    String pem;
    try {
      pem = utf8.decode(bytes);
    } catch (_) {
      setState(() => _error = 'This is not an OpenSSH text private key.');
      return;
    }
    String? passphrase;
    if (SSHKeyPair.isEncryptedPem(pem)) {
      passphrase = await _askPassphrase();
      if (passphrase == null || !mounted) return;
    }
    if (!mounted) return;
    final name = await _askName('Import SSH key',
        initial: files.files.single.name);
    if (name == null || !mounted) return;
    await _perform(() async {
      await _store.importNamed(name, pem, passphrase: passphrase);
    });
  }

  Future<void> _copyPublic(SavedSshKey key) async {
    await Clipboard.setData(ClipboardData(text: key.publicKey));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Public key copied')));
    }
  }

  Future<void> _export(SavedSshKey key, {required bool private}) async {
    if (private && !await AppSecurity.instance.authenticate(context,
        reason: 'Verify identity to export a private SSH key')) {
      return;
    }
    if (private && !await _confirm('Export PRIVATE SSH key?',
        'The exported file contains an UNENCRYPTED private key. Anyone '
        'with this file can authenticate as you. Only save to trusted storage.',
        'Export private key')) {
      return;
    }
    await _perform(() async {
      final payload = private
          ? await _store.exportPrivatePem(key.id)
          : '${key.publicKey}\n';
      final filename = 'taptether-${key.id}.${private ? 'key' : 'pub'}';
      await FilePicker.platform.saveFile(
        dialogTitle: private ? 'Export private SSH key' : 'Export public SSH key',
        fileName: filename,
        bytes: Uint8List.fromList(utf8.encode(payload)),
      );
    });
  }

  String _fingerprint(SavedSshKey key) {
    final bytes = base64Decode(key.publicKey.split(' ')[1]);
    final sha = base64Encode(sha256.convert(bytes).bytes).replaceAll('=', '');
    return 'SHA256:${sha.substring(0, 15)}…';
  }

  Future<void> _action(SavedSshKey key, String action) async {
    switch (action) {
      case 'default':
        await _perform(() => _store.selectKey(key.id));
        return;
      case 'rename':
        final name = await _askName('Rename SSH key', initial: key.name);
        if (name != null && mounted) {
          await _perform(() => _store.renameKey(key.id, name));
        }
        return;
      case 'copy':
        await _copyPublic(key);
        return;
      case 'exportPublic':
        await _export(key, private: false);
        return;
      case 'exportPrivate':
        await _export(key, private: true);
        return;
      case 'delete':
        if (await _confirm('Delete ${key.name}?',
            'This permanently deletes the private key from this phone. '
            'Computers using only this key will no longer accept SSH login. '
            'Exported copies are not deleted.',
            'Delete key')) {
          await _perform(() => _store.deleteKey(key.id));
        }
        return;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Manage SSH Keys')),
    body: ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        Text('${_keys.length} SSH ${_keys.length == 1 ? 'key' : 'keys'} saved',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.add), label: const Text('Create key'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('Import'))),
        ]),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (_keys.isEmpty)
          const Card(child: Padding(
            padding: EdgeInsets.all(20),
            child: Text('No SSH keys yet. Create or import your first key.'),
          )),
        for (final key in _keys)
          Card(child: ListTile(
            leading: Icon(key.id == _selected
                ? Icons.verified_user_outlined : Icons.key_outlined),
            title: Text(key.name, maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(key.id == _selected ? 'Default SSH key' : 'Ed25519',
                    style: TextStyle(color: key.id == _selected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant)),
                Text(_fingerprint(key), maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
            onTap: () => _action(key, 'default'),
            trailing: PopupMenuButton<String>(
              tooltip: 'Manage ${key.name}', enabled: !_busy,
              onSelected: (selected) => _action(key, selected),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'default', child: Text('Make default')),
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'copy', child: Text('Copy public key')),
                PopupMenuItem(value: 'exportPublic', child: Text('Export public key')),
                PopupMenuItem(value: 'exportPrivate', child: Text('Export private key')),
                PopupMenuItem(value: 'delete', child: Text('Delete key')),
              ],
            ),
          )),
        const SizedBox(height: 12),
        const ExpansionTile(
          title: Text('How to authorize an SSH key'),
          childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 14),
          children: [
            Text('Copy the PUBLIC key into your computer’s '
              '~/.ssh/authorized_keys or use the verified SSH installer. '
              'Always verify the server fingerprint independently. '
              'Never share private keys.'),
          ],
        ),
      ],
    ),
  );
}
