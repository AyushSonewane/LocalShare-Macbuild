import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/device_info.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

// ─── Page data ────────────────────────────────────────────────────────────────

class _OnboardingPage {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String subtitle;

  const _OnboardingPage({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.subtitle,
  });
}

const _pages = [
  _OnboardingPage(
    icon: Icons.wifi_tethering_rounded,
    iconColor: AppTheme.accentPrimary,
    iconBg: AppTheme.accentGlow,
    title: 'Share Anything,\nInstantly',
    subtitle:
        'Send any file — photos, documents, videos — to nearby devices with a single tap. No cables. No accounts.',
  ),
  _OnboardingPage(
    icon: Icons.radar_rounded,
    iconColor: AppTheme.accentSecondary,
    iconBg: Color(0x2200B4D8),
    title: 'Auto-Discover\nNearby Devices',
    subtitle:
        'LocalShare automatically finds all devices on the same Wi-Fi network. Just open the app and they appear.',
  ),
  _OnboardingPage(
    icon: Icons.lock_outlined,
    iconColor: AppTheme.success,
    iconBg: Color(0x2200C48C),
    title: 'Fast, Private\n& Offline',
    subtitle:
        'Transfers happen directly between devices over TCP — no internet required, no data ever leaves your network.',
  ),
];

// ─── Screen ──────────────────────────────────────────────────────────────────

class OnboardingScreen extends StatefulWidget {
  final DeviceInfo selfDevice;
  const OnboardingScreen({super.key, required this.selfDevice});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final PageController _pageCtrl = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentPage < _pages.length - 1) {
      _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _finish();
    }
  }

  void _finish() {
    context.read<SettingsService>().markOnboardingSeen();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => HomeScreen(selfDevice: widget.selfDevice),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 450),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    final bg = isDark ? AppTheme.background : AppTheme.lightBackground;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            // ── Skip button ─────────────────────────────────────────────
            Align(
              alignment: Alignment.topRight,
              child: AnimatedOpacity(
                opacity: _currentPage < _pages.length - 1 ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 8, 0),
                  child: TextButton(
                    onPressed:
                        _currentPage < _pages.length - 1 ? _finish : null,
                    child: Text(
                      'Skip',
                      style: TextStyle(
                        color: AppTheme.secondaryOf(context),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Pages ───────────────────────────────────────────────────
            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                onPageChanged: (i) => setState(() => _currentPage = i),
                itemCount: _pages.length,
                itemBuilder: (_, i) =>
                    _OnboardingPageView(page: _pages[i], isActive: i == _currentPage),
              ),
            ),

            // ── Dots + button ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
              child: Column(
                children: [
                  // Dot indicators
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      _pages.length,
                      (i) => _Dot(active: i == _currentPage),
                    ),
                  ),
                  const SizedBox(height: 36),

                  // Next / Get Started button
                  _NextButton(
                    label: _currentPage == _pages.length - 1
                        ? 'Get Started'
                        : 'Next',
                    isLast: _currentPage == _pages.length - 1,
                    onTap: _next,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Single onboarding page ───────────────────────────────────────────────────

class _OnboardingPageView extends StatelessWidget {
  final _OnboardingPage page;
  final bool isActive;
  const _OnboardingPageView({required this.page, required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Illustration orb
          _IllustrationOrb(page: page),
          const SizedBox(height: 52),

          // Title
          Text(
            page.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 16),

          // Subtitle
          Text(
            page.subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.secondaryOf(context),
              fontSize: 14,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Illustration orb ─────────────────────────────────────────────────────────

class _IllustrationOrb extends StatefulWidget {
  final _OnboardingPage page;
  const _IllustrationOrb({required this.page});

  @override
  State<_IllustrationOrb> createState() => _IllustrationOrbState();
}

class _IllustrationOrbState extends State<_IllustrationOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) {
        final glowSize = 120.0 + _pulse.value * 20;
        return Stack(
          alignment: Alignment.center,
          children: [
            // Animated glow
            Container(
              width: glowSize,
              height: glowSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.page.iconBg,
              ),
            ),
            // Solid icon container
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.isDark(context)
                    ? AppTheme.surface
                    : AppTheme.lightSurface,
                border: Border.all(
                  color: widget.page.iconColor.withValues(alpha: 0.3),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.page.iconColor.withValues(alpha: 0.15),
                    blurRadius: 24,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: Icon(
                widget.page.icon,
                color: widget.page.iconColor,
                size: 44,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Dot indicator ────────────────────────────────────────────────────────────

class _Dot extends StatelessWidget {
  final bool active;
  const _Dot({required this.active});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      width: active ? 22 : 7,
      height: 7,
      decoration: BoxDecoration(
        color: active
            ? AppTheme.accentPrimary
            : AppTheme.accentPrimary.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

// ─── Next / Get Started button ────────────────────────────────────────────────

class _NextButton extends StatelessWidget {
  final String label;
  final bool isLast;
  final VoidCallback onTap;
  const _NextButton(
      {required this.label, required this.isLast, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        width: double.infinity,
        height: 52,
        decoration: BoxDecoration(
          gradient: isLast
              ? const LinearGradient(
                  colors: [AppTheme.accentPrimary, AppTheme.accentSecondary],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                )
              : null,
          color: isLast ? null : AppTheme.accentPrimary,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: AppTheme.accentPrimary.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
                letterSpacing: 0.3,
              ),
            ),
            if (!isLast) ...[
              const SizedBox(width: 6),
              const Icon(Icons.arrow_forward_rounded,
                  color: Colors.white, size: 18),
            ],
          ],
        ),
      ),
    );
  }
}
