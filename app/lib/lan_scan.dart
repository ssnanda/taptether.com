import 'dart:async';
import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'discovery.dart';
import 'network_probes.dart';

/// Non-invasive, on-demand TCP discovery across one private /24 only.
/// Mobile operating systems do not generally expose neighbor ARP/MAC records.
class LanHost {
  const LanHost({
    required this.ip,
    required this.hostname,
    required this.openPorts,
    this.macAddress,
    this.platform,
    this.agentAnnounced = false,
  });
  final String ip;
  final String hostname;
  final List<int> openPorts;
  final String? macAddress;
  // UDP announcements are not authenticated; verification still requires
  // the saved TLS fingerprint and credentials.
  final String? platform;
  final bool agentAnnounced;

  String get deviceType {
    if (agentAnnounced) {
      switch (platform) {
        case 'darwin': return 'Mac · TapTether agent (unverified)';
        case 'linux': return 'Linux · TapTether agent (unverified)';
        case 'windows': return 'Windows · TapTether agent (unverified)';
        default: return 'TapTether agent (unverified)';
      }
    }
    if (openPorts.contains(48321)) return 'TapTether computer (unverified)';
    if (openPorts.contains(3389)) return 'Remote Desktop computer';
    if (openPorts.contains(445)) return 'File sharing device';
    if (openPorts.contains(22)) return 'SSH-enabled computer / server';
    if (openPorts.contains(80) || openPorts.contains(443)) {
      return 'Web-enabled device';
    }
    return 'Network device';
  }

  /// No duplicate IPv4 title/subtitle when DNS provides no hostname.
  String get displayName => hostname.trim().isNotEmpty && hostname != ip
      ? hostname : deviceType;

  String get scanSubtitle {
    final extra = displayName == deviceType ? '' : ' · $deviceType';
    final tcp = openPorts.isEmpty ? '' : '\nTCP: ${openPorts.join(", ")}';
    return 'IP: $ip$extra$tcp';
  }

  String get deviceHint {
    if (openPorts.contains(48321)) return 'TapTether agent (likely)';
    if (openPorts.contains(3389)) return 'Remote Desktop device';
    if (openPorts.contains(445)) return 'File sharing / computer';
    if (openPorts.contains(22)) return 'SSH-enabled computer or server';
    if (openPorts.contains(80) || openPorts.contains(443)) {
      return 'Web-enabled device';
    }
    return 'Network device';
  }
}

const lanScanPorts = <int>[48321, 22, 80, 443, 445, 3389];

bool validPrivate24Prefix(String prefix) =>
    isPrivateIPv4('${prefix.trim()}.1');

String? prefixFromIp(String ip) {
  if (!isPrivateIPv4(ip)) return null;
  return ip.split('.').take(3).join('.');
}


class DetectedLanRange {
  const DetectedLanRange({
    required this.ip,
    required this.subnetMask,
    required this.cidr,
    required this.activePrefix,
    required this.scanPrefixes,
    this.ssid,
  });
  final String ip;
  final String subnetMask;
  final String cidr;
  final String activePrefix;
  final List<String> scanPrefixes;
  final String? ssid;
}

int? _ipv4Number(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return null;
  var result = 0;
  for (final item in parts) {
    final n = int.tryParse(item);
    if (n == null || n < 0 || n > 255) return null;
    result = (result << 8) | n;
  }
  return result;
}

String _formatIpv4(int value) =>
    [24, 16, 8, 0].map((shift) => (value >> shift) & 255).join('.');

/// Determines the real CIDR; scanners remain bounded to one /24 at a time.
/// On /22 or larger LANs the user can choose a neighboring /24 window.
DetectedLanRange? rangeFromWifi(String ip, String mask, {String? ssid}) {
  if (!isPrivateIPv4(ip)) return null;
  final address = _ipv4Number(ip), subnet = _ipv4Number(mask);
  if (address == null || subnet == null || subnet == 0) return null;
  final hostBits = (~subnet) & 0xffffffff;
  // A valid subnet has contiguous high bits, then contiguous host bits.
  if ((hostBits & (hostBits + 1)) != 0) return null;
  final network = address & subnet;
  final broadcast = network | hostBits;
  final active = prefixFromIp(ip)!;
  final base24 = network >> 8, last24 = broadcast >> 8;
  final current = address >> 8;
  final prefixes = <String>[active];
  // At most 16 selectable /24 slices, not an unbounded scan.
  for (var distance = 1; prefixes.length < 16 &&
      (current - distance >= base24 || current + distance <= last24);
      distance++) {
    for (final offset in [-distance, distance]) {
      final selected = current + offset;
      if (selected < base24 || selected > last24) continue;
      prefixes.add(_formatIpv4(selected << 8).split('.').take(3).join('.'));
      if (prefixes.length == 16) break;
    }
  }
  return DetectedLanRange(
    ip: ip,
    subnetMask: mask,
    cidr: '${_formatIpv4(network)}/${32 - hostBits.bitLength}',
    activePrefix: active,
    scanPrefixes: prefixes,
    ssid: ssid,
  );
}

/// True only for a private IP on the detected subnet, including /22.
/// Used for current-network device grouping, not authentication.
bool lanRangeContains(DetectedLanRange range, String ip) {
  if (!isPrivateIPv4(ip)) return false;
  final addr = _ipv4Number(ip);
  final local = _ipv4Number(range.ip);
  final mask = _ipv4Number(range.subnetMask);
  return addr != null && local != null && mask != null &&
      (addr & mask) == (local & mask);
}

/// A full CIDR scan must include addresses at internal /24 boundaries.
/// For example, 192.168.20.255 and 192.168.21.0 are valid on /23.
/// Only the actual CIDR network and broadcast addresses are excluded.
({int startHost, int endHost}) scanPrefixBounds(
    DetectedLanRange network, String prefix) {
  final ipParts = network.ip.split('.').map(int.parse).toList();
  final maskParts = network.subnetMask.split('.').map(int.parse).toList();
  final broadcast = <int>[
    for (var i = 0; i < 4; i++)
      ipParts[i] | (255 ^ maskParts[i]),
  ].join('.');
  final networkAddress = network.cidr.split('/').first;
  return (
    startHost: networkAddress == '$prefix.0' ? 1 : 0,
    endHost: broadcast == '$prefix.255' ? 254 : 255,
  );
}

/// A private 10.x or 172.16.x address is not evidence of Wi-Fi: phones
/// also receive private cellular and VPN addresses. Never scan those networks.
bool localDiscoveryTransport(List<ConnectivityResult> transports) =>
    transports.contains(ConnectivityResult.wifi) ||
    transports.contains(ConnectivityResult.ethernet);

/// Limit fallback addresses to known local Wi-Fi/Ethernet interfaces.
/// In particular do not use cellular pdp_ip/rmnet, VPN utun/tun or bridge IPs.
bool localDiscoveryInterface(String name) {
  final value = name.toLowerCase();
  return value == 'en0' || value == 'en1' ||
      value.startsWith('wlan') || value.startsWith('wifi') ||
      value.startsWith('wl') || value.startsWith('eth');
}

/// Return a usable Wi-Fi/Ethernet LAN only while the current transport is
/// local. Never fall back to the first arbitrary private NetworkInterface.
Future<DetectedLanRange?> detectLanRange() async {
  try {
    final transports = await Connectivity().checkConnectivity();
    if (!localDiscoveryTransport(transports)) return null;
  } catch (_) {
    // If the OS cannot verify a local transport, fail closed.
    return null;
  }
  try {
    final info = NetworkInfo();
    final ip = await info.getWifiIP();
    final mask = await info.getWifiSubmask();
    if (ip != null && mask != null) {
      String? ssid;
      try {
        ssid = await info.getWifiName();
      } catch (_) {
        // iOS can withhold SSID even when Wi-Fi is connected.
      }
      final range = rangeFromWifi(ip, mask, ssid: ssid);
      if (range != null) return range;
    }
  } catch (_) {
    // The transport was verified but Wi-Fi metadata is unavailable.
  }
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4, includeLoopback: false,
    );
    for (final interface in interfaces) {
      if (!localDiscoveryInterface(interface.name)) continue;
      for (final address in interface.addresses) {
        if (isPrivateIPv4(address.address)) {
          // Wi-Fi interface verified, netmask unknown. Use one /24 only.
          return rangeFromWifi(address.address, '255.255.255.0');
        }
      }
    }
  } catch (_) {}
  return null;
}

Future<String?> defaultScanPrefix() async =>
    (await detectLanRange())?.activePrefix;

/// Merge a best-effort, unauthenticated agent announcement with TCP results
/// by IP. Agent hosts can appear even if none of the scanned TCP ports responds.
/// Never treat a UDP platform/name as proof of the computer's identity.
List<LanHost> mergeDiscoveredAgents(
  List<LanHost> tcpHosts,
  List<DiscoveredDevice> announcements,
  String prefix,
) {
  final byIp = <String, LanHost>{for (final host in tcpHosts) host.ip: host};
  for (final device in announcements) {
    if (!isPrivateIPv4(device.host) ||
        prefixFromIp(device.host) != prefix) {
      continue;
    }
    final existing = byIp[device.host];
    byIp[device.host] = LanHost(
      ip: device.host,
      hostname: device.name,
      openPorts: existing?.openPorts ?? const [],
      macAddress: existing?.macAddress,
      platform: device.platform,
      agentAnnounced: true,
    );
  }
  return byIp.values.toList()
    ..sort((a, b) {
      final aParts = a.ip.split('.').map(int.parse).toList();
      final bParts = b.ip.split('.').map(int.parse).toList();
      for (var i = 0; i < 4; i++) {
        final diff = aParts[i].compareTo(bParts[i]);
        if (diff != 0) return diff;
      }
      return 0;
    });
}

/// Merge unauthenticated discovery hints from SSDP and multicast DNS.
List<LanHost> mergeLanNeighbors(
    List<LanHost> current, List<LanProbeHost> neighbors, String prefix) {
  final byIp = <String, LanHost>{for (final host in current) host.ip: host};
  for (final entry in neighbors) {
    if (prefixFromIp(entry.ip) != prefix) continue;
    final known = byIp[entry.ip];
    if (known == null) {
      byIp[entry.ip] = LanHost(
          ip: entry.ip, hostname: entry.name, openPorts: const []);
    } else if (!known.agentAnnounced &&
        (known.hostname.isEmpty || known.hostname == known.ip)) {
      byIp[entry.ip] = LanHost(
        ip: known.ip, hostname: entry.name,
        openPorts: known.openPorts, macAddress: known.macAddress,
        platform: known.platform, agentAnnounced: known.agentAnnounced,
      );
    }
  }
  return byIp.values.toList()..sort((a, b) {
    final left = a.ip.split('.').map(int.parse).toList();
    final right = b.ip.split('.').map(int.parse).toList();
    for (var i = 0; i < 4; i++) {
      final diff = left[i].compareTo(right[i]);
      if (diff != 0) return diff;
    }
    return 0;
  });
}

/// User-requested one-IP check for computers like a Mac with firewall-
/// protected ports. A non-responding host is *not* represented as online.
Future<LanHost?> checkPrivateLanIp(
  String ip, {
  Duration timeout = const Duration(milliseconds: 550),
}) async {
  if (!isPrivateIPv4(ip)) {
    throw const FormatException('Enter an address on a private LAN');
  }
  Future<bool> accepting(int port) async {
    try {
      final socket = await Socket.connect(ip, port, timeout: timeout);
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  final discovery = findNearbyDevices(
    targetIp: ip,
    duration: const Duration(milliseconds: 1100),
  ).catchError((Object _) => <DiscoveredDevice>[]);
  final listening = await Future.wait(lanScanPorts.map(accepting));
  final ports = <int>[
    for (var index = 0; index < lanScanPorts.length; index++)
      if (listening[index]) lanScanPorts[index],
  ];
  final announcements = await discovery;
  var hostname = ip;
  if (ports.isNotEmpty) {
    try {
      final resolved = await InternetAddress(ip)
          .reverse().timeout(const Duration(milliseconds: 650));
      if (resolved.host != ip) hostname = resolved.host;
    } catch (_) {
      // Reverse DNS isn't required to probe a LAN address.
    }
  }
  final matches = mergeDiscoveredAgents(
    ports.isEmpty ? const <LanHost>[] : [
      LanHost(ip: ip, hostname: hostname, openPorts: ports),
    ],
    announcements,
    prefixFromIp(ip)!,
  );
  return matches.isEmpty ? null : matches.first;
}

/// Reports only hosts accepting at least one tested TCP port; this is
/// not a complete inventory of devices behind firewalls or with no open ports.
Future<List<LanHost>> scanPrivate24(
  String prefix, {
  void Function(int completed, int total)? onProgress,
  void Function(LanHost candidate)? onAgentFound,
  void Function(String ip, List<int> respondingPorts)? onProbe,
  bool Function()? cancelled,
  int parallelism = 24,
  int hostCount = 254,
  int startHost = 1,
  int? endHost,
  Duration timeout = const Duration(milliseconds: 450),
}) async {
  prefix = prefix.trim();
  if (!validPrivate24Prefix(prefix)) {
    throw const FormatException('Enter a private IPv4 /24 prefix, e.g. 192.168.1');
  }
  final lastHost = endHost ?? hostCount;
  if (parallelism < 1 || parallelism > 32 || hostCount < 1 ||
      hostCount > 254 || startHost < 0 || startHost > 255 ||
      lastHost < startHost || lastHost > 255) {
    throw const FormatException('Invalid scan bounds.');
  }
  final scanTotal = lastHost - startHost + 1;
  final results = <LanHost>[];
  // Probe the agent's local UDP discovery protocol alongside TCP. If UDP
  // broadcast is blocked by iOS or a firewall the TCP scan still works.
  final agentDiscovery = findNearbyDevices(
    scanPrefix: prefix,
    duration: const Duration(seconds: 2),
  ).catchError((Object _) => <DiscoveredDevice>[]);
  final neighborDiscovery = discoverLanNeighbors(prefix)
      .catchError((Object _) => <LanProbeHost>[]);
  var next = startHost;
  var done = 0;
  Future<bool> listening(String host, int port) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> worker() async {
    while (next <= lastHost && !(cancelled?.call() ?? false)) {
      final last = next++;
      final host = '$prefix.$last';
      final checked = await Future.wait(
        lanScanPorts.map((port) => listening(host, port)),
      );
      final ports = <int>[
        for (var i = 0; i < lanScanPorts.length; i++)
          if (checked[i]) lanScanPorts[i],
      ];
      onProbe?.call(host, ports);
      if (ports.isNotEmpty) {
        var name = host;
        try {
          final resolved = await InternetAddress(host)
              .reverse()
              .timeout(const Duration(milliseconds: 650));
          if (resolved.host != host) name = resolved.host;
        } on SocketException {
          // Reverse DNS isn't always configured on local networks.
        } on TimeoutException {
          // Keep the discovered IP without blocking the scan.
        }
        final candidate = LanHost(ip: host, hostname: name, openPorts: ports);
        results.add(candidate);
        // Tell the UI as soon as the TapTether port responds; do not wait
        // until all 254 addresses have completed their unrelated port tests.
        // The caller must authenticate the TLS pin and paired phone before
        // trusting this unverified TCP candidate.
        if (ports.contains(48321)) onAgentFound?.call(candidate);
      }
      done++;
      if (done % 8 == 0 || done == scanTotal) {
        onProgress?.call(done, scanTotal);
      }
    }
  }
  await Future.wait(List.generate(
    parallelism < scanTotal ? parallelism : scanTotal,
    (_) => worker(),
  ));
  if (cancelled?.call() ?? false) {
    return mergeDiscoveredAgents(results, const [], prefix);
  }
  final announced = await agentDiscovery;
  final neighbors = await neighborDiscovery;
  return mergeLanNeighbors(
      mergeDiscoveredAgents(results, announced, prefix), neighbors, prefix);
}
