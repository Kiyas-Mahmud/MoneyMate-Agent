import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// MoneyMate's mark: four pills that "breathe" while the agent is working.
class Orb extends StatefulWidget {
  const Orb({super.key, this.height = 18, this.color = AppColors.ink, this.animate = true});
  final double height;
  final Color color;
  final bool animate;

  @override
  State<Orb> createState() => _OrbState();
}

class _OrbState extends State<Orb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  static const _heights = [0.68, 1.0, 0.86, 0.62];

  @override
  void initState() {
    super.initState();
    if (widget.animate && !WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    final w = h * 0.32;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 4; i++)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : w * 0.35),
              child: Container(
                width: w,
                height: h * _heights[i] * (0.8 + 0.2 * math.sin((_c.value * 2 * math.pi) - i * 0.9)),
                decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(w)),
              ),
            ),
        ],
      ),
    );
  }
}

/// The orb inside a round glass avatar, used next to agent messages.
class OrbAvatar extends StatelessWidget {
  const OrbAvatar({super.key, this.size = 32});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .7),
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white),
    ),
    alignment: Alignment.center,
    child: Orb(height: size * 0.36),
  );
}
