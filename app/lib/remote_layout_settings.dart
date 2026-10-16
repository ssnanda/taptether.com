import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Buttons that can be pinned to the compact remote toolbar.
/// IDs are stable across releases and independent of translated labels.
const Map<String, String> remoteQuickKeyLabels = {
  'escape': 'Esc',
  'tab': 'Tab',
  'enter': 'Enter',
  'backspace': '⌫',
  'up': '↑',
  'down': '↓',
  'left': '←',
  'right': '→',
  'copy': 'Copy',
  'paste': 'Paste',
  'selectAll': 'Select all',
  'undo': 'Undo',
  'find': 'Find',
  'newTab': 'New tab',
  'switchApp': 'Switch app',
  'home': 'Home',
  'end': 'End',
  'pageUp': 'PgUp',
  'pageDown': 'PgDn',
  'f1': 'F1', 'f2': 'F2', 'f3': 'F3', 'f4': 'F4',
  'f5': 'F5', 'f6': 'F6', 'f7': 'F7', 'f8': 'F8',
  'f9': 'F9', 'f10': 'F10', 'f11': 'F11', 'f12': 'F12',
  'volumeDown': 'Vol −',
  'mute': 'Mute',
  'volumeUp': 'Vol +',
};

const List<String> defaultRemoteQuickKeys =
    <String>['escape', 'tab', 'enter', 'backspace'];

const Set<String> remoteAdvancedSections =
    <String>{'editing', 'extended', 'volume', 'power', 'preferences'};

/// Local, per-computer view preferences. Never stored on a remote agent.
class RemoteLayoutSettings {
  const RemoteLayoutSettings({
    this.trackpadExpanded = true,
    this.keyboardExpanded = false,
    this.arrowsExpanded = false,
    this.moreExpanded = false,
    this.presentationMode = false,
    this.mediaMode = false,
    this.mediaService = 'youtube',
    this.visualMode = 'trackpad',
    this.presentationApp = 'powerPoint',
    this.expandedSections = const <String>[],
    this.quickKeys = defaultRemoteQuickKeys,
  });

  final bool trackpadExpanded;
  final bool keyboardExpanded;
  final bool arrowsExpanded;
  final bool moreExpanded;
  final bool presentationMode;
  final bool mediaMode;
  final String mediaService;
  final String visualMode;
  final String presentationApp;
  final List<String> expandedSections;
  final List<String> quickKeys;

  Map<String, Object> toJson() => {
    'trackpadExpanded': trackpadExpanded,
    'keyboardExpanded': keyboardExpanded,
    'arrowsExpanded': arrowsExpanded,
    'moreExpanded': moreExpanded,
    'presentationMode': presentationMode,
    'mediaMode': mediaMode,
    'mediaService': mediaService,
    'visualMode': visualMode,
    'presentationApp': presentationApp,
    'expandedSections': expandedSections,
    'quickKeys': quickKeys,
  };

  static RemoteLayoutSettings fromJson(Object? decoded) {
    if (decoded is! Map) return const RemoteLayoutSettings();
    final values = Map<String, dynamic>.from(decoded);
    final storedKeys = values['quickKeys'];
    final storedSections = values['expandedSections'];
    final keys = storedKeys is List
        ? storedKeys.whereType<String>()
            .where(remoteQuickKeyLabels.containsKey).toSet().toList()
        : defaultRemoteQuickKeys.toList();
    final sections = storedSections is List
        ? storedSections.whereType<String>()
            .where(remoteAdvancedSections.contains).toSet().toList()
        : <String>[];
    return RemoteLayoutSettings(
      trackpadExpanded: values['trackpadExpanded'] is bool
          ? values['trackpadExpanded'] as bool : true,
      keyboardExpanded: values['keyboardExpanded'] == true,
      arrowsExpanded: values['arrowsExpanded'] == true,
      moreExpanded: values['moreExpanded'] == true,
      presentationMode: values['presentationMode'] == true,
      mediaMode: values['presentationMode'] != true && values['mediaMode'] == true,
      mediaService: const {'youtube', 'netflix'}.contains(values['mediaService'])
          ? values['mediaService'] as String : 'youtube',
      visualMode: const {'trackpad', 'snapshot', 'live'}
              .contains(values['visualMode'])
          ? values['visualMode'] as String : 'trackpad',
      presentationApp: const {'powerPoint', 'googleSlides', 'keynote'}
              .contains(values['presentationApp'])
          ? values['presentationApp'] as String
          : 'powerPoint',
      expandedSections: sections,
      quickKeys: keys,
    );
  }
}

class RemoteLayoutStore {
  RemoteLayoutStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(String host) =>
      'taptether.remote.layout.v1.${host.trim().toLowerCase()}';

  Future<RemoteLayoutSettings> read(String host) async {
    try {
      final json = await _storage.read(key: _key(host));
      return json == null ? const RemoteLayoutSettings()
          : RemoteLayoutSettings.fromJson(jsonDecode(json));
    } catch (_) {
      // Layout corruption must never stop a remote from connecting.
      return const RemoteLayoutSettings();
    }
  }

  Future<void> write(String host, RemoteLayoutSettings value) async =>
      _storage.write(key: _key(host), value: jsonEncode(value.toJson()));
}
