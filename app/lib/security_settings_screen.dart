import 'package:flutter/material.dart';
import 'app_security.dart';
import 'appearance.dart';

class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key});
  @override
  State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  final _security = AppSecurity.instance;
  bool _busy = false;
  bool _biometricsAvailable = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _security.addListener(_changed);
    _checkBiometrics();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _checkBiometrics() async {
    final yes = await _security.supportsBiometrics();
    if (mounted) setState(() => _biometricsAvailable = yes);
  }

  Future<String?> _askPin(String title) async {
    final field = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: field, autofocus: true, obscureText: true,
          keyboardType: TextInputType.number, maxLength: 6,
          decoration: const InputDecoration(
              labelText: '6-digit PIN', counterText: ''),
          onSubmitted: (pin) => Navigator.pop(dialog, pin),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, field.text),
              child: const Text('Continue')),
        ],
      ),
    );
    field.dispose();
    return entered;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPin() async {
    if (_security.enabled &&
        !await _security.authenticate(context,
            reason: 'Verify identity before changing PIN')) {
      return;
    }
    if (!mounted) return;
    final first = await _askPin('Choose your app PIN');
    if (first == null || !mounted) return;
    if (!AppSecurity.isValidPin(first)) {
      setState(() => _error = 'Enter exactly six digits.');
      return;
    }
    final second = await _askPin('Confirm your app PIN');
    if (second == null || !mounted) return;
    if (first != second) {
      setState(() => _error = 'PINs do not match. Nothing was changed.');
      return;
    }
    await _run(() => _security.setPin(first));
  }

  Future<void> _toggleLock(bool value) async {
    if (value) {
      await _setPin();
    } else {
      if (!await _security.authenticate(context,
          reason: 'Verify identity to turn off app lock')) {
        return;
      }
      await _run(_security.disable);
    }
  }

  Future<void> _toggleBiometrics(bool value) async {
    if (value) {
      if (!await _security.verifyBiometrics('Enable biometric app unlock')) {
        if (mounted) {
          setState(() => _error = 'Biometric verification was not completed.');
        }
        return;
      }
    } else {
      if (!await _security.authenticate(context,
          reason: 'Verify identity to change security settings')) {
        return;
      }
    }
    await _run(() => _security.setBiometrics(value));
  }

  @override
  void dispose() {
    _security.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Security & Appearance')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Protect your saved devices and keys with an optional app lock.'),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null) Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(_error!, style: TextStyle(
            color: Theme.of(context).colorScheme.error)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.lock_outline),
        title: const Text('Require app unlock'),
        subtitle: const Text('Set a six-digit PIN to enable app lock'),
        value: _security.enabled,
        onChanged: _busy ? null : _toggleLock,
      ),
      if (_security.enabled) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.fingerprint),
          title: const Text('Face ID / Touch ID / biometrics'),
          subtitle: Text(_biometricsAvailable
              ? 'Use biometrics with your app PIN as fallback'
              : 'No enrolled biometric authenticator available'),
          value: _security.biometricEnabled,
          onChanged: _busy || !_biometricsAvailable
              ? null : _toggleBiometrics,
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<int>(
          initialValue: _security.delaySeconds,
          decoration: const InputDecoration(labelText: 'Lock after backgrounding'),
          items: const [
            DropdownMenuItem(value: 0, child: Text('Immediately')),
            DropdownMenuItem(value: 30, child: Text('30 seconds')),
            DropdownMenuItem(value: 60, child: Text('1 minute')),
            DropdownMenuItem(value: 300, child: Text('5 minutes')),
          ],
          onChanged: _busy ? null : (value) {
            if (value != null) _run(() => _security.setDelay(value));
          },
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: _busy ? null : _setPin,
            icon: const Icon(Icons.password),
            label: const Text('Change app PIN')),
        OutlinedButton.icon(
            onPressed: _busy ? null : () {
              Navigator.pop(context);
              _security.lock();
            },
            icon: const Icon(Icons.lock),
            label: const Text('Lock now')),
      ],
      const Divider(height: 40),
      Text('Appearance',
          style: Theme.of(context).textTheme.titleLarge),
      ValueListenableBuilder<ThemeMode>(
        valueListenable: AppearanceController.instance,
        builder: (context, mode, _) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Dark appearance'),
          subtitle: const Text('Light theme is the default'),
          secondary: const Icon(Icons.brightness_6_outlined),
          value: mode == ThemeMode.dark,
          onChanged: (dark) async {
            try {
              await AppearanceController.instance.setDark(dark);
            } catch (_) {
              if (mounted) {
                setState(() => _error = 'Could not save appearance preference.');
              }
            }
          },
        ),
      ),
      const SizedBox(height: 12),
      const ExpansionTile(
        title: Text('Privacy & security details'),
        childrenPadding: EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [Text('Private SSH key export requires another unlock '
            'check when app lock is enabled. Your PIN stays on the phone.')],
      ),
    ]),
  );
}
