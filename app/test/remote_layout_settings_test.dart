import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/remote_layout_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('defaults show trackpad and four quick keys, hide advanced controls',
      () {
    final value = RemoteLayoutSettings.fromJson(null);
    expect(value.trackpadExpanded, true);
    expect(value.keyboardExpanded, false);
    expect(value.arrowsExpanded, false);
    expect(value.moreExpanded, false);
    expect(value.presentationMode, false);
    expect(value.mediaMode, false);
    expect(value.mediaService, 'youtube');
    expect(value.visualMode, 'trackpad');
    expect(value.presentationApp, 'powerPoint');
    expect(value.expandedSections, isEmpty);
    expect(value.quickKeys, defaultRemoteQuickKeys);
  });

  test('remembers personalized per-host preferences and quick key order',
      () async {
    final store = RemoteLayoutStore();
    const custom = RemoteLayoutSettings(
      trackpadExpanded: false,
      keyboardExpanded: true,
      arrowsExpanded: true,
      moreExpanded: true,
      presentationMode: true,
      mediaMode: false,
      mediaService: 'netflix',
      visualMode: 'snapshot',
      presentationApp: 'googleSlides',
      expandedSections: ['editing', 'volume'],
      quickKeys: ['paste', 'enter', 'escape'],
    );
    await store.write('192.168.68.81', custom);
    final loaded = await store.read('192.168.68.81');
    expect(loaded.toJson(), custom.toJson());
    final anotherHost = await store.read('192.168.68.87');
    expect(anotherHost.quickKeys, defaultRemoteQuickKeys);
    expect(anotherHost.trackpadExpanded, true);
    expect(anotherHost.keyboardExpanded, false);
    expect(anotherHost.presentationMode, false);
  });

  test('rejects obsolete or duplicate controls and invalid sections', () {
    final parsed = RemoteLayoutSettings.fromJson({
      'trackpadExpanded': false,
      'quickKeys': ['escape', 'removed', 'escape', 'paste'],
      'expandedSections': ['editing', 'unsupported', 'editing'],
      'presentationMode': true,
      'presentationApp': 'unsupported',
    });
    expect(parsed.quickKeys, ['escape', 'paste']);
    expect(remoteQuickKeyLabels['f12'], 'F12');
    expect(parsed.expandedSections, ['editing']);
    expect(parsed.trackpadExpanded, false);
    expect(parsed.keyboardExpanded, false);
    expect(parsed.presentationMode, true);
    expect(parsed.presentationApp, 'powerPoint');
    expect(parsed.mediaMode, false);
    expect(parsed.mediaService, 'youtube');
    expect(parsed.visualMode, 'trackpad');
  });

  test('malformed preferences restore a usable default remote', () async {
    const storage = FlutterSecureStorage();
    await storage.write(key: 'taptether.remote.layout.v1.192.168.68.81',
        value: '{invalid-json');
    final layout = await RemoteLayoutStore(storage: storage)
        .read('192.168.68.81');
    expect(layout.quickKeys, defaultRemoteQuickKeys);
    expect(layout.trackpadExpanded, true);
  });
}
