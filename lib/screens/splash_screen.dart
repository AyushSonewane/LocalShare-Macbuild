import 'dart:io';
import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:provider/provider.dart';
import '../models/device_info.dart';
import '../services/discovery_service.dart';
import '../services/file_transfer_service.dart';
import '../services/settings_service.dart';
import '../services/share_intent_service.dart';
import '../services/tcp_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';
import 'onboarding_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final AnimationController _pulseCtrl; // for the pulsing glow ring
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _textOpacity;
  late final Animation<Offset> _textSlide;
  late final Animation<double> _taglineOpacity;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    // Logo scales up from 0.5 → 1
    _logoScale = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOutBack),
      ),
    );
    // Logo fades in
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
      ),
    );
    // App name fades in + slides up
    _textOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.35, 0.65, curve: Curves.easeOut),
      ),
    );
    _textSlide = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.35, 0.65, curve: Curves.easeOut),
    ));
    // Tagline fades in last
    _taglineOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.55, 0.85, curve: Curves.easeOut),
      ),
    );

    _ctrl.forward();

    // Pulsing glow ring — continuous, independent of intro animation
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Run init in parallel with animation; navigate when both are ready
    _initAndNavigate();
  }

  Future<void> _initAndNavigate() async {
    // Minimum splash display time + actual init time run in parallel
    final results = await Future.wait([
      _doInit(),
      Future.delayed(const Duration(milliseconds: 2200)),
    ]);

    final initData = results[0] as _InitResult;

    if (!mounted) return;
    _navigate(initData);
  }

  Future<_InitResult> _doInit() async {
    final settings = context.read<SettingsService>();
    final discoveryService = context.read<DiscoveryService>();
    final transferService = context.read<FileTransferService>();
    // Capture before any awaits to avoid use_build_context_synchronously.
    final shareIntentService = context.read<ShareIntentService>();

    final localIp = await _resolveLocalIp();
    final storedId =
        discoveryService.selfInfo?.id ?? DiscoveryService.generateId();
    final deviceName =
        settings.deviceName.isNotEmpty ? settings.deviceName : _safeHostname();

    final selfDevice = DeviceInfo(
      id: storedId,
      name: deviceName,
      ip: localIp,
      port: kTransferPort,
      lastSeen: DateTime.now(),
      platform: Platform.operatingSystem,
    );

    if (!transferService.isInitialized) {
      await transferService.initialize(selfDevice);
    }

    // Start listening for OS share intents.
    shareIntentService.initialize();

    return _InitResult(
      selfDevice: selfDevice,
      isFirstLaunch: !settings.hasSeenOnboarding,
    );
  }

  void _navigate(_InitResult data) {
    final route = data.isFirstLaunch
        ? PageRouteBuilder<void>(
            pageBuilder: (_, __, ___) =>
                OnboardingScreen(selfDevice: data.selfDevice),
            transitionsBuilder: (_, anim, __, child) => FadeTransition(
              opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
              child: child,
            ),
            transitionDuration: const Duration(milliseconds: 500),
          )
        : PageRouteBuilder<void>(
            pageBuilder: (_, __, ___) =>
                HomeScreen(selfDevice: data.selfDevice),
            transitionsBuilder: (_, anim, __, child) => FadeTransition(
              opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
              child: child,
            ),
            transitionDuration: const Duration(milliseconds: 500),
          );

    Navigator.of(context).pushReplacement(route);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.0,
            colors: [
              Color(0xFF1A1830), // slightly warm dark at centre
              AppTheme.background,
            ],
            stops: [0.0, 1.0],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Logo orb with pulsing glow ───────────────────────────────
              ScaleTransition(
                scale: _logoScale,
                child: FadeTransition(
                  opacity: _logoOpacity,
                  child: _LogoOrb(pulseAnim: _pulseAnim),
                ),
              ),
              const SizedBox(height: 28),

              // ── App name ─────────────────────────────────────────────────
              FadeTransition(
                opacity: _textOpacity,
                child: SlideTransition(
                  position: _textSlide,
                  child: Text(
                    'LocalShare',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                      height: 1,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // ── Tagline ───────────────────────────────────────────────
              FadeTransition(
                opacity: _taglineOpacity,
                child: Text(
                  'Share files instantly over LAN',
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),

      // ── Bottom status + pulsing dots ────────────────────────────────
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.only(bottom: 48),
        child: FadeTransition(
          opacity: _taglineOpacity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Connecting…',
                style: TextStyle(
                  color: AppTheme.textSecondary.withValues(alpha: 0.6),
                  fontSize: 11,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 10),
              _PulsingDots(),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Logo orb ───────────────────────────────────────────────────────────────

class _LogoOrb extends StatelessWidget {
  final Animation<double> pulseAnim;
  const _LogoOrb({required this.pulseAnim});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulseAnim,
      builder: (_, __) {
        return Stack(
          alignment: Alignment.center,
          children: [
            // Outer pulsing glow ring
            Transform.scale(
              scale: pulseAnim.value,
              child: Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AppTheme.accentPrimary
                          .withValues(alpha: 0.22 * (2.0 - pulseAnim.value)),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            // Mid ring
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.surface,
                border: Border.all(
                  color: AppTheme.accentPrimary.withValues(alpha: 0.4),
                  width: 1.5,
                ),
              ),
            ),
            // Inner icon
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppTheme.accentPrimary, AppTheme.accentSecondary],
                ),
              ),
              child: const Icon(
                Icons.wifi_tethering_rounded,
                color: Colors.white,
                size: 36,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Pulsing loading dots ─────────────────────────────────────────────────────

class _PulsingDots extends StatefulWidget {
  @override
  State<_PulsingDots> createState() => _PulsingDotsState();
}

class _PulsingDotsState extends State<_PulsingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final delay = i * 0.2;
        final anim = Tween<double>(begin: 0.3, end: 1.0).animate(
          CurvedAnimation(
            parent: _ctrl,
            curve: Interval(delay, (delay + 0.6).clamp(0, 1),
                curve: Curves.easeInOut),
          ),
        );
        return AnimatedBuilder(
          animation: anim,
          builder: (_, __) => Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.accentPrimary.withValues(alpha: anim.value),
            ),
          ),
        );
      }),
    );
  }
}

// ─── Init helpers ─────────────────────────────────────────────────────────────

class _InitResult {
  final DeviceInfo selfDevice;
  final bool isFirstLaunch;
  const _InitResult({required this.selfDevice, required this.isFirstLaunch});
}

/// Resolves the best local IPv4 address for LAN communication.
///
/// Strategy:
///   1. Try `NetworkInfo().getWifiIP()` (works well on Android/iOS).
///   2. Enumerate all non-loopback IPv4 interfaces, skipping virtual adapters
///      (Hyper-V, VPN, WSL, VirtualBox, Docker, etc.).
///   3. Among real adapters, prefer private LAN addresses (192.168, 10.x, 172.16-31).
///   4. Use a UDP-connect trick to ask the OS which source IP it would use to
///      reach a well-known public address — gives the default-route interface.
///   5. Fall back to the first non-loopback address, then 127.0.0.1.
Future<String> _resolveLocalIp() async {
  // --- Step 1: platform API (mobile) ---
  try {
    final ip = await NetworkInfo().getWifiIP();
    if (ip != null && ip.isNotEmpty && ip != '127.0.0.1') {
      debugPrint('[IP] NetworkInfo returned: $ip');
      return ip;
    }
  } catch (_) {}

  // --- Step 2: enumerate interfaces, skip virtual ---
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );

    String? bestPrivate;
    String? bestOther;

    for (final iface in interfaces) {
      if (_isVirtualInterfaceName(iface.name)) {
        debugPrint('[IP] Skipping virtual interface: ${iface.name}');
        continue;
      }
      for (final addr in iface.addresses) {
        if (addr.isLoopback) continue;
        final ip = addr.address;
        debugPrint('[IP] Candidate: ${iface.name} -> $ip');
        if (_isPrivateLan(ip)) {
          bestPrivate ??= ip;
        } else {
          bestOther ??= ip;
        }
      }
    }

    if (bestPrivate != null) {
      debugPrint('[IP] Chose private LAN address: $bestPrivate');
      return bestPrivate;
    }
    if (bestOther != null) {
      debugPrint('[IP] Chose non-LAN address: $bestOther');
      return bestOther;
    }
  } catch (e) {
    debugPrint('[IP] Interface enumeration error: $e');
  }

  // --- Step 3: UDP-connect trick (removed because RawDatagramSocket lacks connect in Dart) ---

  debugPrint('[IP] Falling back to 127.0.0.1');
  return '127.0.0.1';
}

bool _isPrivateLan(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]) ?? 0;
  final b = int.tryParse(parts[1]) ?? 0;
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  return false;
}

/// Returns true for known virtual/internal network interfaces.
bool _isVirtualInterfaceName(String name) {
  final lower = name.toLowerCase();
  // Windows hotspot can run over Wi-Fi Direct "virtual" adapters.
  if (lower.contains('wi-fi direct')) {
    return false;
  }
  if (lower.contains('hyper-v') || lower.contains('hyperv')) {
    return true;
  }
  if (lower.contains('vethernet')) {
    return true;
  }
  if (lower.contains('wsl') || lower.contains('loopback adapter')) {
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
  if (lower.contains('docker') || lower.contains('br-')) {
    return true;
  }
  // Windows specific
  if (lower.startsWith('isatap') || lower.startsWith('teredo')) {
    return true;
  }
  return false;
}

String _safeHostname() {
  try {
    final h = Platform.localHostname;
    return h.length > 20 ? h.substring(0, 20) : h;
  } catch (_) {
    return 'Unknown';
  }
}
