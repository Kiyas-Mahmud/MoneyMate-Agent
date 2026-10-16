import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/background.dart';
import '../../widgets/glass.dart';
import '../../widgets/orb.dart';
import '../../widgets/ui.dart';

final _checkProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, text) async => Map<String, dynamic>.from(await ref.watch(apiProvider).post('/scam-check', {'text': text})),
  retry: (_, _) => null,
);

/// Runs the scam check on a message and explains the verdict.
class ScamResultScreen extends ConsumerWidget {
  const ScamResultScreen({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_checkProvider(text));
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    ref.listen(_checkProvider(text), (_, next) {
      if (next.value?['verdict'] == 'LIKELY_SCAM') HapticFeedback.heavyImpact();
    });
    final r = async.value;
    final tuitionRelated =
        r != null &&
        ((r['payee_verification'] as Map?)?['status'] == 'IMPERSONATION' ||
            RegExp(r'tuition|semester|bursar', caseSensitive: false).hasMatch(text));

    return Scaffold(
      body: DriftBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: TopFade(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(16, top + 68, 16, bottom + 100),
                  children: [
                    _Quote(text: text).enter(0),
                    const SizedBox(height: 12),
                    AnimatedSwitcher(
                      duration: AppMotion.slow,
                      switchInCurve: AppMotion.smooth,
                      child: async.when(
                        loading: () => const _Checking(key: ValueKey('checking')),
                        error: (e, _) => Glass(
                          key: const ValueKey('error'),
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              Text(
                                '$e',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: AppColors.muted),
                              ),
                              const SizedBox(height: 12),
                              GlassButton(label: 'Try again', onTap: () => ref.invalidate(_checkProvider(text))),
                            ],
                          ),
                        ),
                        data: (r) => _Verdict(key: const ValueKey('verdict'), r: r),
                      ),
                    ),
                  ],
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
                    onTap: () => context.canPop() ? context.pop() : context.go('/scam'),
                  ),
                  const Expanded(
                    child: Text(
                      'Scam check',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            if (r != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: bottom + 20,
                child: Row(
                  children: [
                    Expanded(
                      child: tuitionRelated
                          ? PrimaryButton(
                              label: 'Pay the official way',
                              onTap: () => context.pushReplacement('/tuition'),
                            )
                          : PrimaryButton(label: 'Done', onTap: () => context.go('/home')),
                    ),
                    const SizedBox(width: 10),
                    GlassButton(
                      label: 'Check another',
                      height: 54,
                      onTap: () => context.canPop() ? context.pop() : context.go('/scam'),
                    ),
                  ],
                ).animate().fadeIn(delay: 500.ms).slideY(begin: .4, delay: 500.ms, curve: AppMotion.smooth),
              ),
          ],
        ),
      ),
    );
  }
}

class _Quote extends StatefulWidget {
  const _Quote({required this.text});
  final String text;
  @override
  State<_Quote> createState() => _QuoteState();
}

class _QuoteState extends State<_Quote> {
  bool _open = false;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => _open = !_open),
    child: Glass(
      radius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(LucideIcons.quote, size: 16, color: AppColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: AnimatedSize(
              duration: AppMotion.base,
              curve: AppMotion.smooth,
              alignment: Alignment.topCenter,
              child: Text(
                '"${widget.text}"',
                maxLines: _open ? null : 3,
                overflow: _open ? null : TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF3A3A3A), height: 1.5),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// While the backend works: the steps it really performs, ticking in one after another.
class _Checking extends StatelessWidget {
  const _Checking({super.key});

  @override
  Widget build(BuildContext context) {
    const steps = [
      'Looking for pressure, threats and discounts',
      'Checking the account against the university registry',
      'Asking the AI for a second opinion',
    ];
    return Glass(
      level: GlassLevel.heavy,
      radius: 28,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Orb(height: 22),
              SizedBox(width: 12),
              Text('Checking the message…', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 16),
          for (final (i, s) in steps.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 1.6, color: AppColors.muted),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(s, style: const TextStyle(fontSize: 13, color: Color(0xFF3A3A3A))),
                  ),
                ],
              ),
            ).animate().fadeIn(delay: (i * 450).ms, duration: AppMotion.base).slideX(begin: .05, delay: (i * 450).ms),
        ],
      ),
    );
  }
}

class _Verdict extends StatelessWidget {
  const _Verdict({super.key, required this.r});
  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final verdict = r['verdict'] as String;
    final (color, bg, icon, title, sub) = switch (verdict) {
      'LIKELY_SCAM' => (
        AppColors.danger,
        AppColors.dangerBg,
        LucideIcons.shieldX,
        'Likely a scam',
        'Do not pay this request',
      ),
      'CAUTION' => (
        AppColors.warning,
        AppColors.warningBg,
        LucideIcons.shieldAlert,
        'Be careful',
        'Check it with the sender another way first',
      ),
      _ => (
        AppColors.success,
        AppColors.successBg,
        LucideIcons.shieldCheck,
        'No red flags found',
        'Still check the payee before you pay',
      ),
    };
    final pv = Map<String, dynamic>.from(r['payee_verification'] as Map? ?? {});
    final ex = Map<String, dynamic>.from(r['extracted'] as Map? ?? {});
    final flags = <String>[
      if (pv['status'] == 'IMPERSONATION') pv['message'] as String? ?? 'Not the official account',
      for (final f in r['red_flags'] as List? ?? const [])
        if (f['code'] != 'ACCOUNT_MISMATCH') f['explanation'] as String,
      if (pv['status'] == 'UNKNOWN' && ex['account'] != null)
        'Account ${ex['account']} is not a verified university account',
    ];
    final op = r['second_opinion'] as Map?;
    final escalated = r['escalated_by_second_opinion'] == true;

    return Column(
      children: [
        Glass(
          level: GlassLevel.heavy,
          radius: 28,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    child: Icon(icon, color: Colors.white, size: 20),
                  ).animate().scaleXY(begin: .4, duration: 550.ms, curve: Curves.elasticOut).fadeIn(duration: 200.ms),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                        Text(sub, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                      ],
                    ),
                  ),
                  if (flags.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(AppRadius.pill)),
                      child: Text(
                        '${flags.length} red flag${flags.length == 1 ? '' : 's'}',
                        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
                      ),
                    ),
                ],
              ),
              if (flags.isNotEmpty) const SizedBox(height: 14),
              for (final (i, f) in flags.indexed)
                Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.only(top: 6, right: 10),
                            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                          ),
                          Expanded(child: Text(f, style: const TextStyle(fontSize: 13, height: 1.4))),
                        ],
                      ),
                    )
                    .animate()
                    .fadeIn(delay: (200 + i * 90).ms, duration: AppMotion.base)
                    .slideX(begin: .05, delay: (200 + i * 90).ms, curve: AppMotion.smooth),
              if (ex['amount'] != null) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .7),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const Text('Amount mentioned', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                      const Spacer(),
                      Text(
                        money(ex['amount'] as num, ex['currency'] as String? ?? 'USD'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          decoration: verdict == 'LIKELY_SCAM' ? TextDecoration.lineThrough : null,
                          decorationColor: AppColors.danger.withValues(alpha: .6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Glass(
              radius: 24,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(LucideIcons.sparkles, size: 16),
                      const SizedBox(width: 8),
                      const Text('AI second opinion', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text(
                        op?['available'] == true ? 'Gemini' : 'Off',
                        style: const TextStyle(fontSize: 11, color: AppColors.muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (op?['available'] == true) ...[
                    Text(
                      op!['explanation'] as String? ?? '',
                      style: const TextStyle(fontSize: 13, color: Color(0xFF3A3A3A), height: 1.5),
                    ),
                    if (op['advice'] != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Next step: ${op['advice']}',
                        style: const TextStyle(fontSize: 12, color: AppColors.muted, height: 1.45),
                      ),
                    ],
                    if (escalated) ...[
                      const SizedBox(height: 8),
                      const Badge2('Raised the warning level', tone: Tone.warning),
                    ],
                  ] else
                    const Text(
                      'Not connected right now. This verdict comes from MoneyMate\'s built-in checks; the AI can only ever '
                      'raise a warning, never lower it.',
                      style: TextStyle(fontSize: 12, color: AppColors.muted, height: 1.45),
                    ),
                ],
              ),
            )
            .animate()
            .fadeIn(delay: 350.ms, duration: AppMotion.base)
            .slideY(begin: .1, delay: 350.ms, curve: AppMotion.smooth),
      ],
    );
  }
}
