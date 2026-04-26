import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/device_info.dart';

const int _kDiscoveryPort = 45678;
const int _kBeaconIntervalSeconds = 2;
const int _kDeviceTimeoutSeconds = 15;
const int _kCleanupIntervalSeconds = 5; // check for stale devices frequently
const String _kMagicPrefix = 'TCPSHARE:';

class DiscoveryService extends ChangeNotifier {
  RawDatagramSocket? _socket;
  Timer? _beaconTimer;
  Timer? _cleanupTimer;
  DeviceInfo? _self;
  List<String> _subnetBroadcasts =
      []; // cached, refreshed on start/forceRefresh

  final Map<String, DeviceInfo> _peers = {};
  List<DeviceInfo> get peers =>
      _peers.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  bool get isRunning => _socket != null;
  DeviceInfo? get selfInfo => _self;

  // ─── Public control ──────────────────────────────────────────────────────────

  Future<void> start(DeviceInfo self) async {
    _self = self;
    _subnetBroadcasts = await _fetchSubnetBroadcasts();
    await _bindSocket();
    _startBeaconing();
    _startCleanupTimer();
  }

  /// Call when the user changes their device name in Settings.
  void updateSelf(DeviceInfo self) {
    _self = self;
    _sendBeaconBurst();
  }

  /// Update the receiving mode flag and immediately broadcast it.
  /// Call this whenever the user switches between the Receive and Send tabs.
  void setReceivingMode(bool receiving) {
    final current = _self;
    if (current == null) return;
    if (current.isReceiving == receiving) return; // no change
    _self = current.copyWith(isReceiving: receiving);
    _sendBeaconBurst();
  }

  /// Broadcast a burst of beacons so peers can immediately see this device.
  /// Call after a transfer completes to prevent peer entries from going stale.
  void announceSelf() => _sendBeaconBurst();

  /// Force an immediate re-discover: clear stale peers, send a beacon burst.
  /// The UI calls this when the user taps the Refresh button.
  Future<void> forceRefresh() async {
    _subnetBroadcasts = await _fetchSubnetBroadcasts();
    _peers.clear();
    notifyListeners();
    _sendBeaconBurst();
  }

  // ─── Socket ──────────────────────────────────────────────────────────────────

  Future<void> _bindSocket() async {
    // Attempt to bind with retries — the port may be briefly held after a hot
    // reload or OS socket cleanup. reusePort is set to true where supported
    // but some platforms (notably some Windows configs) ignore it gracefully.
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        _socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          _kDiscoveryPort,
          reuseAddress: true,
          reusePort:
              true, // needed on Android for multi-process; harmless on Windows
        );
        _socket!.broadcastEnabled = true;
        _socket!.listen(_onDatagram);
        debugPrint('[Discovery] UDP socket bound on port $_kDiscoveryPort');
        return;
      } catch (e) {
        debugPrint('[Discovery] Bind attempt ${attempt + 1} failed: $e');
        if (attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    }
    // Last-resort: try reusePort: false in case the platform rejects it
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _kDiscoveryPort,
        reuseAddress: true,
        reusePort: false,
      );
      _socket!.broadcastEnabled = true;
      _socket!.listen(_onDatagram);
      debugPrint(
          '[Discovery] UDP socket bound (reusePort=false fallback) on port $_kDiscoveryPort');
    } catch (e) {
      debugPrint('[Discovery] FATAL: could not bind UDP socket: $e');
      rethrow;
    }
  }

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;

    try {
      final message = utf8.decode(dg.data);
      if (!message.startsWith(_kMagicPrefix)) return;
      final payload = message.substring(_kMagicPrefix.length);
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final device = DeviceInfo.fromJson(json);

      // Ignore ourselves
      if (device.id == _self?.id) return;

      // Ignore packets from unreachable subnets (e.g. Android emulator at
      // 10.0.2.x when we are on 192.168.x.x). If we have known subnet
      // broadcasts, the sender's IP must share a /24 with at least one of them.
      if (_subnetBroadcasts.isNotEmpty) {
        final senderIp = dg.address.address;
        final senderPrefix =
            senderIp.split('.').take(3).join('.');
        final reachable = _subnetBroadcasts.any(
            (bc) => bc.split('.').take(3).join('.') == senderPrefix);
        if (!reachable) {
          debugPrint(
              '[Discovery] Ignoring unreachable peer ${device.name} ($senderIp)');
          return;
        }
      }

      final wasNew = !_peers.containsKey(device.id);
      _peers[device.id] = device.copyWith(lastSeen: DateTime.now());
      // Only notify if state changed (new peer or receiving-mode toggled)
      final prev = _peers[device.id];
      if (wasNew || prev?.isReceiving != device.isReceiving) {
        notifyListeners();
      } else {
        // Always notify to keep lastSeen fresh in UI
        notifyListeners();
      }
    } catch (_) {}
  }

  // ─── Beaconing ───────────────────────────────────────────────────────────────

  void _startBeaconing() {
    _sendBeaconBurst(); // immediate burst on start
    _beaconTimer = Timer.periodic(
      const Duration(seconds: _kBeaconIntervalSeconds),
      (_) => _sendBeacon(),
    );
  }

  /// Send 5 beacons ~200 ms apart for robust initial / refresh discovery
  /// across platforms with varying UDP multicast/broadcast reliability.
  void _sendBeaconBurst() {
    _sendBeacon();
    Future.delayed(const Duration(milliseconds: 200), _sendBeacon);
    Future.delayed(const Duration(milliseconds: 400), _sendBeacon);
    Future.delayed(const Duration(milliseconds: 800), _sendBeacon);
    Future.delayed(const Duration(milliseconds: 1400), _sendBeacon);
  }

  /// Sends the UDP beacon on the broadcast address AND on every non-loopback
  /// IPv4 interface's subnet broadcast. This ensures the hotspot-host device
  /// (which lives on a different adapter) is also announced on that subnet.
  void _sendBeacon() {
    if (_self == null || _socket == null) return;
    final data = utf8.encode('$_kMagicPrefix${_self!.toBeacon()}');

    // Always send to global broadcast
    _sendTo(data, '255.255.255.255');

    // Also send subnet-directed broadcasts using the cached interface list
    for (final addr in _subnetBroadcasts) {
      _sendTo(data, addr);
    }
  }

  void _sendTo(List<int> data, String address) {
    try {
      _socket!.send(data, InternetAddress(address), _kDiscoveryPort);
    } catch (_) {}
  }

  /// Fetches subnet-directed broadcast addresses for all non-loopback IPv4
  /// interfaces, filtering out known virtual/VPN adapters on Windows.
  Future<List<String>> _fetchSubnetBroadcasts() async {
    final result = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        // Skip obvious virtual adapters that won't reach real LAN peers.
        if (_isVirtualInterface(iface.name)) continue;
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          // Assume /24 — covers all common home/hotspot subnets
          final broadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
          if (!result.contains(broadcast)) {
            result.add(broadcast);
          }
        }
      }
    } catch (_) {}
    debugPrint('[Discovery] Subnet broadcasts: $result');
    return result;
  }

  // ─── Cleanup ─────────────────────────────────────────────────────────────────

  void _startCleanupTimer() {
    _cleanupTimer = Timer.periodic(
      const Duration(seconds: _kCleanupIntervalSeconds),
      (_) {
        final cutoff = DateTime.now()
            .subtract(const Duration(seconds: _kDeviceTimeoutSeconds));
        final staleKeys = _peers.entries
            .where((e) => e.value.lastSeen.isBefore(cutoff))
            .map((e) => e.key)
            .toList();
        if (staleKeys.isNotEmpty) {
          for (final key in staleKeys) {
            debugPrint(
                '[Discovery] Removing stale peer: ${_peers[key]?.name}');
            _peers.remove(key);
          }
          notifyListeners();
        }
      },
    );
  }

  void stop() {
    _beaconTimer?.cancel();
    _cleanupTimer?.cancel();
    _socket?.close();
    _socket = null;
    _peers.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  static String generateId() {
    final rng = Random.secure();
    return List.generate(
        8, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Returns true for known virtual/internal adapters that should not be used
/// for LAN discovery broadcasts — this filters out Hyper-V, VPN, WSL, etc.
bool _isVirtualInterface(String name) {
  final lower = name.toLowerCase();
  // Windows hotspot can use Wi-Fi Direct "virtual" adapters; keep them.
  if (lower.contains('wi-fi direct')) {
    return false;
  }
  // Windows virtual adapters
  if (lower.contains('hyper-v') || lower.contains('hyperv')) {
    return true;
  }
  if (lower.contains('vethernet')) {
    return true;
  }
  if (lower.contains('wsl') || lower.contains('loopback')) {
    return true;
  }
  if (lower.contains('virtualbox') || lower.contains('vmware')) {
    return true;
  }
  if (lower.contains('vpn') ||
      lower.contains('tap-') ||
      lower.contains('tun')) {
    return true;
  }
  // Docker bridge
  if (lower.contains('docker') || lower.contains('br-')) {
    return true;
  }
  return false;
}
