import 'package:flutter/material.dart';

/// Smooth fade + horizontal slide page transition.
/// Use [AppRoutes.push] instead of [Navigator.push] to get it automatically.
class FadeSlideRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  FadeSlideRoute({required this.page})
      : super(
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 240),
          pageBuilder: (_, __, ___) => page,
          transitionsBuilder: (_, animation, secondaryAnimation, child) {
            // Incoming page slides in from the right
            final slide = Tween<Offset>(
              begin: const Offset(0.08, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ));
            // Outgoing page slides slightly left (depth effect)
            final slideOut = Tween<Offset>(
              begin: Offset.zero,
              end: const Offset(-0.04, 0),
            ).animate(CurvedAnimation(
              parent: secondaryAnimation,
              curve: Curves.easeInCubic,
            ));
            final fade = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            );

            return FadeTransition(
              opacity: fade,
              child: SlideTransition(
                position: slideOut,
                child: SlideTransition(position: slide, child: child),
              ),
            );
          },
        );
}

/// Convenience wrapper — replaces [Navigator.push] for smooth transitions.
class AppRoutes {
  static Future<T?> push<T>(BuildContext context, Widget page) {
    return Navigator.of(context).push<T>(FadeSlideRoute(page: page));
  }
}
