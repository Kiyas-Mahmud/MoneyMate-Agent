import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme.dart';
import '../../widgets/pressable.dart';
import '../../widgets/sheet.dart';
import '../../widgets/ui.dart';
import '../agent/agent_chat.dart';

/// The Pay tab: what the student can do with money, in one tap each.
class PayMenu extends ConsumerWidget {
  const PayMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tuition = ref.watch(agentOpenerProvider).value;
    final days = tuition?['days_left'] as int?;
    final tiles = <(IconData, String, String, String)>[
      (
        LucideIcons.graduationCap,
        'Pay tuition',
        days == null
            ? 'Nothing due'
            : days < 0
            ? 'Overdue'
            : days == 0
            ? 'Due today'
            : 'Due in $days days',
        '/tuition',
      ),
      (LucideIcons.send, 'Send money', 'Cheapest route', '/send'),
      (LucideIcons.arrowLeftRight, 'Convert', 'Live rates', '/wallet'),
      (LucideIcons.shieldCheck, 'Scam check', 'Paste a message', '/scam'),
      (LucideIcons.handHeart, 'Ask family', 'Money from home', '/request'),
      (LucideIcons.chartLine, 'Exchange rates', 'Market rate', '/rates'),
    ];

    // Replace the sheet with the chosen screen, so Back returns to where the student was.
    void open(String path) => context.pushReplacement(path);

    return GlassSheet(
      title: 'What do you need?',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.25,
            children: [
              for (final (i, (icon, title, sub, path)) in tiles.indexed)
                Pressable(
                      onTap: () => open(path),
                      haptic: true,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .88),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(14)),
                              child: Icon(icon, color: Colors.white, size: 20),
                            ),
                            const Spacer(),
                            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text(sub, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                          ],
                        ),
                      ),
                    )
                    .animate()
                    .fadeIn(delay: (80 + i * 60).ms, duration: AppMotion.base)
                    .scaleXY(begin: .9, delay: (80 + i * 60).ms, duration: AppMotion.base, curve: AppMotion.spring),
            ],
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            label: 'Or just ask the agent',
            icon: LucideIcons.sparkles,
            onTap: () {
              context.pop();
              context.go('/agent');
            },
          ).animate().fadeIn(delay: 340.ms, duration: AppMotion.base),
        ],
      ),
    );
  }
}
