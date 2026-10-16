import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'computer_store.dart';
import 'remote_layout_settings.dart';
import 'presentation_mode.dart';
import 'media_remote.dart';
import 'visual_mode.dart';
import 'visual_transport.dart';
import 'visual_surface.dart';
import 'lan_scan.dart';
import 'network_location.dart';
import 'device_recovery.dart';
import 'device_visibility.dart';
import 'clipboard_chunks.dart';
import 'appearance.dart';
import 'app_security.dart';
import 'security_settings_screen.dart';
import 'device_manager_screen.dart';
import 'discovery.dart';
import 'phone_identity.dart';
import 'qr_pairing.dart';
import 'ssh_key_screen.dart';
import 'install_agent_screen.dart';
import 'lan_scan_screen.dart';
import 'scan_report.dart';
import 'agent_update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:url_launcher/url_launcher.dart';

final RouteObserver<ModalRoute<dynamic>> _remoteRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();

void main() => runApp(const TapTetherApp());

class TapTetherApp extends StatefulWidget {
  const TapTetherApp({super.key});
  @override
  State<TapTetherApp> createState() => _TapTetherAppState();
}

class _TapTetherAppState extends State<TapTetherApp> {
  @override
  void initState() {
    super.initState();
    unawaited(AppearanceController.instance.load());
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: AppearanceController.instance,
    builder: (context, mode, _) => MaterialApp(
      title: 'TapTether',
      debugShowCheckedModeBanner: false,
      navigatorObservers: [_remoteRouteObserver],
      theme: TapTetherPalette.light(),
      darkTheme: TapTetherPalette.dark(),
      themeMode: mode,
      builder: (context, navigator) => AppLockGate(
        child: navigator ?? const SizedBox.shrink(),
      ),
      home: const RemoteScreen(),
    ),
  );
}

/// Pin the locally generated certificate. Never accept arbitrary certificates.
/// No cloud, analytics SDK, or outbound endpoint exists in this app.
class LocalAgent {
  HttpClient? _client;
  Uri? _base;
  String? _token;
  PhoneIdentity? _identity;
  String? _deviceId;
  String? _session;
  DateTime? _sessionExpires;
  bool _shutdownEnabled = false;
  bool _screenCaptureSupported = false;
  bool get screenCaptureSupported => _screenCaptureSupported;
  String? _reportedHostname;
  String? _reportedPlatform;
  String? _reportedMacAddress;
  String? get reportedMacAddress => _reportedMacAddress;
  bool get shutdownEnabled => _shutdownEnabled;
  String? get reportedHostname => _reportedHostname;
  String? get reportedPlatform => _reportedPlatform;

  bool get configured => _base != null && _client != null;

  void configure(String host, String token, String fingerprint, {
    PhoneIdentity? identity, String? deviceId,
  }) {
    host = host.trim();
    final expected = fingerprint.replaceAll(RegExp(r'[^a-fA-F0-9]'), '').toUpperCase();
    if (expected.length != 64) {
      throw const FormatException('Enter the complete 64-character TLS SHA-256 fingerprint.');
    }
    if (token.trim().length < 20 && (identity == null || deviceId == null)) {
      throw const FormatException('Enter the pairing token printed by the agent.');
    }
    if (!_isLocalHost(host)) {
      throw const FormatException('Only RFC1918 private IPv4 or .local hosts are allowed.');
    }
    _client?.close(force: true);
    final context = SecurityContext(withTrustedRoots: false);
    final client = HttpClient(context: context);
    client.connectionTimeout = const Duration(seconds: 4);
    client.badCertificateCallback = (cert, _, __) {
      try {
        final b64 = cert.pem
            .replaceAll('-----BEGIN CERTIFICATE-----', '')
            .replaceAll('-----END CERTIFICATE-----', '')
            .replaceAll(RegExp(r'\s+'), '');
        final digest = sha256.convert(base64Decode(b64)).toString().toUpperCase();
        return digest == expected;
      } catch (_) {
        return false;
      }
    };
    _client = client;
    _base = Uri(scheme: 'https', host: host, port: 48321);
    _token = token.trim();
    _identity = identity;
    _deviceId = deviceId;
    _session = null;
    _sessionExpires = null;
    _reportedHostname = null;
    _reportedPlatform = null;
    _reportedMacAddress = null;
    _shutdownEnabled = false;
    _screenCaptureSupported = false;
  }

  static bool _isLocalHost(String host) {
    if (RegExp(r'^[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.local$').hasMatch(host)) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final oct = parts.map(int.tryParse).toList();
    if (oct.any((v) => v == null || v < 0 || v > 255)) return false;
    final a = oct[0]!, b = oct[1]!;
    return a == 10 || (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) || a == 127;
  }

  Future<Map<String, dynamic>> _postJson(
      String endpoint, Map<String, Object> body, String bearer) async {
    if (!configured) throw StateError('Agent is not configured.');
    final request = await _client!.postUrl(_base!.resolve(endpoint));
    request.headers.contentType = ContentType.json;
    if (bearer.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 6));
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != 200) {
      throw StateError('Agent $endpoint: HTTP ${response.statusCode}');
    }
    final result = jsonDecode(text);
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Unexpected agent authentication response.');
    }
    return result;
  }

  Future<String> enrollPhone(PhoneIdentity phone, String name) async {
    if ((_token ?? '').length < 20) {
      throw StateError('Owner pairing token is required for enrollment.');
    }
    final result = await _postJson('/api/pair', {
      'name': name,
      'publicKey': phone.encodedPublicKey,
    }, _token!);
    final id = result['id'];
    if (id is! String || id != phone.id) {
      throw StateError('Agent device identity does not match this phone.');
    }
    return id;
  }

  Future<String> _bearer() async {
    final identity = _identity;
    final id = _deviceId;
    if (identity == null || id == null) return _token ?? '';
    final cached = _session;
    if (cached != null && _sessionExpires != null &&
        _sessionExpires!.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return cached;
    }
    final challenge = await _postJson('/api/auth/challenge', {'id': id}, '');
    final nonce = challenge['nonce'];
    if (nonce is! String || nonce.length < 32) {
      throw const FormatException('Agent challenge is invalid.');
    }
    final signature = await identity.signChallenge(nonce);
    final response = await _postJson('/api/auth/session', {
      'id': id, 'nonce': nonce, 'signature': signature,
    }, '');
    final token = response['token'];
    if (token is! String || token.length < 32) {
      throw const FormatException('Agent session invalid.');
    }
    _session = token;
    _sessionExpires = DateTime.now().add(const Duration(minutes: 14));
    return token;
  }

  void usePhoneKey(PhoneIdentity identity, String id) {
    _identity = identity;
    _deviceId = id;
    _token = null;
    _session = null;
    _sessionExpires = null;
  }

  Future<void> send(String type, [Map<String, Object> details = const {}]) async {
    if (!configured) throw StateError('Connect to your local agent first.');
    final req = await _client!.postUrl(_base!.resolve('/api/control'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'type': type, ...details}));
    final res = await req.close().timeout(const Duration(seconds: 5));
    if (res.statusCode != 204) {
      final body = await utf8.decoder.bind(res).join();
      throw StateError('Agent response ${res.statusCode}: $body');
    }
    await res.drain<void>();
  }

  Future<String?> agentVersion() async {
    if (!configured) return null;
    try {
      final request = await _client!.getUrl(_base!.resolve('/api/info'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
      final response = await request.close().timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = jsonDecode(await utf8.decoder.bind(response).join());
      if (body is Map && body['version'] is String) {
        _shutdownEnabled = body['shutdownEnabled'] == true;
        _screenCaptureSupported = body['screenCaptureSupported'] == true;
        final name = body['hostname'];
        if (name is String &&
            RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$').hasMatch(name)) {
          _reportedHostname = name;
        }
        final macAddress = body['macAddress'];
        if (macAddress is String &&
            RegExp(r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(macAddress)) {
          _reportedMacAddress = macAddress.toUpperCase();
        }
        final platform = body['platform'];
        if (platform == 'linux' || platform == 'darwin' || platform == 'windows') {
          _reportedPlatform = platform as String;
        }
        return body['version'] as String;
      }
    } catch (_) {
      // Older agents without this endpoint remain compatible.
    }
    return null;
  }

  /// Best-effort ARP neighbor inventory from the authenticated agent.
  Future<Map<String, String>> trustedLanNeighbors() async {
    if (!configured) return {};
    try {
      final request = await _client!.getUrl(_base!.resolve('/api/neighbors'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return {};
      }
      final decoded = jsonDecode(await utf8.decoder.bind(response).join());
      if (decoded is! List || decoded.length > 1024) return {};
      final result = <String, String>{};
      for (final item in decoded) {
        if (item is! Map || item['ip'] is! String || item['mac'] is! String) {
          continue;
        }
        final ip = item['ip'] as String;
        final mac = item['mac'] as String;
        if (isPrivateIPv4(ip) &&
            RegExp(r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(mac)) {
          result[ip] = mac.toUpperCase();
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  /// Existing agents that lack this endpoint still use the SSH/local updater.
    Future<bool> requestUpdate() async {
    if (!configured) throw StateError('Connect to a paired computer first.');
    final req = await _client!.postUrl(_base!.resolve('/api/update'));
    req.headers.contentType = ContentType.json;
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
    req.write(jsonEncode({'confirm': true}));
    final res = await req.close().timeout(const Duration(seconds: 8));
    final result = res.statusCode;
    await res.drain<void>();
    if (result == 202) return true;
    if (result == 404 || result == 501) return false;
    throw StateError('Computer could not start the update (HTTP $result).');
  }


  Future<void> openMedia(String service, String query) async {
    if (!configured) throw StateError('Connect to a paired computer first.');
    final req = await _client!.postUrl(_base!.resolve('/api/media/open'));
    req.headers.contentType = ContentType.json;
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
    req.write(jsonEncode({'service': service, 'query': query}));
    final res = await req.close().timeout(const Duration(seconds: 8));
    if (res.statusCode != 204) {
      final explanation = await utf8.decoder.bind(res).join();
      throw StateError(explanation.trim().isNotEmpty
          ? explanation.trim()
          : 'Computer could not open the media service.');
    }
    await res.drain<void>();
  }

  Future<ScreenFrame> snapshot() async {
    if (!configured) throw StateError('Connect to a paired computer first.');
    final req = await _client!.getUrl(_base!.resolve('/api/snapshot'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
    final response = await req.close().timeout(const Duration(seconds: 7));
    if (response.statusCode != 200) {
      final explanation = await utf8.decoder.bind(response).join();
      throw StateError(explanation.trim().isEmpty
          ? 'Screen capture unavailable (HTTP ${response.statusCode}).'
          : explanation.trim());
    }
    final width = int.tryParse(response.headers.value('x-screen-width') ?? '');
    final height = int.tryParse(response.headers.value('x-screen-height') ?? '');
    if (width == null || height == null || width < 1 || height < 1 ||
        width > 1280 || height > 720) {
      await response.drain<void>();
      throw const FormatException('Agent sent invalid screen dimensions.');
    }
    final output = BytesBuilder(copy: false);
    await for (final bytes in response.timeout(const Duration(seconds: 8))) {
      output.add(bytes);
      if (output.length > 2 << 20) {
        throw const FormatException('Screenshot exceeds safe transfer size.');
      }
    }
    return ScreenFrame(output.takeBytes(), width, height);
  }

  Stream<ScreenFrame> liveFrames() async* {
    if (!configured) throw StateError('Connect to a paired computer first.');
    final req = await _client!.getUrl(_base!.resolve('/api/live'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
    final response = await req.close().timeout(const Duration(seconds: 7));
    if (response.statusCode != 200) {
      final explanation = await utf8.decoder.bind(response).join();
      throw StateError(explanation.trim().isEmpty
          ? 'Live video unavailable (HTTP ${response.statusCode}).'
          : explanation.trim());
    }
    final frames = MjpegFrameDecoder();
    await for (final bytes in response) {
      for (final frame in frames.add(bytes)) {
        yield frame;
      }
    }
  }

  void disconnect() {
    _client?.close(force: true);
    _client = null;
    _base = null;
    _token = null;
    _identity = null;
    _deviceId = null;
    _session = null;
    _sessionExpires = null;
    _shutdownEnabled = false;
    _screenCaptureSupported = false;
    _reportedHostname = null;
    _reportedPlatform = null;
    _reportedMacAddress = null;
  }
}

class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});
  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen>
    with WidgetsBindingObserver, RouteAware {
  final agent = LocalAgent();
  final deviceStore = ComputerStore();
  final remoteLayoutStore = RemoteLayoutStore();
  final networkLocationStore = NetworkLocationStore();
  Timer? _heartbeatTimer;
  StreamSubscription<List<ConnectivityResult>>? _networkChanges;
  DetectedLanRange? _wifiRange;
  String? _detectedLocation;
  String _locationFilter = 'automatic';
  bool _showOffline = false;
  bool _checkingHeartbeat = false;
  bool _scanningToReconcile = false;
  final Set<String> _scanVerifiedDeviceIds = {};
  final ScanReport _discoveryReport = ScanReport();
  DateTime? _lastTcpRecoveryAt;
  String? _lastTcpRecoveryNetwork;
  String? _lastNetworkId;
  String? _activeDeviceId;
  final Map<String, bool> _online = {};
  RemoteLayoutSettings _remoteLayout = const RemoteLayoutSettings();
  String? _connectedPlatform;
  bool _connectionLost = false;
  bool _agentInputDenied = false;
  String? _connectionTechnical;
  bool _retryingConnection = false;
  List<SavedComputer> savedComputers = [];
  List<DiscoveredDevice> nearbyComputers = [];
  bool searching = false;
  bool installingAgent = false;
  bool _showPairForm = false;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  String? discoveredName;
  final host = TextEditingController();
  final token = TextEditingController();
  final pin = TextEditingController();
  final typing = TextEditingController();
  String status = 'Not connected';
  String installedVersion = '…';
  String? availableAppVersion;
  String? availableAgentVersion;
  String? connectedAgentVersion;
  String? _latestReleaseVersion;
  bool _macShortcuts = false;
  bool _haptics = true;
  Timer? _snapshotTimer;
  StreamSubscription<ScreenFrame>? _liveFrames;
  ScreenFrame? _currentFrame;
  String? _screenError;
  bool _screenBusy = false;
  bool _appForeground = true;
  bool _pageVisible = true;
  bool _refreshAfterCapture = false;
  Orientation? _lastRemoteOrientation;
  int _screenEpoch = 0;

  bool get _viewingScreen => agent.configured && !_connectionLost &&
      _appForeground && _pageVisible &&
      (_remoteLayout.trackpadExpanded ||
          (mounted && MediaQuery.orientationOf(context) == Orientation.landscape)) &&
      !_remoteLayout.mediaMode && !_remoteLayout.presentationMode &&
      agent.screenCaptureSupported &&
      VisualModePolicy.normalize(_remoteLayout.visualMode) != 'trackpad';

  void _stopScreen() {
    _screenEpoch++;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    final prior = _liveFrames;
    _liveFrames = null;
    if (prior != null) unawaited(prior.cancel());
    _screenBusy = false;
    _refreshAfterCapture = false;
    _currentFrame = null;
    _screenError = null;
  }

  void _syncScreen() {
    _stopScreen();
    if (!_viewingScreen) return;
    final epoch = _screenEpoch;
    if (_remoteLayout.visualMode == 'snapshot') {
      unawaited(_refreshScreenshot());
      _snapshotTimer = Timer.periodic(VisualModePolicy.snapshotInterval,
          (_) => unawaited(_refreshScreenshot()));
    } else if (_remoteLayout.visualMode == 'live') {
      _screenBusy = true;
      _liveFrames = agent.liveFrames().listen((frame) {
        if (!mounted || _screenEpoch != epoch || !_viewingScreen) return;
        setState(() {
          _currentFrame = frame;
          _screenBusy = false;
          _screenError = null;
        });
      }, onError: (Object error) {
        if (!mounted || _screenEpoch != epoch) return;
        setState(() {
          _screenBusy = false;
          _screenError = error.toString();
        });
      }, onDone: () {
        if (!mounted || _screenEpoch != epoch) return;
        setState(() {
          _screenBusy = false;
          _screenError ??= 'Live stream stopped. Reopen Live to retry.';
        });
      }, cancelOnError: true);
    }
  }

  Future<void> _refreshScreenshot() async {
    if (!_viewingScreen || _remoteLayout.visualMode != 'snapshot') return;
    if (_screenBusy) {
      _refreshAfterCapture = true;
      return;
    }
    _refreshAfterCapture = false;
    final epoch = _screenEpoch;
    _screenBusy = true;
    if (mounted) setState(() {});
    try {
      final frame = await agent.snapshot();
      if (!mounted || _screenEpoch != epoch) return;
      setState(() {
        _currentFrame = frame;
        _screenError = null;
      });
    } catch (error) {
      if (mounted && _screenEpoch == epoch) {
        setState(() => _screenError = error.toString());
      }
    } finally {
      if (mounted && _screenEpoch == epoch) {
        setState(() => _screenBusy = false);
        if (_refreshAfterCapture) {
          _refreshAfterCapture = false;
          unawaited(_refreshScreenshot());
        }
      }
    }
  }


  @override
  void initState() {
    super.initState();
    unawaited(loadInstalledVersion());
    unawaited(checkForUpdates());
    unawaited(loadComputers());
    unawaited(_refreshNetworkLocation());
    _networkChanges = Connectivity().onConnectivityChanged.listen((_) {
      unawaited(_refreshNetworkLocation());
    });
    WidgetsBinding.instance.addObserver(this);
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed) {
        unawaited(_refreshNetworkLocation());
        unawaited(_refreshHeartbeats());
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) _remoteRouteObserver.subscribe(this, route);
    final orientation = MediaQuery.orientationOf(context);
    if (_lastRemoteOrientation != orientation) {
      _lastRemoteOrientation = orientation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncScreen();
      });
    }
  }

  @override
  void didPushNext() {
    _pageVisible = false;
    _stopScreen();
  }

  @override
  void didPopNext() {
    _pageVisible = true;
    _syncScreen();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    if (_appForeground) {
      _syncScreen();
      unawaited(_refreshNetworkLocation());
      unawaited(_refreshHeartbeats());
    } else {
      _stopScreen();
    }
  }

  Future<void> _refreshNetworkLocation() async {
    final current = await detectLanRange();
    final label = await networkLocationStore.locationFor(current);
    final identity = networkLocationStore.identifier(current);
    if (mounted) {
      final changed = _lastNetworkId != identity;
      setState(() {
        if (changed) _online.clear();
        _lastNetworkId = identity;
        _wifiRange = current;
        _detectedLocation = label;
      });
      if (changed && savedComputers.isNotEmpty && current != null) {
        unawaited(_refreshHeartbeats());
      }
    }
  }

  Future<bool> _pingSavedDevice(
      SavedComputer device, PhoneIdentity? phone, {String? atHost}) async {
    final connection = LocalAgent();
    try {
      connection.configure(atHost ?? device.host, device.token, device.fingerprint,
          identity: device.deviceId.isNotEmpty ? phone : null,
          deviceId: device.deviceId.isNotEmpty ? device.deviceId : null);
      await connection.send('ping');
      return true;
    } catch (_) {
      return false;
    } finally {
      connection.disconnect();
    }
  }

  Future<void> _refreshHeartbeats({bool forceRecovery = false}) async {
    if (_checkingHeartbeat || _scanningToReconcile ||
        savedComputers.isEmpty) {
      return;
    }
    // Saved device heartbeats are also LAN traffic; do not probe private
    // cellular/VPN addresses while Wi-Fi is unavailable.
    final activeWifi = await detectLanRange();
    if (!mounted) return;
    if (activeWifi == null) {
      setState(() => _online.clear());
      return;
    }
    _checkingHeartbeat = true;
    if (mounted) setState(() {});
    try {
      PhoneIdentity? phone;
      try {
        if (savedComputers.any((d) => d.deviceId.isNotEmpty)) {
          phone = await PhoneIdentity.loadOrCreate();
        }
      } catch (_) {}
      final snapshot = savedComputers.toList();
      final missing = <SavedComputer>[];
      for (var start = 0; start < snapshot.length; start += 4) {
        final chunk = snapshot.skip(start).take(4).toList();
        final values = await Future.wait(
          chunk.map((d) => _pingSavedDevice(d, phone)),
        );
        if (!mounted) break;
        setState(() {
          for (var i = 0; i < chunk.length; i++) {
            _online[chunk[i].id] = values[i];
            if (!values[i]) missing.add(chunk[i]);
          }
        });
      }

      final wifi = activeWifi;
      if (wifi != null && missing.isNotEmpty && mounted) {
        final thisNetwork = wifi.cidr;
        final now = DateTime.now();
        final eligibleForTcp = forceRecovery ||
            _lastTcpRecoveryNetwork != thisNetwork ||
            _lastTcpRecoveryAt == null ||
            now.difference(_lastTcpRecoveryAt!) >
                const Duration(minutes: 4);
        List<String>? tcpHints;
        List<DiscoveredDevice> replies = [];
        try {
          replies = await findNearbyDevices(
            scanPrefixes: wifi.scanPrefixes.take(8).toList(),
            duration: const Duration(milliseconds: 1400),
          );
        } catch (_) {}
        for (final device in missing) {
          if (!mounted) break;
          final candidates = recoveryCandidates(device, wifi, replies)
              .where((ip) => ip != device.host).toList();
          // Bonjour addresses and UDP announcements are untrusted hints.
          final label = device.name.trim().replaceFirst(
              RegExp(r'\.local\.?$', caseSensitive: false), '');
          if (RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,62}$')
              .hasMatch(label)) {
            try {
              final addresses = await InternetAddress.lookup('$label.local',
                  type: InternetAddressType.IPv4)
                  .timeout(const Duration(milliseconds: 1250));
              for (final address in addresses) {
                if (lanRangeContains(wifi, address.address) &&
                    !candidates.contains(address.address) &&
                    address.address != device.host) {
                  candidates.insert(0, address.address);
                }
              }
            } catch (_) {}
          }
          String? verified;
          for (var index = 0; index < candidates.length; index += 4) {
            final batch = candidates.skip(index).take(4).toList();
            final result = await Future.wait(batch.map((ip) =>
                _pingSavedDevice(device, phone, atHost: ip)));
            for (var i = 0; i < batch.length; i++) {
              if (result[i]) { verified = batch[i]; break; }
            }
            if (verified != null) break;
          }
          // UDP and Bonjour can be blocked by local-network policy. Probe
          // only TCP 48321 on this Wi-Fi CIDR, at most once per four minutes
          // unless the user explicitly taps Refresh. An open port remains an
          // untrusted candidate until the saved TLS pin AND authenticated
          // phone pairing succeed.
          if (verified == null && eligibleForTcp) {
            if (tcpHints == null) {
              _lastTcpRecoveryNetwork = thisNetwork;
              _lastTcpRecoveryAt = now;
              tcpHints = await probeAgentControlPorts(wifi);
            }
            final tried = candidates.toSet();
            final extra = tcpHints.where((ip) =>
                ip != device.host && !tried.contains(ip)).toList();
            for (var index = 0; index < extra.length; index += 4) {
              final batch = extra.skip(index).take(4).toList();
              final results = await Future.wait(batch.map((ip) =>
                  _pingSavedDevice(device, phone, atHost: ip)));
              for (var i = 0; i < batch.length; i++) {
                if (results[i]) {
                  verified = batch[i];
                  break;
                }
              }
              if (verified != null) break;
            }
          }
          if (verified == null || !mounted) continue;
          // Reuse the previously paired computer, never create an extra row.
          final moved = movedDevice(device, verified,
              currentLocation: _detectedLocation);
          try {
            final saved = await deviceStore.upsert(moved);
            if (!mounted) break;
            setState(() {
              savedComputers = saved;
              _online[moved.id] = true;
            });
            if (_activeDeviceId == moved.id && agent.configured) {
              unawaited(connectSaved(moved));
            }
          } catch (_) {}
        }
      }
    } finally {
      _checkingHeartbeat = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _labelCurrentNetwork() async {
    final network = _wifiRange;
    if (network == null) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('This Wi-Fi network belongs to'),
        children: [
          for (final item in deviceLocations.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, item.key),
              child: Text(item.value),
            ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    await networkLocationStore.assign(network, choice);
    // Assign existing uncategorized devices inside this subnet to the
    // chosen location. Never override an explicitly selected category.
    for (final device in savedComputers.toList()) {
      if (device.location == 'other' &&
          lanRangeContains(network, device.host)) {
        await deviceStore.upsert(SavedComputer(
          id: device.id, name: device.name, host: device.host,
          token: device.token, fingerprint: device.fingerprint,
          platform: device.platform, deviceId: device.deviceId,
          customName: device.customName, location: choice,
          macAddress: device.macAddress,
        ));
      }
    }
    await loadComputers();
    await _refreshNetworkLocation();
  }

  Future<void> scanQrPairing() async {
    final scanned = await Navigator.of(context).push<PairingQR>(
      MaterialPageRoute(builder: (_) => const PairingScanner()),
    );
    if (scanned == null || !mounted) return;
    host.text = scanned.host;
    token.text = scanned.token;
    pin.text = scanned.fingerprint;
    discoveredName = scanned.host;
    await connect();
  }

  Future<void> openAgentInstaller() => _launchAgentInstaller();

  Future<void> _launchAgentInstaller({
    SavedComputer? device,
    bool updateOnly = false,
  }) async {
    if (installingAgent) return;
    setState(() => installingAgent = true);
    try {
      final address = device?.host ?? host.text.trim();
      final known = savedComputers.where((d) => d.host == address);
      final platform = device?.platform ?? agent.reportedPlatform ??
          (known.isNotEmpty ? known.first.platform : _connectedPlatform);
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => InstallAgentScreen(
          initialHost: address,
          knownPlatform: platform,
          updateOnly: updateOnly,
          onInstalled: (installed, installedPlatform) async {
            host.text = installed.host;
            token.text = installed.token;
            pin.text = installed.fingerprint;
            discoveredName = device?.name ?? installed.host;
            _connectedPlatform = installedPlatform;
            return connect();
          },
        ),
      ));
    } finally {
      if (mounted) setState(() => installingAgent = false);
    }
  }

  Future<void> loadComputers() async {
    try {
      final devices = await deviceStore.read();
      if (mounted) setState(() => savedComputers = devices);
      unawaited(_refreshHeartbeats());
    } catch (_) {
      if (mounted) {
        setState(() =>
            status = 'Saved devices could not be loaded. Check secure storage permissions.');
      }
    }
  }

  Future<Map<String, String>> _trustedMacDiscovery() async {
    final current = _wifiRange;
    if (current == null) return {};
    final candidates = savedComputers.where((device) =>
        lanRangeContains(current, device.host)).take(3);
    PhoneIdentity? phone;
    try {
      if (candidates.any((device) => device.deviceId.isNotEmpty)) {
        phone = await PhoneIdentity.loadOrCreate();
      }
    } catch (_) {}
    final combined = <String, String>{};
    for (final device in candidates) {
      final connection = LocalAgent();
      try {
        connection.configure(device.host, device.token, device.fingerprint,
            identity: device.deviceId.isNotEmpty ? phone : null,
            deviceId: device.deviceId.isNotEmpty ? device.deviceId : null);
        combined.addAll(await connection.trustedLanNeighbors());
      } catch (_) {
        // Offline or older agents cannot provide neighbor information.
      } finally {
        connection.disconnect();
      }
    }
    return combined;
  }

  /// A scan discovers IP addresses, never trusted identities. This verifies
  /// each candidate against the original saved certificate and authenticated
  /// pairing before immediately replacing an outdated DHCP address.
  Future<String?> _reconcileScannedAgent(String ip) async {
    if (!mounted || !isPrivateIPv4(ip) || savedComputers.isEmpty) {
      return null;
    }
    PhoneIdentity? phone;
    try {
      if (savedComputers.any((d) => d.deviceId.isNotEmpty)) {
        phone = await PhoneIdentity.loadOrCreate();
      }
    } catch (_) {}
    final snapshots = savedComputers.toList()..sort((a, b) =>
        (a.host == ip ? 0 : 1).compareTo(b.host == ip ? 0 : 1));
    for (final saved in snapshots) {
      if (!mounted || !(await _pingSavedDevice(saved, phone, atHost: ip))) {
        continue;
      }
      if (_scanVerifiedDeviceIds.contains(saved.id)) {
        return saved.name;
      }
      _scanVerifiedDeviceIds.add(saved.id);
      if (saved.host == ip) {
        if (mounted) setState(() => _online[saved.id] = true);
        return saved.name;
      }
      try {
        final verified = movedDevice(saved, ip,
            currentLocation: _detectedLocation);
        final refreshed = await deviceStore.upsert(verified);
        if (!mounted) return null;
        setState(() {
          savedComputers = refreshed;
          _online[saved.id] = true;
        });
        // Leave the user in the scan screen; the matching My Devices entry
        // is already updated and will open the correct IP when selected.
        return verified.name;
      } catch (_) {
        _scanVerifiedDeviceIds.remove(saved.id);
        return null;
      }
    }
    return null;
  }

  Future<Map<String, String>> _reconcileDiscoveredAgents(
      List<DiscoveredDevice> results) async {
    final recognized = <String, String>{};
    for (final result in results) {
      final name = await _reconcileScannedAgent(result.host);
      if (name != null) recognized[result.host] = name;
    }
    return recognized;
  }

  Future<void> scanNetwork() async {
    if (_scanningToReconcile) return;
    _scanningToReconcile = true;
    _scanVerifiedDeviceIds.clear();
    String? selected;
    try {
      selected = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) =>
            LanScanScreen(initialIp: host.text.trim(),
                knownComputers: savedComputers,
                macResolver: _trustedMacDiscovery,
                verifyPairedAgent: _reconcileScannedAgent)),
      );
    } finally {
      _scanningToReconcile = false;
      _scanVerifiedDeviceIds.clear();
    }
    if (selected == null || !mounted) return;
    PhoneIdentity? phone;
    try {
      if (savedComputers.any((d) => d.deviceId.isNotEmpty)) {
        phone = await PhoneIdentity.loadOrCreate();
      }
    } catch (_) {}
    for (final device in savedComputers.toList()) {
      if (await _pingSavedDevice(device, phone, atHost: selected)) {
        final moved = movedDevice(device, selected,
            currentLocation: _detectedLocation);
        try { await deviceStore.upsert(moved); } catch (_) {}
        if (mounted) await connectSaved(moved);
        return;
      }
    }
    if (!mounted) return;
    agent.disconnect();
    setState(() {
      host.text = selected!;
      discoveredName = selected;
      _showPairForm = true;
      status = 'Selected $selected from LAN scan. Pairing credentials are still required.';
    });
  }

  Future<void> searchNearby() async {
    if (searching || _scanningToReconcile) return;
    final wifi = await detectLanRange();
    if (!mounted) return;
    if (wifi == null) {
      _discoveryReport.clear();
      _discoveryReport.add('Discovery skipped: Wi-Fi is not connected');
      setState(() {
        nearbyComputers = [];
        status = 'Connect to Wi-Fi to discover nearby computers. '
            'Cellular networks are not scanned.';
      });
      return;
    }
    _scanningToReconcile = true;
    _scanVerifiedDeviceIds.clear();
    _discoveryReport.clear();
    _discoveryReport.add('Discover initiated by phone (no background scan)');
    setState(() {
      searching = true;
      nearbyComputers = [];
      status = 'Looking for TapTether agents on the local network…';
    });
    try {
      // Read the Wi-Fi again so a recent SSID switch does not reuse a
      // stale subnet from the preceding heartbeat refresh.
      _discoveryReport.add('Wi-Fi: ${wifi?.ip ?? "unknown"} · '
          'CIDR: ${wifi?.cidr ?? "unknown"}');
      final prefixes = wifi?.scanPrefixes.take(8).toList();
      _discoveryReport.add('UDP discovery: broadcast + unicast on port 48322 · '
          'ranges ${prefixes?.map((p) => "$p.0/24").join(", ") ?? "system detected"}');
      final result = await findNearbyDevices(scanPrefixes: prefixes);
      if (!mounted) return;
      _discoveryReport.add('UDP responses: ${result.length}');
      for (final found in result) {
        _discoveryReport.add('${found.host}: UDP announcement '
            '(unverified, platform ${found.platform})');
      }
      final verified = await _reconcileDiscoveredAgents(result);
      if (!mounted) return;
      final allCandidates = <String, DiscoveredDevice>{
        for (final found in result) found.host: found,
      };
      // A user-requested Discover also probes the agent TCP port on all
      // on-link /24 slices of up to a /22, even with no saved pairing.
      // This gives unpaired agents a chance to appear when UDP is blocked.
      // Open ports remain UNTRUSTED until pairing/TLS authentication.
      if (verified.isEmpty && wifi != null) {
        _discoveryReport.add('TCP fallback: probe port 48321 on Wi-Fi CIDR '
            '(320ms per host, up to 1024 addresses; max 24 results)');
        var attempted = 0;
        final ips = await probeAgentControlPorts(wifi,
          onProbe: (ip, accepts) {
            attempted++;
            _discoveryReport.add('$ip: TCP 48321 '
                '${accepts ? "accepted (unverified)" : "no connection"}');
          },
        );
        _discoveryReport.add('TCP fallback complete: $attempted addresses '
            'checked; ${ips.length} TCP responder(s)');
        for (final ip in ips) {
          if (!mounted) break;
          final name = await _reconcileScannedAgent(ip);
          if (name != null) {
            verified[ip] = name;
            _discoveryReport.add('$ip: saved pairing authenticated');
          } else {
            _discoveryReport.add('$ip: not authenticated as saved pairing');
            allCandidates.putIfAbsent(ip, () => DiscoveredDevice(
              name: 'Possible TapTether agent (unverified)',
              host: ip,
              platform: 'TCP 48321',
              version: 'unknown',
            ));
          }
        }
      } else if (verified.isNotEmpty) {
        _discoveryReport.add('TCP fallback skipped: paired computer found '
            'through UDP and authenticated');
      } else {
        _discoveryReport.add('TCP fallback unavailable: no Wi-Fi CIDR');
      }
      if (!mounted) return;
      _discoveryReport.add('Discover finished: '
          '${verified.length} existing paired computer(s) verified; '
          '${allCandidates.values.where((candidate) => !verified.containsKey(candidate.host)).length} unverified candidate(s)');
      setState(() {
        nearbyComputers = allCandidates.values.where((candidate) =>
            !verified.containsKey(candidate.host)).toList();
        status = verified.isNotEmpty
            ? 'Recognized ${verified.length} paired computer(s). My Devices is updated.'
            : nearbyComputers.isEmpty
                ? 'No agents found. See Full Discover Output below.'
                : 'Found ${nearbyComputers.length} unverified candidate(s). Pair to confirm.';
      });
    } catch (_) {
      _discoveryReport.add('Discover failed: network scan could not finish');
      if (mounted) {
        setState(() =>
            status = 'Discovery unavailable. See Full Discover Output.');
      }
    } finally {
      _scanningToReconcile = false;
      _scanVerifiedDeviceIds.clear();
      if (mounted) setState(() => searching = false);
    }
  }

  Future<void> selectDiscovered(DiscoveredDevice device) async {
    PhoneIdentity? phone;
    try {
      if (savedComputers.any((d) => d.deviceId.isNotEmpty)) {
        phone = await PhoneIdentity.loadOrCreate();
      }
    } catch (_) {}
    for (final saved in savedComputers.toList()) {
      if (await _pingSavedDevice(saved, phone, atHost: device.host)) {
        final moved = movedDevice(saved, device.host,
            currentLocation: _detectedLocation);
        try { await deviceStore.upsert(moved); } catch (_) {}
        if (mounted) await connectSaved(moved);
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      discoveredName = device.name;
      _connectedPlatform = device.platform;
      _macShortcuts = device.platform == 'darwin';
      _showPairForm = true;
      host.text = device.host;
      token.clear();
      pin.clear();
      status = 'Discovered ${device.name}. Enter its token and certificate fingerprint to verify ownership.';
    });
  }

  Future<void> connectSaved(SavedComputer device) async {
    host.text = device.host;
    token.text = device.token;
    pin.text = device.fingerprint;
    discoveredName = device.name;
    _connectedPlatform = device.platform;
    _macShortcuts = device.platform == 'darwin';
    await connect(existingId: device.id, deviceId: device.deviceId);
  }

  Future<void> updateSavedAgent(SavedComputer device) async {
    if (device.platform != 'linux' && device.platform != 'darwin' &&
        device.platform != 'windows') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('This operating system has no supported updater.'),
      ));
      return;
    }
    // A saved device may be online yet run a different agent build from
    // the iPhone app. Read its actual version over the authenticated,
    // TLS-pinned channel and refresh the published release metadata before
    // showing an actionable update confirmation.
    String? installedAgentVersion;
    final inspector = LocalAgent();
    try {
      final phone = device.deviceId.isEmpty
          ? null : await PhoneIdentity.loadOrCreate();
      inspector.configure(device.host, device.token, device.fingerprint,
          identity: phone,
          deviceId: device.deviceId.isEmpty ? null : device.deviceId);
      installedAgentVersion = await inspector.agentVersion();
    } catch (_) {
      // An unreachable or legacy agent has an unknown version.
    } finally {
      inspector.disconnect();
    }
    await checkForUpdates();
    if (!mounted) return;
    final check = AgentUpdateCheck(
      installed: installedAgentVersion,
      published: _latestReleaseVersion,
    );
    final approved = await showDialog<bool>(
      context: context,
      builder: (_) => AgentUpdateDialog(
        computerName: device.name,
        check: check,
      ),
    );
    if (approved != true || !mounted || !check.canUpdate) return;
    // Existing installed agents own the update action and verify the release.
    // Ubuntu requires the user to have separately enabled noninteractive sudo.
    // Older agents or machines without it retain the SSH GUI fallback.
    if (device.platform == 'darwin' ||
        device.platform == 'linux' || device.platform == 'windows') {
      final client = LocalAgent();
      try {
        final phone = device.deviceId.isEmpty
            ? null : await PhoneIdentity.loadOrCreate();
        client.configure(device.host, device.token, device.fingerprint,
            identity: phone,
            deviceId: device.deviceId.isEmpty ? null : device.deviceId);
        if (await client.requestUpdate()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Update started on ${device.name}.'),
            ));
          }
          return;
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(
              'Direct update unavailable. Opening SSH update instead.')),
          );
        }
      } finally {
        client.disconnect();
      }
    }
    if (mounted) {
      await _launchAgentInstaller(device: device, updateOnly: true);
    }
  }

  Future<void> forgetComputer(SavedComputer device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Forget ${device.name}?'),
        content: const Text('Its saved token and certificate fingerprint will be erased from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Forget')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updated = await deviceStore.remove(device.id);
      if (mounted) setState(() => savedComputers = updated);
    } catch (_) {
      if (mounted) setState(() => status = 'Cannot erase saved pairing from secure storage.');
    }
  }

  Future<void> openDeviceManager() async {
    final addNew = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => DeviceManagerScreen(
        store: deviceStore,
        onConnect: connectSaved,
        onUpdate: updateSavedAgent,
      ),
    ));
    if (!mounted) return;
    await loadComputers();
    if (addNew == true && mounted) setState(() => _showPairForm = true);
  }

  Future<void> openSshKeys() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const SshKeyScreen(),
    ));
  }

  Future<void> openSecuritySettings() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const SecuritySettingsScreen(),
    ));
  }

  void showPairForm() {
    _stopScreen();
    if (agent.configured) agent.disconnect();
    setState(() {
      _showPairForm = true;
      status = 'Enter verified computer pairing details.';
    });
  }

  Widget appDrawer() => Drawer(
    child: SafeArea(child: ListView(
      padding: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset('assets/branding/taptether.png',
                  width: 54, height: 54),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('TapTether',
                    style: Theme.of(context).textTheme.titleLarge),
                const Text('Your network. Your control.'),
              ],
            )),
          ]),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.devices_outlined),
          title: const Text('My Devices'),
          onTap: () {
            Navigator.pop(context);
            if (agent.configured) {
              agent.disconnect();
              setState(() => status = 'Select a device to connect.');
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: const Text('SSH Keys'),
          onTap: () {
            Navigator.pop(context);
            openSshKeys();
          },
        ),
        ExpansionTile(
          leading: const Icon(Icons.add_circle_outline),
          title: const Text('Add & Discover'),
          childrenPadding: const EdgeInsets.only(left: 16),
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Pair computer'),
              onTap: () {
                Navigator.pop(context);
                showPairForm();
              },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Scan QR'),
              onTap: () {
                Navigator.pop(context);
                scanQrPairing();
              },
            ),
            ListTile(
              leading: const Icon(Icons.radar),
              title: const Text('Discover computers'),
              onTap: () {
                Navigator.pop(context);
                if (agent.configured) agent.disconnect();
                searchNearby();
              },
            ),
            ListTile(
              leading: const Icon(Icons.network_check),
              title: const Text('Scan local IP network'),
              onTap: () {
                Navigator.pop(context);
                scanNetwork();
              },
            ),
            ListTile(
              leading: const Icon(Icons.install_desktop),
              title: const Text('Install Agent'),
              onTap: installingAgent ? null : () {
                Navigator.pop(context);
                openAgentInstaller();
              },
            ),
          ],
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Security & Appearance'),
          onTap: () {
            Navigator.pop(context);
            openSecuritySettings();
          },
        ),
        AboutListTile(
          icon: const Icon(Icons.info_outline),
          applicationName: 'TapTether',
          applicationVersion: installedVersion,
          child: const Text('About'),
        ),
      ],
    )),
  );

  Widget deviceDashboard() {
    final visibleDevices = visibleSavedDevices(
      savedComputers,
      online: _online,
      locationFilter: _locationFilter,
      currentLocation: _detectedLocation,
      currentNetwork: _wifiRange,
      showOffline: _showOffline,
    );
    return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Expanded(child: Text('My Devices',
          style: Theme.of(context).textTheme.headlineSmall)),
        TextButton.icon(
          onPressed: openDeviceManager,
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Manage'),
        ),
      ]),
      const SizedBox(height: 8),
      if (savedComputers.isNotEmpty) ...[
        Row(children: [
          Expanded(child: DropdownButtonFormField<String>(
            key: const ValueKey('device-location-filter'),
            initialValue: _locationFilter,
            decoration: const InputDecoration(
              isDense: true, labelText: 'Location'),
            items: [
              DropdownMenuItem(value: 'automatic',
                child: Text(_detectedLocation == null
                    ? 'Current network'
                     : 'Current · ${deviceLocations[_detectedLocation]!}')),
              const DropdownMenuItem(
                value: 'all', child: Text('All locations')),
              for (final category in deviceLocations.entries)
                DropdownMenuItem(value: category.key, child: Text(category.value)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _locationFilter = value);
            },
          )),
          IconButton(
            tooltip: 'Check online computers',
            onPressed: _checkingHeartbeat ? null : () =>
                _refreshHeartbeats(forceRecovery: true),
            icon: const Icon(Icons.refresh),
          ),
        ]),
        Row(children: [
          Checkbox(
            key: const ValueKey('show-offline-devices'),
            value: _showOffline,
            onChanged: (value) => setState(() => _showOffline = value ?? false),
          ),
          const Text('Show offline'),
          const Spacer(),
          TextButton.icon(
            onPressed: _wifiRange == null ? null : _labelCurrentNetwork,
            icon: const Icon(Icons.location_on_outlined, size: 17),
            label: const Text('Label network'),
          ),
        ]),
        if (_wifiRange == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              const Icon(Icons.wifi_off, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(
                'Connect to Wi-Fi to discover and scan computers. '
                'Cellular networks are not scanned.',
                style: Theme.of(context).textTheme.bodySmall,
              )),
            ]),
          ),
        if (_wifiRange != null)
          Text('Wi-Fi: ${_wifiRange!.cidr}'
              '${_detectedLocation == null ? ' · Unassigned' : ' · ${deviceLocations[_detectedLocation]!}'}',
              style: Theme.of(context).textTheme.bodySmall),
        if (_checkingHeartbeat)
          const LinearProgressIndicator(),
        const SizedBox(height: 8),
        if (visibleDevices.isEmpty)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(_checkingHeartbeat
                ? 'Checking which computers are online…'
                : 'No online computers for this location. Select Show offline '
                  'to see saved devices or change the location filter.'),
          ),
      ],
      if (savedComputers.isEmpty)
        Card(child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.devices_other_outlined, size: 36),
              const SizedBox(height: 12),
              Text('No computers paired yet',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text('Pair a computer on your local network '
                  'to reconnect with a single tap.'),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: showPairForm,
                icon: const Icon(Icons.add),
                label: const Text('Pair computer'),
              ),
            ],
          ),
        ))
      else
        for (final device in visibleDevices)
          Card(child: ListTile(
            leading: Icon(device.platform == 'darwin'
                ? Icons.laptop_mac : Icons.computer),
            title: Text(device.name, maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: Text('${device.host} · ${deviceLocations[device.location]!}'
                ' · ${_online[device.id] == true ? 'Online' : _online[device.id] == false ? 'Offline' : 'Checking…'}',
                maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (device.platform == 'linux' ||
                  device.platform == 'darwin' ||
                  device.platform == 'windows')
                IconButton(
                  tooltip: 'Check agent update',
                  onPressed: () => updateSavedAgent(device),
                  icon: const Icon(Icons.system_update_alt),
                ),
              Icon(Icons.circle, size: 13,
                  color: _online[device.id] == true
                      ? Colors.green : Theme.of(context)
                          .colorScheme.outline),
            ]),
            onTap: () => connectSaved(device),
          )),
      for (final nearby in nearbyComputers)
        Card(child: ListTile(
          leading: const Icon(Icons.radar),
          title: Text(nearby.name),
          subtitle: Text('${nearby.host} · ${nearby.platform}'),
          trailing: const Icon(Icons.add_link),
          onTap: () => selectDiscovered(nearby),
        )),
      const SizedBox(height: 10),
      Card(child: ExpansionTile(
        key: const ValueKey('device-quick-actions'),
        leading: const Icon(Icons.add_circle_outline),
        title: const Text('Add or discover a computer'),
        subtitle: const Text('Pair, scan or install an agent'),
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Wrap(spacing: 8, runSpacing: 5, children: [
              ActionChip(avatar: const Icon(Icons.add, size: 18),
                label: const Text('Pair'), onPressed: showPairForm),
              ActionChip(avatar: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('Scan QR'), onPressed: scanQrPairing),
              ActionChip(avatar: const Icon(Icons.radar, size: 18),
                label: Text(searching ? 'Searching…' : 'Discover'),
                onPressed: searching || _wifiRange == null
                    ? null : searchNearby),
              ActionChip(avatar: const Icon(Icons.network_check, size: 18),
                label: const Text('Scan IPs'),
                onPressed: _wifiRange == null ? null : scanNetwork),
              ActionChip(avatar: const Icon(Icons.install_desktop, size: 18),
                label: const Text('Install agent'),
                onPressed: installingAgent ? null : openAgentInstaller),
            ]),
          ),
        ],
      )),
      const SizedBox(height: 8),
      ScanReportPanel(
        title: 'Full Discover Output',
        report: _discoveryReport,
      ),
      const SizedBox(height: 14),
    ],
   );
  }

  bool newerThan(String latest, String installed) {
    final pattern = RegExp(r'^([0-9]+)[.]([0-9]+)[.]([0-9]+)(?:[+]([0-9]+))?');
    final a = pattern.firstMatch(latest);
    final b = pattern.firstMatch(installed);
    if (a == null || b == null) return false;
    for (var i = 1; i <= 4; i++) {
      final left = int.parse(a.group(i) ?? '0');
      final right = int.parse(b.group(i) ?? '0');
      if (left != right) return left > right;
    }
    return false;
  }

  Future<void> loadInstalledVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() =>
          installedVersion = '${info.version}+${info.buildNumber}');
      }
    } catch (_) {
      if (mounted) {
        setState(() => installedVersion = 'unavailable');
      }
    }
  }

  Future<void> checkForUpdates() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);
    try {
      // The only startup internet request checks public release metadata.
      final request = await client.getUrl(Uri.parse(
        'https://raw.githubusercontent.com/ssnanda/taptether.com/main/altstore.json'));
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return;
      final data = jsonDecode(await utf8.decoder.bind(response).join());
      if (data is! Map || data['apps'] is! List) return;
      final apps = data['apps'] as List;
      if (apps.isEmpty || apps.first is! Map) return;
      final app = apps.first as Map;
      if (app['version'] is! String) return;
      final latest = "${app['version']}+${app['buildVersion']}";
      final local = await PackageInfo.fromPlatform();
      final current = '${local.version}+${local.buildNumber}';
      if (!mounted) return;
      setState(() {
        _latestReleaseVersion = latest;
        availableAppVersion = newerThan(latest, current) ? latest : null;
        availableAgentVersion = connectedAgentVersion != null &&
                newerThan(latest, connectedAgentVersion!)
            ? latest : null;
      });
    } catch (_) {
      // LAN control remains usable without internet access.
    } finally {
      client.close(force: true);
    }
  }

  Widget updateNotices() => Column(children: [
    if (availableAppVersion != null) Card(child: ListTile(
      leading: const Icon(Icons.system_update),
      title: Text('TapTether ${availableAppVersion!} available'),
      subtitle: const Text('View the new IPA in AltStore / GitHub Releases.'),
      trailing: const Icon(Icons.open_in_new),
      onTap: () => launchUrl(
        Uri.parse('https://github.com/ssnanda/taptether.com/releases/tag/current'),
        mode: LaunchMode.externalApplication),
    )),
    if (availableAgentVersion != null) Card(child: ListTile(
      leading: const Icon(Icons.computer),
      title: Text('Computer agent update: ${availableAgentVersion!}'),
      subtitle: const Text('On the computer, run taptetherctl check-update and update.'),
    )),
  ]);

  Future<void> confirmShutdown() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Shut down this computer?'),
        content: const Text('Open applications will close and unsaved work may be lost.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Shut down')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await agent.send('shutdown');
      if (mounted) setState(() => status = 'Shutdown requested.');
    } catch (e) {
      _handleRemoteFailure(e);
    }
  }


  final Map<int, Offset> _touches = {};
  double? _pinchStart;
  bool _pinching = false;
  double _swipeX = 0;
  bool _swipeSent = false;
  bool _multiTouchGesture = false;
  double _scrollRemainder = 0;
  int _pendingScroll = 0;
  Timer? _scrollTimer;
  bool _scrollInFlight = false;
  double mouseSensitivity = 3.8;

  void _touchDown(PointerDownEvent e) {
    if (_touches.isEmpty) _multiTouchGesture = false;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length > 1) _multiTouchGesture = true;
    _pinchStart = _touches.length == 2
        ? (_touches.values.first - _touches.values.last).distance : null;
    _pinching = false;
    if (_touches.length == 3) {
      _swipeX = 0;
      _swipeSent = false;
    }
  }

  void _touchMove(PointerMoveEvent e) {
    final before = _touches[e.pointer];
    if (before == null) return;
    _touches[e.pointer] = e.localPosition;
    final delta = e.localPosition - before;
    if (_touches.length == 1) {
      queueMovement(delta);
    } else if (_touches.length == 2) {
      final distance = (_touches.values.first - _touches.values.last).distance;
      _pinchStart ??= distance;
      if ((distance - _pinchStart!).abs() >= 40) {
        _pinching = true;
        unawaited(command('key', {'key': _shortcut(
            distance > _pinchStart! ? 'equal' : 'minus')}));
        _pinchStart = distance;
      }
      if (!_pinching) {
        _scrollRemainder += delta.dy / 15;
        final ticks = _scrollRemainder.truncate();
        if (ticks != 0) {
          _scrollRemainder -= ticks;
          _pendingScroll += ticks;
          _scheduleScroll();
        }
      }
    } else if (_touches.length >= 3 && !_swipeSent) {
      _swipeX += delta.dx;
      if (_swipeX.abs() >= 115) {
        _swipeSent = true;
        unawaited(command('key', {'key': _macShortcuts
            ? (_swipeX > 0 ? 'cmd+tab' : 'shift+cmd+tab')
            : (_swipeX > 0 ? 'alt+tab' : 'shift+alt+tab')}));
      }
    }
  }

  void _touchUp(PointerEvent e) {
    _touches.remove(e.pointer);
    if (_touches.length < 2) {
      _pinchStart = null;
      _pinching = false;
      _scrollRemainder = 0;
    }
    if (_touches.length < 3) _swipeX = 0;
  }

  String _shortcut(String key) =>
      '${_macShortcuts ? 'cmd' : 'ctrl'}+$key';

  void _scheduleScroll() {
    if (_scrollTimer != null || _scrollInFlight || !agent.configured) return;
    _scrollTimer = Timer(const Duration(milliseconds: 20), _flushScroll);
  }

  Future<void> _flushScroll() async {
    _scrollTimer = null;
    if (!agent.configured || _scrollInFlight) return;
    final ticks = _pendingScroll.clamp(-8, 8).toInt();
    if (ticks == 0) return;
    _pendingScroll -= ticks;
    _scrollInFlight = true;
    try {
      await command('scroll', {'dy': ticks});
    } finally {
      _scrollInFlight = false;
      if (_pendingScroll != 0) _scheduleScroll();
    }
  }

  // Only by explicit tap; sends text into the focused desktop app, not the OS clipboard.
  Future<void> typePhoneClipboard() async {
    try {
      final value = (await Clipboard.getData('text/plain'))?.text;
      if (value == null || value.isEmpty) {
        if (mounted) setState(() => status = 'Phone clipboard has no text.');
        return;
      }
      for (final chunk in clipboardChunks(value)) {
        await agent.send('text', {'text': chunk});
      }
      if (mounted) {
        setState(() =>
            status = 'Typed phone clipboard into the active computer window.');
      }
    } catch (error) {
      _handleRemoteFailure(error);
    }
  }
  double _pendingMoveX = 0;
  double _pendingMoveY = 0;
  bool _movementInFlight = false;
  Timer? _movementTimer;

  // Preserve all touch motion while sending only one network movement at a time.
  void queueMovement(Offset delta) {
    _pendingMoveX += delta.dx * mouseSensitivity;
    _pendingMoveY += delta.dy * mouseSensitivity;
    _scheduleMovement();
  }

  void _scheduleMovement() {
    if (_movementTimer != null || _movementInFlight || !agent.configured) return;
    _movementTimer = Timer(const Duration(milliseconds: 12), _flushMovement);
  }

  Future<void> _flushMovement() async {
    _movementTimer = null;
    if (!agent.configured || _movementInFlight) return;
    final dx = _pendingMoveX.truncate().clamp(-300, 300);
    final dy = _pendingMoveY.truncate().clamp(-300, 300);
    if (dx == 0 && dy == 0) return;
    _pendingMoveX -= dx;
    _pendingMoveY -= dy;
    _movementInFlight = true;
    try {
      await command('move', {'dx': dx, 'dy': dy});
    } finally {
      _movementInFlight = false;
      if (_pendingMoveX.abs() >= 1 || _pendingMoveY.abs() >= 1) {
        _scheduleMovement();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _remoteRouteObserver.unsubscribe(this);
    _heartbeatTimer?.cancel();
    unawaited(_networkChanges?.cancel());
    host.dispose(); token.dispose(); pin.dispose(); typing.dispose();
    _movementTimer?.cancel();
    _scrollTimer?.cancel();
    _stopScreen();
    agent.disconnect();
    super.dispose();
  }

  Future<void> command(String type, [Map<String, Object> data = const {}]) async {
    try {
      await agent.send(type, data);
      if ((type == 'click' || type == 'tap' || type == 'scroll') &&
          _viewingScreen && _remoteLayout.visualMode == 'snapshot') {
        // The input has reached the agent before requesting the next frame.
        unawaited(Future<void>.delayed(const Duration(milliseconds: 120),
            _refreshScreenshot));
      }
      if ((_connectionLost || _agentInputDenied) && mounted) {
        setState(() {
          _connectionLost = false;
          _agentInputDenied = false;
          _connectionTechnical = null;
          status = 'Connected to ${host.text.trim()}';
        });
      }
      if (_haptics && (type == 'click' || type == 'key')) {
        unawaited(HapticFeedback.selectionClick());
      }
    } catch (e) {
      _handleRemoteFailure(e);
    }
  }

  Future<bool> connect({String? existingId, String? deviceId}) async {
    _stopScreen();
    try {
      if (mounted) {
        setState(() => _remoteLayout = const RemoteLayoutSettings());
      }
      final phone = await PhoneIdentity.loadOrCreate();
      agent.configure(host.text, token.text, pin.text,
        identity: deviceId != null && deviceId.isNotEmpty ? phone : null,
        deviceId: deviceId != null && deviceId.isNotEmpty ? deviceId : null);
      await agent.send('ping');
      // Upgrade legacy token pairing to a device-specific signed identity.
      var enrolledId = deviceId ?? '';
      if (enrolledId.isEmpty) {
        try {
          enrolledId = await agent.enrollPhone(phone, 'Phone');
          agent.usePhoneKey(phone, enrolledId);
          await agent.send('ping');
        } catch (_) {
          // Older agents still accept legacy token pairing until upgraded.
          agent.configure(host.text, token.text, pin.text);
          await agent.send('ping');
          enrolledId = '';
        }
      }
      final currentAgent = await agent.agentVersion();
      String? verifiedName = agent.reportedHostname;
      // Older agents do not yet report hostname; reverse DNS is only a
      // display hint after a successful authenticated, TLS-pinned ping.
      if (verifiedName == null) {
        try {
          final ip = InternetAddress(host.text.trim());
          final reverse = await ip.reverse()
              .timeout(const Duration(milliseconds: 750));
          if (reverse.host != host.text.trim() &&
              RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$')
                  .hasMatch(reverse.host)) {
            verifiedName = reverse.host;
          }
        } catch (_) {}
      }
      _connectedPlatform = agent.reportedPlatform ?? _connectedPlatform;
      if (_connectedPlatform == 'windows' || _connectedPlatform == 'linux') {
        _macShortcuts = false;
      }
      if (verifiedName != null) discoveredName = verifiedName;
      if (mounted) {
        setState(() {
        status = 'Connected to ${host.text.trim()}';
        _connectionLost = false;
        _agentInputDenied = false;
        _connectionTechnical = null;
        connectedAgentVersion = currentAgent;
        availableAgentVersion = currentAgent != null &&
                _latestReleaseVersion != null &&
                newerThan(_latestReleaseVersion!, currentAgent)
            ? _latestReleaseVersion : null;
        });
      }
      // Persist only after certificate pin verification and authenticated ping.
      try {
        final byId = savedComputers.where((d) => d.id == existingId);
        final normalizedPin = pin.text.replaceAll(
            RegExp(r'[^a-fA-F0-9]'), '').toUpperCase();
        final byPin = savedComputers.where(
            (d) => d.fingerprint.toUpperCase() == normalizedPin);
        final byHost = savedComputers.where(
            (d) => d.host == host.text.trim());
        final existing = byId.isNotEmpty ? byId.first
            : byPin.isNotEmpty ? byPin.first
            : byHost.isNotEmpty ? byHost.first : null;
        final discovered = nearbyComputers.where((d) => d.host == host.text.trim());
        final location = _detectedLocation ?? existing?.location ?? 'other';
        final device = SavedComputer(
          id: existingId ?? existing?.id ?? SavedComputer.newId(),
          name: existing?.customName == true
              ? existing!.name
              : verifiedName ?? discoveredName ?? existing?.name ?? host.text.trim(),
          host: host.text.trim(),
          token: enrolledId.isEmpty ? token.text.trim() : '',
          deviceId: enrolledId,
          fingerprint: pin.text.replaceAll(RegExp(r'[^a-fA-F0-9]'), '').toUpperCase(),
          platform: agent.reportedPlatform ?? (discovered.isEmpty
              ? (_connectedPlatform ?? existing?.platform ?? 'computer')
              : discovered.first.platform),
          location: location,
          customName: existing?.customName ?? false,
          macAddress: agent.reportedMacAddress ?? existing?.macAddress ?? '',
        );
        final updated = await deviceStore.upsert(device);
        if (mounted) {
          setState(() {
            savedComputers = updated;
            _online[device.id] = true;
            _activeDeviceId = device.id;
          });
        }
        unawaited(_loadLayoutForHost(host.text.trim()));
        return true;
      } catch (_) {
        if (mounted) {
          setState(() =>
              status = 'Connected, but secure storage could not save this pairing.');
        }
        return false;
      }
    } catch (e) {
      agent.disconnect();
      if (mounted) setState(() => status = '$e');
      return false;
    }
  }

  Widget keyButton(String label, String key, {double? width}) =>
      SizedBox(width: width, child: OutlinedButton(
        onPressed: agent.configured && !_connectionLost
            ? () => command('key', {'key': key}) : null,
        child: Text(label, textAlign: TextAlign.center),
      ));


  Future<void> _loadLayoutForHost(String expectedHost) async {
    final loaded = await remoteLayoutStore.read(expectedHost);
    if (mounted && agent.configured && host.text.trim() == expectedHost) {
      setState(() => _remoteLayout = loaded);
      _syncScreen();
    }
  }

  void _setLayout(RemoteLayoutSettings next) {
    final visualChanged = _remoteLayout.visualMode != next.visualMode ||
        _remoteLayout.trackpadExpanded != next.trackpadExpanded ||
        _remoteLayout.mediaMode != next.mediaMode ||
        _remoteLayout.presentationMode != next.presentationMode;
    setState(() => _remoteLayout = next);
    if (visualChanged) _syncScreen();
    unawaited(_persistLayout(host.text.trim(), next));
  }

  Future<void> _persistLayout(
      String computer, RemoteLayoutSettings value) async {
    if (computer.isEmpty) return;
    try {
      await remoteLayoutStore.write(computer, value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Unable to save control preferences on this phone.'),
        ));
      }
    }
  }

  RemoteLayoutSettings _changedLayout({
    bool? trackpad,
    bool? keyboard,
    bool? arrows,
    bool? more,
    bool? presenting,
    bool? mediaMode,
    String? mediaService,
    String? visualMode,
    String? presentationApp,
    List<String>? sections,
    List<String>? quick,
  }) => RemoteLayoutSettings(
    trackpadExpanded: trackpad ?? _remoteLayout.trackpadExpanded,
    keyboardExpanded: keyboard ?? _remoteLayout.keyboardExpanded,
    arrowsExpanded: arrows ?? _remoteLayout.arrowsExpanded,
    moreExpanded: more ?? _remoteLayout.moreExpanded,
    presentationMode: presenting ?? _remoteLayout.presentationMode,
    mediaMode: mediaMode ?? _remoteLayout.mediaMode,
    mediaService: mediaService ?? _remoteLayout.mediaService,
    visualMode: visualMode ?? _remoteLayout.visualMode,
    presentationApp: presentationApp ?? _remoteLayout.presentationApp,
    expandedSections: sections ?? _remoteLayout.expandedSections,
    quickKeys: quick ?? _remoteLayout.quickKeys,
  );

  void _toggleMoreSection(String id) {
    final enabled = _remoteLayout.expandedSections.toSet();
    if (!enabled.add(id)) enabled.remove(id);
    _setLayout(_changedLayout(sections: enabled.toList()));
  }

  void _handleRemoteFailure(Object error) {
    if (!mounted) return;
    final disconnected = error is SocketException ||
        error is TimeoutException ||
        error is HandshakeException ||
        error is HttpException;
    setState(() {
      if (disconnected) {
        _stopScreen();
        _connectionLost = true;
        _connectionTechnical = error.toString();
        status = 'Connection lost';
        _pendingMoveX = 0;
        _pendingMoveY = 0;
        _pendingScroll = 0;
        _touches.clear();
      } else if (isMacAccessibilityError(error)) {
        _agentInputDenied = true;
        status = 'Mac is online but Accessibility permission blocks input.';
      } else {
        status = 'Remote command failed. Check the computer connection.';
      }
    });
  }

  Future<void> _retryRemoteConnection() async {
    if (_retryingConnection || !agent.configured) return;
    setState(() => _retryingConnection = true);
    try {
      await agent.send('ping');
      if (mounted) {
        setState(() {
          _connectionLost = false;
          _connectionTechnical = null;
          status = 'Connected to ${host.text.trim()}';
        });
      }
    } catch (error) {
      _handleRemoteFailure(error);
    } finally {
      if (mounted) setState(() => _retryingConnection = false);
    }
  }

  String _quickKeyCommand(String id) {
    if (RegExp(r'^f(?:[1-9]|1[0-2])$').hasMatch(id)) return id;
    switch (id) {
      case 'escape': return 'Escape';
      case 'tab': return 'Tab';
      case 'enter': return 'Return';
      case 'backspace': return 'BackSpace';
      case 'up': return 'Up';
      case 'down': return 'Down';
      case 'left': return 'Left';
      case 'right': return 'Right';
      case 'copy': return _shortcut('c');
      case 'paste': return _shortcut('v');
      case 'selectAll': return _shortcut('a');
      case 'undo': return _shortcut('z');
      case 'find': return _shortcut('f');
      case 'newTab': return _shortcut('t');
      case 'switchApp': return _macShortcuts ? 'cmd+tab' : 'alt+tab';
      case 'home': return 'home';
      case 'end': return 'end';
      case 'pageUp': return 'pageup';
      case 'pageDown': return 'pagedown';
      case 'volumeDown': return 'XF86AudioLowerVolume';
      case 'mute': return 'XF86AudioMute';
      case 'volumeUp': return 'XF86AudioRaiseVolume';
      default: throw ArgumentError.value(id, 'id', 'Unknown remote control');
    }
  }

  Widget _quickKeyButton(String id) =>
      keyButton(remoteQuickKeyLabels[id]!, _quickKeyCommand(id));

  Future<void> _customizeQuickKeys() async {
    final chosen = _remoteLayout.quickKeys.toList();
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) => SafeArea(child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(children: [
              Row(children: [
                Expanded(child: Text('Customize quick keys',
                    style: Theme.of(context).textTheme.titleLarge)),
                TextButton(
                  onPressed: () => Navigator.pop(context, chosen),
                  child: const Text('Save'),
                ),
              ]),
              const Text('Choose visible buttons and move them up or down '
                  'to set the order. These settings are saved per computer.'),
              const SizedBox(height: 8),
              Expanded(child: ListView(children: [
                if (chosen.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('No quick keys selected. Add buttons below.'),
                  ),
                for (var i = 0; i < chosen.length; i++)
                  ListTile(
                    key: ValueKey('quick-${chosen[i]}'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(remoteQuickKeyLabels[chosen[i]]!),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Move up',
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: i == 0 ? null : () => updateSheet(() {
                          final key = chosen.removeAt(i);
                          chosen.insert(i - 1, key);
                        }),
                      ),
                      IconButton(
                        tooltip: 'Move down',
                        icon: const Icon(Icons.arrow_downward),
                        onPressed: i == chosen.length - 1 ? null
                            : () => updateSheet(() {
                          final key = chosen.removeAt(i);
                          chosen.insert(i + 1, key);
                        }),
                      ),
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close),
                        onPressed: () => updateSheet(() => chosen.removeAt(i)),
                      ),
                    ]),
                  ),
                const Divider(),
                Text('Available controls',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final entry in remoteQuickKeyLabels.entries)
                    if (!chosen.contains(entry.key))
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: Text(entry.value),
                        onPressed: () => updateSheet(() => chosen.add(entry.key)),
                      ),
                ]),
              ])),
            ]),
          ),
        )),
      ),
    );
    if (result != null && mounted) {
      _setLayout(_changedLayout(quick: result));
    }
  }


  Widget _advancedSection(String id, String title, IconData icon,
      Widget content) {
    final open = _remoteLayout.expandedSections.contains(id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        trailing: Icon(open ? Icons.expand_less : Icons.expand_more),
        onTap: () => _toggleMoreSection(id),
      ),
      if (open) Padding(padding: const EdgeInsets.only(bottom: 12),
          child: content),
      const Divider(height: 1),
    ]);
  }

  Widget _arrowPad() => Column(children: [
    Center(child: _quickKeyButton('up')),
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _quickKeyButton('left'),
      const SizedBox(width: 8),
      _quickKeyButton('down'),
      const SizedBox(width: 8),
      _quickKeyButton('right'),
    ]),
  ]);

  Widget _trackpadSurface({double height = 224}) => GestureDetector(
    // Win the gesture arena against the enclosing ListView. A Listener
    // receives raw multi-touch pointer events but cannot stop parent scroll.
    // Pointer tracking below continues to handle movement and two-finger
    // gestures; these pan handlers deliberately do not send duplicate input.
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) {},
    onPanUpdate: (_) {},
    onTap: _connectionLost ? null : () {
      if (!_multiTouchGesture) unawaited(command('click', {'button': 'left'}));
    },
    onDoubleTap: _connectionLost ? null : () {
      if (!_multiTouchGesture) unawaited(command('click', {'button': 'double'}));
    },
    onLongPress: _connectionLost ? null : () {
      if (!_multiTouchGesture) unawaited(command('click', {'button': 'right'}));
    },
    child: Listener(
      onPointerDown: _connectionLost ? null : _touchDown,
      onPointerUp: _connectionLost ? null : _touchUp,
      onPointerCancel: _connectionLost ? null : _touchUp,
      onPointerMove: _connectionLost ? null : _touchMove,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary
                .withValues(alpha: 0.25))),
        child: Center(child: Icon(Icons.touch_app, size: 36,
            color: Theme.of(context).colorScheme.onPrimaryContainer
                .withValues(alpha: 0.5))),
      ),
    ),
  );

  Widget _connectionBanner() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.wifi_off_outlined),
          const SizedBox(width: 8),
          Expanded(child: Text('Connection lost',
              style: Theme.of(context).textTheme.titleMedium)),
          TextButton.icon(
            onPressed: _retryingConnection ? null : _retryRemoteConnection,
            icon: const Icon(Icons.refresh),
            label: Text(_retryingConnection ? 'Retrying…' : 'Retry'),
          ),
        ]),
        const Text('The computer agent is not responding. Check that it '
            'is running and retry.'),
        if (_connectionTechnical != null)
          ExpansionTile(
            title: const Text('Technical details'),
            tilePadding: EdgeInsets.zero,
            children: [SelectableText(_connectionTechnical!,
                style: Theme.of(context).textTheme.bodySmall)],
          ),
      ]),
    ),
  );

  List<Widget> _moreControlSections() => [
        _advancedSection('editing', 'Editing & shortcuts',
          Icons.edit_outlined, Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final id in [
                  'copy', 'paste', 'selectAll', 'undo', 'find', 'newTab',
                  'switchApp',
                ]) _quickKeyButton(id),
              ]),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _connectionLost ? null : typePhoneClipboard,
                icon: const Icon(Icons.content_paste_go),
                label: const Text('Type phone clipboard'),
              ),
              // Clipboard action is intentionally explicit. Technical detail
              // belongs in Help, not the main remote-control surface.
            ],
          ),
        ),
        _advancedSection('extended', 'Extended keyboard',
          Icons.keyboard_alt_outlined, Wrap(
            spacing: 8, runSpacing: 4, children: [
              for (final id in ['home', 'end', 'pageUp', 'pageDown'])
                _quickKeyButton(id),
              for (var f = 1; f <= 12; f++) keyButton('F$f', 'f$f'),
            ],
          ),
        ),
        _advancedSection('volume', 'Volume & media',
          Icons.volume_up_outlined, Wrap(
            spacing: 8, runSpacing: 4, children: [
              for (final id in ['volumeDown', 'mute', 'volumeUp'])
                _quickKeyButton(id),
            ],
          ),
        ),
        _advancedSection('power', 'Power',
          Icons.power_settings_new_outlined, Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              OutlinedButton.icon(
                onPressed: agent.shutdownEnabled ? confirmShutdown : null,
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Shut down computer'),
              ),
              if (!agent.shutdownEnabled)
                const Text('Shutdown is not enabled on this computer.'),
            ],
          ),
        ),
        _advancedSection('preferences', 'Remote preferences',
          Icons.settings_outlined, Column(children: [
            Row(children: [
              Text('Pointer: ${mouseSensitivity.toStringAsFixed(1)}×'),
              Expanded(child: Slider(
                value: mouseSensitivity, min: 1.0, max: 8.0, divisions: 28,
                onChanged: (value) =>
                    setState(() => mouseSensitivity = value),
              )),
            ]),
            if (_connectedPlatform != 'linux' &&
                _connectedPlatform != 'windows')
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mac shortcuts (⌘)'),
                value: _macShortcuts,
                onChanged: (value) => setState(() => _macShortcuts = value),
              ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Haptic feedback'),
              value: _haptics,
              onChanged: (value) => setState(() => _haptics = value),
            ),
          ]),
        ),
  ];


  Widget _modeSwitcher() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: SegmentedButton<String>(
      key: const ValueKey('remote-mode-switcher'),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment<String>(value: 'remote',
          label: Text('Remote', maxLines: 1, softWrap: false)),
        ButtonSegment<String>(value: 'presentation',
          label: Text('Presentation', maxLines: 1, softWrap: false)),
        ButtonSegment<String>(value: 'media',
          label: Text('Media', maxLines: 1, softWrap: false)),
      ],
      selected: {
        _remoteLayout.presentationMode ? 'presentation'
            : _remoteLayout.mediaMode ? 'media' : 'remote'
      },
      onSelectionChanged: (selection) => _setLayout(
        _changedLayout(
          presenting: selection.first == 'presentation',
          mediaMode: selection.first == 'media',
        ),
      ),
    ),
  );

  Widget _visualModeSelector() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: SegmentedButton<String>(
      key: const ValueKey('screen-view-mode-switcher'),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment<String>(value: 'trackpad', label: Text('Trackpad')),
        ButtonSegment<String>(value: 'snapshot', label: Text('Snapshot')),
        ButtonSegment<String>(value: 'live', label: Text('Live')),
      ],
      selected: {VisualModePolicy.normalize(_remoteLayout.visualMode)},
      onSelectionChanged: agent.screenCaptureSupported
          ? (values) => _setLayout(_changedLayout(visualMode: values.first))
          : null,
    ),
  );

  Future<void> _searchMedia(MediaService service, String text) async {
    try {
      if (text.trim().isNotEmpty) {
        MediaSearch.url(service, text); // validate before contacting the agent
      }
      await agent.openMedia(service.name, text);
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)));
      }
    } catch (error) {
      _handleRemoteFailure(error);
    }
  }

  Widget _remoteInputSurface({double height = 224}) {
    if (VisualModePolicy.normalize(_remoteLayout.visualMode) == 'trackpad' ||
        !agent.screenCaptureSupported) {
      return _trackpadSurface(height: height);
    }
    return VisualSurface(
      key: ValueKey('remote-visual-${_remoteLayout.visualMode}'),
      height: height,
      frame: _currentFrame,
      live: _remoteLayout.visualMode == 'live',
      busy: _screenBusy,
      error: _screenError,
      onRefresh: () => unawaited(_refreshScreenshot()),
      onTap: (x, y, button) =>
          unawaited(command('tap', {'x': x, 'y': y, 'button': button})),
      onScroll: (ticks) =>
          unawaited(command('scroll', {'dy': ticks})),
    );
  }

  Widget _mediaView(bool landscape) {
    final selected = _remoteLayout.mediaService == 'netflix'
        ? MediaService.netflix : MediaService.youtube;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      MediaRemote(
        key: const ValueKey('media-remote'),
        service: selected,
        enabled: agent.configured && !_connectionLost,
        landscape: landscape,
        onServiceChanged: (service) =>
            _setLayout(_changedLayout(mediaService: service.name)),
        onKey: (key) => unawaited(command('key', {'key': key})),
        onSearch: (service, text) => _searchMedia(service, text),
        onOpenService: (service) => _searchMedia(service, ''),
      ),
      const SizedBox(height: 12),
      Text('Mouse and keyboard',
          style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      _trackpadSurface(height: landscape ? 100 : 140),
      const SizedBox(height: 8),
      _landscapeTyping(),
    ]);
  }

  Widget _presentationView(bool landscape) {
    final isMac = _connectedPlatform == 'darwin' ||
        (_connectedPlatform == null && _macShortcuts);
    final selected = PresentationApp.values.firstWhere(
      (candidate) => candidate.name == _remoteLayout.presentationApp,
      orElse: () => PresentationApp.powerPoint,
    );
    final app = !isMac && selected == PresentationApp.keynote
        ? PresentationApp.powerPoint : selected;
    return PresentationControls(
      key: const ValueKey('presentation-remote'),
      app: app,
      isMac: isMac,
      enabled: agent.configured && !_connectionLost,
      landscape: landscape,
      onAppChanged: (selection) => _setLayout(
        _changedLayout(presentationApp: selection.name),
      ),
      onKey: (key) => unawaited(command('key', {'key': key})),
    );
  }

  void _openLandscapeTools() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16,
              MediaQuery.viewInsetsOf(sheetContext).bottom + 16),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Keyboard & shortcuts',
                  style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 12),
              _keyboardControls(),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _immersiveLandscapeRemote() => LayoutBuilder(
    builder: (context, bounds) => Stack(fit: StackFit.expand, children: [
      _remoteInputSurface(height: bounds.maxHeight),
      Positioned(left: 12, top: 8, right: 12,
        child: Material(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(16),
          elevation: 3,
          child: Row(children: [
            const SizedBox(width: 8),
            Expanded(child: _visualModeSelector()),
            IconButton(
              key: const ValueKey('landscape-keyboard'),
              tooltip: 'Keyboard and shortcuts',
              onPressed: _openLandscapeTools,
              icon: const Icon(Icons.keyboard_outlined),
            ),
            PopupMenuButton<String>(
              tooltip: 'Remote options',
              icon: const Icon(Icons.more_vert),
              onSelected: (choice) {
                if (choice == 'presentation' || choice == 'media') {
                  _setLayout(_changedLayout(
                    presenting: choice == 'presentation',
                    mediaMode: choice == 'media',
                  ));
                } else if (choice == 'devices') {
                  _stopScreen();
                  agent.disconnect();
                  setState(() => status = 'Select a device to connect.');
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'presentation',
                    child: Text('Presentation')),
                PopupMenuItem(value: 'media', child: Text('Media')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'devices', child: Text('Switch computer')),
              ],
            ),
          ]),
        ),
      ),
      Positioned(left: 16, bottom: 8,
        child: IgnorePointer(child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(8)),
          child: Padding(padding: const EdgeInsets.symmetric(
              horizontal: 9, vertical: 4),
            child: Text(discoveredName ?? host.text.trim(),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall)),
        )),
      ),
    ]),
  );

  Widget _keyboardControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _landscapeTyping(),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: OutlinedButton.icon(
          onPressed: _connectionLost ? null :
              () => command('click', {'button': 'left'}),
          icon: const Icon(Icons.touch_app_outlined, size: 18),
          label: const Text('Left click'),
        )),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton.icon(
          onPressed: _connectionLost ? null :
              () => command('click', {'button': 'right'}),
          icon: const Icon(Icons.ads_click, size: 18),
          label: const Text('Right click'),
        )),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Text('Quick keys',
            style: Theme.of(context).textTheme.titleSmall)),
        TextButton.icon(
          onPressed: _customizeQuickKeys,
          icon: const Icon(Icons.tune, size: 16),
          label: const Text('Customize'),
        ),
      ]),
      if (_remoteLayout.quickKeys.isEmpty)
        const Text('Add your preferred keys using Customize.')
      else
        Wrap(spacing: 6, runSpacing: 3, children: [
          for (final id in _remoteLayout.quickKeys) _quickKeyButton(id),
        ]),
      TextButton.icon(
        key: const ValueKey('arrow-keys-toggle'),
        onPressed: () => _setLayout(_changedLayout(
          arrows: !_remoteLayout.arrowsExpanded)),
        icon: Icon(_remoteLayout.arrowsExpanded
            ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down),
        label: Text(_remoteLayout.arrowsExpanded
            ? 'Hide arrow keys' : 'Arrow keys'),
      ),
      if (_remoteLayout.arrowsExpanded) _arrowPad(),
      OutlinedButton.icon(
        key: const ValueKey('more-controls-toggle'),
        onPressed: () => _setLayout(_changedLayout(
          more: !_remoteLayout.moreExpanded)),
        icon: Icon(_remoteLayout.moreExpanded
            ? Icons.expand_less : Icons.expand_more),
        label: Text(_remoteLayout.moreExpanded
            ? 'Hide more controls' : 'More controls'),
      ),
      if (_remoteLayout.moreExpanded) ..._moreControlSections(),
    ],
  );

  Widget _landscapeTyping() => TextField(
    controller: typing,
    enabled: !_connectionLost,
    autocorrect: false,
    enableSuggestions: false,
    decoration: const InputDecoration(
      isDense: true,
      prefixIcon: Icon(Icons.keyboard_outlined),
      labelText: 'Type on computer',
    ),
    onChanged: (text) {
      if (text.isNotEmpty) {
        unawaited(command('text', {'text': text}));
        typing.clear();
      }
    },
  );

  Widget _connectedControls() {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_connectionLost) _connectionBanner(),
      if (_agentInputDenied && !_connectionLost)
        Card(
          key: const ValueKey('mac-accessibility-warning'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Mac input permission required',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                const Text('Open macOS System Settings → Privacy & Security '
                    '→ Accessibility and allow TapTether Input Core. '
                    'Then restart TapTether if needed.'),
              ]),
          ),
        ),
      _modeSwitcher(),
      if (_remoteLayout.presentationMode) _presentationView(landscape),
      if (_remoteLayout.mediaMode) _mediaView(landscape),
      if (!_remoteLayout.presentationMode && !_remoteLayout.mediaMode) ...[
        _visualModeSelector(),
        const SizedBox(height: 4),
        if (!_remoteLayout.keyboardExpanded) ...[
          Row(children: [
            Expanded(child: Text(
              VisualModePolicy.normalize(_remoteLayout.visualMode) == 'trackpad'
                  ? 'Trackpad' : 'Screen control',
              style: Theme.of(context).textTheme.titleSmall)),
            TextButton.icon(
              key: const ValueKey('trackpad-toggle'),
              onPressed: () => _setLayout(_changedLayout(
                trackpad: !_remoteLayout.trackpadExpanded,
                keyboard: false)),
              icon: Icon(_remoteLayout.trackpadExpanded
                  ? Icons.expand_less : Icons.expand_more, size: 18),
              label: Text(_remoteLayout.trackpadExpanded ? 'Hide' : 'Show'),
            ),
          ]),
          if (_remoteLayout.trackpadExpanded) _remoteInputSurface(),
        ],
        const SizedBox(height: 6),
        Card(child: ExpansionTile(
          key: ValueKey('remote-keyboard-${_remoteLayout.keyboardExpanded}'),
          initiallyExpanded: _remoteLayout.keyboardExpanded,
          leading: const Icon(Icons.keyboard_outlined),
          title: const Text('Keyboard & shortcuts'),
          subtitle: const Text('Expand to type or use extra keys'),
          onExpansionChanged: (expanded) => _setLayout(_changedLayout(
              keyboard: expanded, trackpad: !expanded)),
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: _keyboardControls()),
          ],
        )),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final connected = agent.configured;
    final immersive = connected &&
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        !_remoteLayout.presentationMode && !_remoteLayout.mediaMode;
    if (immersive) {
      return Scaffold(
        key: _scaffoldKey,
        body: SafeArea(child: _immersiveLandscapeRemote()),
      );
    }
    return Scaffold(
      key: _scaffoldKey,
      drawer: appDrawer(),
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Open navigation',
          icon: const Icon(Icons.menu),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: connected
            ? Row(children: [
                Icon(Icons.circle, size: 10,
                  color: _connectionLost
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(discoveredName ?? host.text.trim(),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              ])
            : const Text('TapTether'),
        actions: [
          if (connected) IconButton(
            tooltip: 'Switch computer',
            onPressed: () {
              _stopScreen();
              agent.disconnect();
              setState(() => status = 'Select a device to connect.');
            },
            icon: const Icon(Icons.swap_horiz),
          ),
          if (connected) IconButton(
            tooltip: 'Disconnect',
            onPressed: () {
              _stopScreen();
              agent.disconnect();
              setState(() => status = 'Disconnected');
            },
            icon: const Icon(Icons.link_off),
          ),
      ]),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
        if (!connected) ...[
          Text('Your devices. Your control. Your network.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w500,
              )),
          const SizedBox(height: 12),
        ],
        if (!connected) updateNotices(),
        if (!connected) ...[
          deviceDashboard(),
          if (_showPairForm) ...[
          const Text('Pair with a computer agent', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('For first-time pairing, enter the token and TLS SHA-256 fingerprint from your computer. Verified devices are saved securely on this phone.'),
          const SizedBox(height: 12),
          TextField(controller: host, autocorrect: false,
              decoration: const InputDecoration(labelText: 'Computer LAN IP (e.g. 192.168.1.10)', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: token, obscureText: true, autocorrect: false,
              decoration: const InputDecoration(labelText: 'Agent pairing token', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: pin, autocorrect: false,
              decoration: const InputDecoration(labelText: 'Certificate SHA-256 fingerprint', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          FilledButton.icon(onPressed: () async { await connect(); }, icon: const Icon(Icons.lan), label: const Text('Connect locally')),
          ],
        ] else ...[
          _connectedControls(),
        ],
        const SizedBox(height: 16),
        if (!connected) ...[
          Text(status, style: TextStyle(fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Center(child: Text('TapTether v$installedVersion',
            style: TextStyle(fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant))),
        ],
      ])),
    );
  }
}
