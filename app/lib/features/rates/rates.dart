import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../widgets/background.dart';
import '../../widgets/glass.dart';
import '../../widgets/ui.dart';

final ratesProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) async => Map<String, dynamic>.from(await ref.watch(apiProvider).get('/fx/rates')),
  retry: (_, _) => null,
);

// The pairs a student from Bangladesh studying in China reads most, each the way round that reads naturally.
const _pairs = [('CNY', 'BDT'), ('USD', 'BDT'), ('USD', 'CNY')];

// "Mon, 19 Oct 2026 00:02:32 +0000" -> "19 Oct 2026"
String _date(String? s) => RegExp(r'\d{1,2} [A-Z][a-z]{2} \d{4}').firstMatch(s ?? '')?.group(0) ?? (s ?? '');

/// Live mid-market exchange rates, and what each provider charges on top.
class RatesScreen extends ConsumerWidget {
  const RatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(ratesProvider);
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      body: DriftBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: TopFade(
                child: async.when(
                  loading: () => const Center(child: CircularProgressIndicator(color: AppColors.ink, strokeWidth: 2)),
                  error: (e, _) => Center(
                    child: Text('$e', style: const TextStyle(color: AppColors.muted)),
                  ),
                  data: (r) {
                    final pairs = [for (final p in r['pairs'] as List) Map<String, dynamic>.from(p)];
                    Map<String, dynamic> pair(String a, String b) =>
                        pairs.firstWhere((p) => p['from'] == a && p['to'] == b);
                    final providers = [for (final p in r['providers'] as List) Map<String, dynamic>.from(p)];
                    final live = r['live'] == true;
                    return RefreshIndicator(
                      color: AppColors.ink,
                      onRefresh: () async => ref.invalidate(ratesProvider),
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                        padding: EdgeInsets.fromLTRB(16, top + 68, 16, bottom + 40),
                        children: [
                          Glass(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        'Market rate',
                                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    Badge2(live ? 'Live' : 'Saved', tone: live ? Tone.success : Tone.neutral),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Mid-market · ${_date(r['as_of'] as String?)}',
                                  style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
                                ),
                                const SizedBox(height: 12),
                                for (final (i, (a, b)) in _pairs.indexed) ...[
                                  if (i > 0) const Divider(height: 22, color: AppColors.line),
                                  _RateRow(p: pair(a, b)),
                                ],
                              ],
                            ),
                          ).animate().fadeIn(duration: AppMotion.base).slideY(begin: .06, curve: AppMotion.smooth),
                          const SizedBox(height: 14),
                          const Padding(
                            padding: EdgeInsets.only(left: 4, bottom: 8),
                            child: Text(
                              'What providers charge',
                              style: TextStyle(fontSize: 12, color: AppColors.muted),
                            ),
                          ),
                          Glass(
                            level: GlassLevel.light,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                            child: Column(
                              children: [
                                for (final (i, p) in providers.indexed) ...[
                                  if (i > 0) const Divider(height: 1, color: AppColors.line),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                p['name'] as String,
                                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                                              ),
                                              Text(
                                                p['eta'] as String,
                                                style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              '${p['fx_margin_pct']}% above market',
                                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                            ),
                                            Text(
                                              (p['fee_usd'] as num) == 0
                                                  ? 'No fee'
                                                  : '\$${(p['fee_usd'] as num).toStringAsFixed(2)} fee',
                                              style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ).animate().fadeIn(delay: 120.ms, duration: AppMotion.base),
                          const SizedBox(height: 14),
                          GlassButton(
                            label: 'Convert between my wallets',
                            icon: LucideIcons.arrowLeftRight,
                            onTap: () => context.push('/wallet'),
                          ),
                          const SizedBox(height: 10),
                          GlassButton(
                            label: 'Ask family for money',
                            icon: LucideIcons.handHeart,
                            onTap: () => context.push('/request'),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'Market rates from ExchangeRate-API. Provider prices are sandbox examples.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 10.5, color: AppColors.hint),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: top + 8,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  CircleGlassButton(
                    icon: LucideIcons.chevronLeft,
                    tooltip: 'Back',
                    onTap: () => context.canPop() ? context.pop() : context.go('/home'),
                  ),
                  const Expanded(
                    child: Text(
                      'Exchange rates',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RateRow extends StatelessWidget {
  const _RateRow({required this.p});
  final Map<String, dynamic> p;

  @override
  Widget build(BuildContext context) {
    final mid = (p['mid_rate'] as num).toDouble();
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '1 ${p['from']} = ${mid.toStringAsFixed(2)} ${p['to']}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -.3),
              ),
              const SizedBox(height: 2),
              Text(
                'Best for \$100: ${p['best_provider']} · ${(p['best_total_cost_pct'] as num).toStringAsFixed(1)}% cost',
                style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
              ),
            ],
          ),
        ),
        Text(
          '${p['from']} → ${p['to']}',
          style: const TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
