import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shimmer/shimmer.dart';

import '../core/theme.dart';
import 'glass.dart';
import 'pressable.dart';

/// Black pill: the one main action on a screen.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, this.onTap, this.icon, this.loading = false, this.height = 54});
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool loading;
  final double height;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: loading ? null : onTap,
    haptic: true,
    child: Container(
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(AppRadius.pill)),
      child: AnimatedSwitcher(
        duration: AppMotion.fast,
        child: loading
            ? const SizedBox(
                key: ValueKey('l'),
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
              )
            : Row(
                key: const ValueKey('t'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[Icon(icon, color: Colors.white, size: 19), const SizedBox(width: 8)],
                  Text(
                    label,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
      ),
    ),
  );
}

/// Glass pill: secondary action.
class GlassButton extends StatelessWidget {
  const GlassButton({super.key, required this.label, this.onTap, this.icon, this.height = 50});
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final double height;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    child: Glass(
      radius: AppRadius.pill,
      child: SizedBox(
        height: height,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Text(label, style: const TextStyle(fontSize: 15)),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Round 44 px glass icon button (back, bell, share).
class CircleGlassButton extends StatelessWidget {
  const CircleGlassButton({super.key, required this.icon, this.onTap, this.tooltip, this.dot = false});
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool dot;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: tooltip,
    child: Pressable(
      onTap: onTap,
      scale: 0.9,
      child: Glass(
        radius: 22,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, size: 20),
              if (dot)
                Positioned(
                  top: 11,
                  right: 12,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

enum Tone { neutral, success, warning, danger, ink }

/// Small rounded label, e.g. "Low risk · 2%", "Needs you", "Blocked", "Verified".
class Badge2 extends StatelessWidget {
  const Badge2(this.text, {super.key, this.tone = Tone.neutral});
  final String text;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      Tone.success => (AppColors.successBg, AppColors.success),
      Tone.warning => (AppColors.warningBg, AppColors.warning),
      Tone.danger => (AppColors.dangerBg, AppColors.danger),
      Tone.ink => (AppColors.ink, Colors.white),
      Tone.neutral => (Colors.white.withValues(alpha: .85), AppColors.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(AppRadius.pill)),
      child: Text(
        text,
        style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Thin animated risk bar.
class RiskBar extends StatelessWidget {
  const RiskBar({super.key, required this.score, required this.level});
  final double score;
  final String level;

  @override
  Widget build(BuildContext context) {
    final color = level == 'HIGH'
        ? AppColors.danger
        : level == 'MEDIUM'
        ? AppColors.warning
        : AppColors.success;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 4,
        child: Stack(
          children: [
            Container(color: Colors.black.withValues(alpha: .08)),
            FractionallySizedBox(
              widthFactor: score.clamp(0.04, 1.0),
              child: Container(color: color),
            ).animate().scaleX(begin: 0, alignment: Alignment.centerLeft, duration: 900.ms, curve: AppMotion.smooth),
          ],
        ),
      ),
    );
  }
}

/// Shimmer skeleton block for loading states.
class Skeleton extends StatelessWidget {
  const Skeleton({super.key, this.height = 16, this.width, this.radius = 12});
  final double height;
  final double? width;
  final double radius;
  @override
  Widget build(BuildContext context) => Shimmer.fromColors(
    baseColor: const Color(0xFFE6E6E6),
    highlightColor: const Color(0xFFF7F7F7),
    child: Container(
      height: height,
      width: width,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(radius)),
    ),
  );
}

/// Standard staggered entrance for screen content: fade + slide up.
extension Entrance on Widget {
  Widget enter(int index, {int baseMs = 60}) => animate()
      .fadeIn(duration: AppMotion.base, delay: (index * baseMs).ms, curve: AppMotion.smooth)
      .slideY(begin: 0.12, end: 0, duration: AppMotion.base, delay: (index * baseMs).ms, curve: AppMotion.smooth);
}

/// Shows a short message at the bottom (errors, confirmations).
void toast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? AppColors.danger : AppColors.ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 100),
    ),
  );
}

/// Fades scrolling content out as it slides under a floating header, instead of clashing with it.
class TopFade extends StatelessWidget {
  const TopFade({super.key, required this.child, this.from = 40, this.to = 84, this.belowStatusBar = true});
  final Widget child;
  final double from, to; // fade band
  final bool belowStatusBar; // measure the band from below the status bar, or from this widget's own top edge

  @override
  Widget build(BuildContext context) {
    final top = belowStatusBar ? MediaQuery.paddingOf(context).top : 0.0;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (r) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [Colors.transparent, Colors.black],
        stops: [(top + from) / r.height, (top + to) / r.height],
      ).createShader(r),
      child: child,
    );
  }
}
