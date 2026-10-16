import 'dart:ui';

import 'package:flutter/material.dart';

enum GlassLevel { light, regular, heavy }

/// Liquid-glass surface: blurred backdrop + translucent white + bright hairline edge.
/// Blur costs GPU on low-end Android, so heavy glass is for bars and sheets; cards can use [GlassLevel.light].
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.level = GlassLevel.regular,
    this.radius = 26,
    this.padding,
    this.borderRadius,
  });

  final Widget child;
  final GlassLevel level;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final (sigma, opacity, shadow) = switch (level) {
      GlassLevel.light => (14.0, 0.45, 0.04),
      GlassLevel.regular => (22.0, 0.55, 0.07),
      GlassLevel.heavy => (30.0, 0.72, 0.10),
    };
    final br = borderRadius ?? BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: shadow),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: br,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: opacity),
              borderRadius: br,
              border: Border.all(color: Colors.white.withValues(alpha: 0.85)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
