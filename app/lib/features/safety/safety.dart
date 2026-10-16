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
import '../../widgets/ui.dart';

/// What the safety screen explains: a stranger's money that arrived, and (if it happened) the blocked
/// attempt to pass it on.
class _Case {
  _Case({this.blocked, this.incoming, required this.mule});
  final Map<String, dynamic>? blocked; // the transfer MoneyMate refused
  final Map<String, dynamic>? incoming; // money from a first-time sender
  final bool mule;
}

typedef _Ref = ({int? tx, int? action});

final _caseProvider = FutureProvider.autoDispose.family<_Case, _Ref>((ref, r) async {
  final api = ref.watch(apiProvider);
  var txId = r.tx;
  if (txId == null && r.action != null) {
    txId = (await api.get('/agent/actions/${r.action}'))['transaction_id'] as int?;
  }
  final txs = [
    for (final t in await api.get('/transactions', query: {'limit': 200}) as List) Map<String, dynamic>.from(t),
  ];
  final target = txs.where((t) => t['id'] == txId).firstOrNull;
  if (target == null) throw ApiError('This payment is no longer in your history.');

  // Money from someone who has never paid the student before (the mule pattern starts here).
  final incomingAll = txs.where((t) => t['direction'] == 'IN' && t['status'] == 'COMPLETED').toList();
  bool firstTime(Map<String, dynamic> t) =>
      incomingAll.where((o) => o['counterparty'] == t['counterparty']).length == 1;

  if (target['direction'] == 'IN') return _Case(incoming: target, mule: firstTime(target));

  final before = DateTime.parse(target['created_at'] as String);
  final incoming = incomingAll
      .where((t) => firstTime(t) && !DateTime.parse(t['created_at'] as String).isAfter(before))
      .firstOrNull; // newest first
  final reasons = (target['risk_reasons'] as List? ?? const []).join(' ').toLowerCase();
  return _Case(blocked: target, incoming: incoming, mule: reasons.contains('mule') || incoming != null);
}, retry: (_, _) => null);

String _time(String iso) {
  final d = parseUtc(iso);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String _plain(String? s) => (s ?? '').replaceAll(RegExp(r'\s*\(.*\)$'), '');

/// "We stopped this transfer" (blocked) or "Be careful with this money" (a stranger's money just arrived).
class SafetyScreen extends ConsumerWidget {
  const SafetyScreen({super.key, this.txId, this.actionId});
  final int? txId, actionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_caseProvider((tx: txId, action: actionId)));
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    ref.listen(_caseProvider((tx: txId, action: actionId)), (_, next) {
      if (next.value?.blocked != null) HapticFeedback.heavyImpact();
    });
    final c = async.value;

    void getHelp() => context.go(
      Uri(
        path: '/agent',
        queryParameters: {
          'prompt': 'I received money from a stranger. Help me return it safely.',
          'at': '${DateTime.now().millisecondsSinceEpoch}',
        },
      ).toString(),
    );

    return Scaffold(
      body: DriftBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: TopFade(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(16, top + 64, 16, bottom + 150),
                  children: [
                    async.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.only(top: 120),
                        child: Center(child: CircularProgressIndicator(color: AppColors.ink, strokeWidth: 2)),
                      ),
                      error: (e, _) => Glass(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          '$e',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.muted),
                        ),
                      ),
                      data: (c) => _Body(c: c),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: top + 8,
              left: 16,
              child: CircleGlassButton(
                icon: LucideIcons.chevronLeft,
                tooltip: 'Back',
                onTap: () => context.canPop() ? context.pop() : context.go('/home'),
              ),
            ),
            if (c != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: bottom + 20,
                child: Column(
                  children: [
                    if (c.mule)
                      PrimaryButton(label: 'Get help returning the money', icon: LucideIcons.lifeBuoy, onTap: getHelp)
                    else
                      PrimaryButton(
                        label: 'Ask the agent why',
                        icon: LucideIcons.sparkles,
                        onTap: () => context.go('/agent'),
                      ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: GlassButton(label: 'Back to home', onTap: () => context.go('/home')),
                    ),
                  ],
                ).animate().fadeIn(delay: 600.ms).slideY(begin: .3, delay: 600.ms, curve: AppMotion.smooth),
              ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.c});
  final _Case c;

  @override
  Widget build(BuildContext context) {
    final blocked = c.blocked;
    final incoming = c.incoming;
    final danger = blocked != null;
    final (title, sub) = danger
        ? c.mule
              ? ('We stopped this transfer', 'It looks like a money-mule job. Your money is still in your wallet.')
              : ('We stopped this payment', 'It looked too risky to send. Nothing left your wallet.')
        : (
            'Be careful with this money',
            'Someone you have never dealt with sent it. If anyone asks you to pass it on, don\'t.',
          );

    final reasons = [for (final r in blocked?['risk_reasons'] as List? ?? const []) r.toString()];
    final level = blocked?['risk_level'] as String?;
    final score = (blocked?['risk_score'] as num?)?.toDouble();

    return Column(
      children: [
        // The badge pulses a soft halo a few times so the warning registers.
        SizedBox(
          width: 120,
          height: 120,
          child: Stack(
            alignment: Alignment.center,
            children: [
              for (final d in [0, 500, 1000])
                Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: (danger ? AppColors.danger : AppColors.warning).withValues(alpha: .25),
                      ),
                    )
                    .animate(onPlay: (ctl) => ctl.repeat(count: 2))
                    .scaleXY(begin: 1, end: 1.7, delay: d.ms, duration: 1500.ms, curve: Curves.easeOut)
                    .fadeOut(delay: d.ms, duration: 1500.ms),
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(color: danger ? AppColors.danger : AppColors.warning, shape: BoxShape.circle),
                child: Icon(danger ? LucideIcons.shieldX : LucideIcons.shieldAlert, color: Colors.white, size: 32),
              ).animate().scaleXY(begin: .4, duration: 600.ms, curve: Curves.elasticOut).fadeIn(duration: 200.ms),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: -0.5),
        ).enter(1),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            sub,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Color(0xFF4A4A4A), height: 1.5),
          ),
        ).enter(2),
        const SizedBox(height: 22),
        Glass(
          level: GlassLevel.heavy,
          radius: 28,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('What happened', style: TextStyle(fontSize: 12, color: AppColors.muted)),
              const SizedBox(height: 10),
              if (incoming != null)
                _Step(
                  icon: LucideIcons.arrowDownLeft,
                  bg: AppColors.successBg,
                  fg: AppColors.success,
                  title:
                      '+${money(incoming['amount'] as num, incoming['currency'] as String)} from ${_plain(incoming['counterparty'])}',
                  sub: 'First time this sender paid you · ${_time(incoming['created_at'] as String)}',
                ),
              if (incoming != null && blocked != null)
                Container(
                  width: 2,
                  height: 18,
                  margin: const EdgeInsets.fromLTRB(16, 4, 0, 4),
                  color: Colors.black.withValues(alpha: .15),
                ).animate().scaleY(begin: 0, alignment: Alignment.topCenter, delay: 400.ms, duration: 300.ms),
              if (blocked != null)
                _Step(
                  icon: LucideIcons.ban,
                  bg: AppColors.dangerBg,
                  fg: AppColors.danger,
                  title:
                      '−${money(blocked['amount'] as num, blocked['currency'] as String)} to ${_plain(blocked['counterparty'])}',
                  sub: [
                    if (incoming != null)
                      () {
                        final mins = DateTime.parse(blocked['created_at'] as String)
                            .difference(DateTime.parse(incoming['created_at'] as String))
                            .inMinutes;
                        return mins < 60
                            ? '$mins minute${mins == 1 ? '' : 's'} later'
                            : _time(blocked['created_at'] as String);
                      }()
                    else
                      _time(blocked['created_at'] as String),
                    'blocked',
                  ].join(' · '),
                ).animate().fadeIn(delay: 500.ms).slideX(begin: .05, delay: 500.ms),
              if (score != null && level != null) ...[
                Container(
                  height: 1,
                  color: Colors.black.withValues(alpha: .07),
                  margin: const EdgeInsets.symmetric(vertical: 14),
                ),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Fraud risk', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                    ),
                    Text(
                      '${level[0]}${level.substring(1).toLowerCase()} · ${(score * 100).round()}%',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: level == 'HIGH'
                            ? AppColors.danger
                            : level == 'MEDIUM'
                            ? AppColors.warning
                            : AppColors.success,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                RiskBar(score: score, level: level),
              ],
              if (!c.mule && reasons.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final r in reasons)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('• $r', style: const TextStyle(fontSize: 12, height: 1.4)),
                  ),
              ],
              if (c.mule) ...[
                const SizedBox(height: 12),
                Text(
                  danger
                      ? 'Forwarding money from a stranger can make you part of money laundering. Students who do this can lose '
                            'their bank account and their visa.'
                      : 'Scammers send money to students, then ask them to forward it or send it "back" to another account. '
                            'That is money laundering. MoneyMate will block any transfer that passes it on.',
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF3A3A3A), height: 1.5),
                ),
              ],
            ],
          ),
        ).enter(3),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.bg, required this.fg, required this.title, required this.sub});
  final IconData icon;
  final Color bg, fg;
  final String title, sub;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Icon(icon, size: 16, color: fg),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            Text(sub, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
          ],
        ),
      ),
    ],
  );
}
