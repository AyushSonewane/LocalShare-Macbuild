import 'dart:ui';
import 'package:flutter/material.dart';

/// Minimal, Windows 11 Fluent-style drag-and-drop overlay.
///
/// Adapts automatically to dark and light themes:
/// - Dark mode : black dim backdrop, white text
/// - Light mode: white/gray dim backdrop, dark text
class DragDropOverlay extends StatelessWidget {
  /// Whether the drag is actively hovering over the window.
  final bool isHovering;

  /// Number of files being dragged (0 = unknown).
  final int fileCount;

  /// First file name, shown when only one file is dragged.
  final String? firstFileName;

  const DragDropOverlay({
    super.key,
    required this.isHovering,
    this.fileCount = 0,
    this.firstFileName,
  });

  // Windows Fluent accent blue — works well on both backgrounds
  static const _accent = Color(0xFF0078D4);
  static const _accentFill = Color(0x1A0078D4); // ~10% fill on hover

  // ── Helpers ───────────────────────────────────────────────────────────────
  String get _label => isHovering ? 'Release to send' : 'Drop files to send';

  String get _sublabel {
    if (fileCount == 1 && firstFileName != null) {
      final n = firstFileName!;
      return n.length > 32 ? '${n.substring(0, 30)}…' : n;
    }
    if (fileCount > 1) return '$fileCount files';
    return 'Folders supported';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // ── Theme-dependent tokens ─────────────────────────────────────────────
    final backdropColor = isDark
        ? Colors.black.withValues(alpha: isHovering ? 0.52 : 0.44)
        : Colors.white.withValues(alpha: isHovering ? 0.68 : 0.60);

    final borderColor = isHovering
        ? _accent
        : (isDark
            ? Colors.white.withValues(alpha: 0.30)
            : Colors.black.withValues(alpha: 0.18));

    final cardBg = isHovering
        ? _accentFill
        : (isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.80));

    final labelColor = isHovering
        ? _accent
        : (isDark
            ? Colors.white.withValues(alpha: 0.90)
            : Colors.black.withValues(alpha: 0.80));

    final sublabelColor = isDark
        ? Colors.white.withValues(alpha: 0.42)
        : Colors.black.withValues(alpha: 0.42);

    final iconColor = isHovering
        ? _accent
        : (isDark
            ? Colors.white.withValues(alpha: 0.72)
            : Colors.black.withValues(alpha: 0.55));

    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Soft blurred backdrop ──────────────────────────────────────
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
            child: ColoredBox(color: backdropColor),
          ),

          // ── Drop zone card ─────────────────────────────────────────────
          Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              width: 280,
              padding:
                  const EdgeInsets.symmetric(vertical: 40, horizontal: 32),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor, width: 1.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Upload icon ──────────────────────────────────────
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.upload_file_outlined,
                      key: ValueKey(iconColor.value),
                      size: 36,
                      color: iconColor,
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Primary label ────────────────────────────────────
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: Text(
                      _label,
                      key: ValueKey(_label),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: labelColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),

                  const SizedBox(height: 6),

                  // ── Sub-label ────────────────────────────────────────
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: Text(
                      _sublabel,
                      key: ValueKey(_sublabel),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: sublabelColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
