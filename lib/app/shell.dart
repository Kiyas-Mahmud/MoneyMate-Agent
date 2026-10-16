import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../widgets/background.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';

class _Tab {
  const _Tab(this.path, this.icon, this.label);
  final String path;
  final IconData icon;
  final String label;
}

const _tabs = [
  _Tab('/home', LucideIcons.house, 'Home'),
  _Tab('/agent', LucideIcons.sparkles, 'AI agent'),
  _Tab('/pay', LucideIcons.circlePlus, 'Pay'),
  _Tab('/activity', LucideIcons.receipt, 'Activity'),
  _Tab('/profile', LucideIcons.user, 'Profile'),
];

/// App frame: drifting background, the current tab, and the floating liquid-glass tab bar.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final index = _tabs.indexWhere((t) => location.startsWith(t.path)).clamp(0, _tabs.length - 1);
    // The tab bar steps aside while typing so the keyboard and the input field get the room.
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      body: DriftBackground(
        child: Stack(
          children: [
            Positioned.fill(child: child),
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: SafeArea(
                top: false,
                child: IgnorePointer(
                  ignoring: typing,
                  child: AnimatedSlide(
                    offset: typing ? const Offset(0, 1.6) : Offset.zero,
                    duration: AppMotion.fast,
                    curve: AppMotion.smooth,
                    child: AnimatedOpacity(
                      opacity: typing ? 0 : 1,
                      duration: AppMotion.fast,
                      child: _TabBar(index: index),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.index});
  final int index;

  @override
  Widget build(BuildContext context) {
    return Glass(
      level: GlassLevel.heavy,
      radius: AppRadius.pill,
      padding: const EdgeInsets.all(6),
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth / _tabs.length;
          return SizedBox(
            height: 48,
            child: Stack(
              children: [
                // The bright pill slides to the selected tab with a soft spring.
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 520),
                  curve: Curves.easeOutBack,
                  left: index * w + 4,
                  width: w - 8,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .95),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .08),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < _tabs.length; i++)
                      Expanded(
                        child: Semantics(
                          button: true,
                          selected: i == index,
                          label: _tabs[i].label,
                          child: Pressable(
                            scale: 0.88,
                            onTap: () => i == 2 ? context.push('/pay') : context.go(_tabs[i].path),
                            child: SizedBox(
                              height: 48,
                              child: Center(
                                child: AnimatedScale(
                                  scale: i == index ? 1.08 : 1,
                                  duration: const Duration(milliseconds: 300),
                                  child: Icon(
                                    _tabs[i].icon,
                                    size: 22,
                                    color: i == index ? AppColors.ink : const Color(0xFF6B6B6B),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
