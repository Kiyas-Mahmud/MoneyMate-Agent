import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/background.dart';
import '../../widgets/glass.dart';
import '../../widgets/ui.dart';

final _sentProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int>(
  (ref, id) async => Map<String, dynamic>.from(await ref.watch(apiProvider).get('/transactions/$id/receipt')),
  retry: (_, _) => null,
);

/// Shown after the student verifies a transfer: what was sent, by which route, and how it was approved.
class SentScreen extends ConsumerWidget {
  const SentScreen({super.key, required this.txId});
  final int txId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_sentProvider(txId));
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      body: DriftBackground(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator(color: AppColors.ink, strokeWidth: 2)),
          error: (e, _) => Center(
            child: Text('$e', style: const TextStyle(color: AppColors.muted)),
          ),
          data: (r) {
            final name = (r['counterparty'] as String? ?? '').replaceAll(RegExp(r'\s*\(.*\)$'), '');
            final first = name.split(' ').first;
            // memo: "Recipient gets 36,165.92 BDT"
            final m = RegExp(r'gets ([\d,.]+) ([A-Z]{3})').firstMatch(r['memo'] as String? ?? '');
            final gets = m == null ? null : money(double.parse(m.group(1)!.replaceAll(',', '')), m.group(2)!);
            final rows = <(String, Widget)>[
              if (r['provider'] != null) ('Route', Text(r['provider'] as String, style: const TextStyle(fontSize: 13))),
              if ((r['fee'] as num? ?? 0) > 0)
                (
                  'Fee',
                  Text(
                    money(r['fee'] as num, r['currency'] as String, decimals: true),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ('Reference', Text(r['reference'] as String, style: const TextStyle(fontSize: 13))),
              ('Approval', const Badge2('Verified with fingerprint', tone: Tone.success)),
            ];

            return Stack(
              children: [
                ListView(
                  padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 90, 16, bottom + 100),
                  children: [
                    Center(
                      child:
                          Container(
                                width: 84,
                                height: 84,
                                decoration: const BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
                                child: const Icon(LucideIcons.check, color: Colors.white, size: 40).animate().scaleXY(
                                  begin: 0,
                                  delay: 250.ms,
                                  duration: 500.ms,
                                  curve: Curves.elasticOut,
                                ),
                              )
                              .animate()
                              .scaleXY(begin: .5, duration: 550.ms, curve: Curves.elasticOut)
                              .fadeIn(duration: 200.ms),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Sent to $name',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: AppColors.muted),
                    ).enter(1),
                    const SizedBox(height: 4),
                    Text(
                      money(r['amount'] as num, r['currency'] as String),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w600, letterSpacing: -1.6),
                    ).enter(2),
                    if (gets != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '$first receives $gets',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14, color: Color(0xFF3A3A3A)),
                      ).enter(3),
                    ],
                    const SizedBox(height: 32),
                    Glass(
                      level: GlassLevel.heavy,
                      radius: 26,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Column(
                        children: [
                          for (final (label, value) in rows)
                            Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                border: Border(bottom: BorderSide(color: Colors.black.withValues(alpha: .06))),
                              ),
                              child: Row(
                                children: [
                                  Text(label, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
                                  const Spacer(),
                                  value,
                                ],
                              ),
                            ),
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              'Your agent compared every route and prepared this one. It was sent only after you verified it on your phone.',
                              style: TextStyle(fontSize: 12, color: AppColors.muted, height: 1.5),
                            ),
                          ),
                        ],
                      ),
                    ).enter(4),
                  ],
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: bottom + 20,
                  child: Row(
                    children: [
                      Expanded(
                        child: PrimaryButton(
                          label: 'View receipt',
                          onTap: () => context.pushReplacement('/receipt/$txId'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      GlassButton(label: 'Done', height: 54, onTap: () => context.go('/home')),
                    ],
                  ).animate().fadeIn(delay: 450.ms).slideY(begin: .4, delay: 450.ms, curve: AppMotion.smooth),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
