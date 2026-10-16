import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../core/theme.dart';

/// Soft grey shapes drifting slowly behind the glass, so the blur has something to refract.
/// Radial gradients instead of blur filters keep it cheap on Android.
class DriftBackground extends StatelessWidget {
  const DriftBackground({super.key, required this.child, this.tint});

  final Widget child;
  final Color? tint; // e.g. a faint red behind a "blocked" screen

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.canvas,
      child: Stack(
        children: [
          _blob(const Color(0xFFC9C9C9), 320, top: 40, left: -110, dx: 40, dy: 50, ms: 9000),
          _blob(tint ?? const Color(0xFF9E9E9E), 300, top: 380, right: -130, dx: -50, dy: -40, ms: 11000, opacity: .55),
          _blob(const Color(0xFFDADADA), 220, bottom: 40, left: 10, dx: 30, dy: -30, ms: 10000),
          Positioned.fill(child: child),
        ],
      ),
    );
  }

  Widget _blob(
    Color color,
    double size, {
    double? top,
    double? left,
    double? right,
    double? bottom,
    required double dx,
    required double dy,
    required int ms,
    double opacity = 1,
  }) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      child: IgnorePointer(
        child:
            Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        color.withValues(alpha: opacity),
                        color.withValues(alpha: 0),
                      ],
                    ),
                  ),
                )
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .move(begin: Offset.zero, end: Offset(dx, dy), duration: ms.ms, curve: Curves.easeInOut),
      ),
    );
  }
}
