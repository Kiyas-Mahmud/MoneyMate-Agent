import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/pressable.dart';
import '../../widgets/ui.dart';
import 'home_data.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // Payments can be prepared while the app is in the background (the daily monitor, another screen),
  // so Home reloads whenever the student comes back to it.
  late final _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(homeProvider));

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final home = ref.watch(homeProvider);
    final user = ref.watch(sessionProvider).user ?? const {};
    final top = MediaQuery.paddingOf(context).top;

    return RefreshIndicator(
      color: AppColors.ink,
      backgroundColor: Colors.white,
      edgeOffset: top,
      onRefresh: () => ref.refresh(homeProvider.future),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: EdgeInsets.fromLTRB(16, top + 12, 16, 130),
        children: [
          _Header(name: user['full_name'] as String? ?? '', unread: home.value?.unread ?? 0).enter(0),
          const SizedBox(height: 14),
          AnimatedSwitcher(
            duration: AppMotion.base,
            reverseDuration: AppMotion.fast,
            switchInCurve: AppMotion.smooth,
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
            child: home.when(
              data: (d) => _Content(key: const ValueKey('data'), data: d),
              loading: () => const _Loading(key: ValueKey('loading')),
              error: (e, _) =>
                  _Failed(key: const ValueKey('error'), message: '$e', onRetry: () => ref.invalidate(homeProvider)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.name, required this.unread});
  final String name;
  final int unread;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Glass(
        radius: 22,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Text(
              name.isEmpty ? '' : name[0].toUpperCase(),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(greeting(), style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.2),
            ),
          ],
        ),
      ),
      CircleGlassButton(
        icon: LucideIcons.bell,
        tooltip: 'Notifications',
        dot: unread > 0,
        onTap: () => context.push('/notifications'),
      ),
    ],
  );
}

class _Content extends StatelessWidget {
  const _Content({super.key, required this.data});
  final HomeData data;

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      _BalanceCard(data: data),
      if (data.tuition != null) _TuitionCard(t: data.tuition!),
      if (data.pending.isNotEmpty) _PendingPill(pending: data.pending),
      _RecentCard(data: data),
    ];
    return Column(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          cards[i].enter(i + 1, baseMs: 80),
        ],
      ],
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.data});
  final HomeData data;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => context.push('/wallet'),
    scale: 0.98,
    child: Glass(
      level: GlassLevel.heavy,
      radius: 28,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Total balance', style: TextStyle(fontSize: 13, color: AppColors.muted)),
              const Spacer(),
              GestureDetector(
                onTap: () => context.push('/rates'),
                child: Text(
                  '${data.liveRates ? 'Live rates' : 'Saved rates'} · ${data.ratesAsOf}  ›',
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // The total counts up from zero the first time it appears, then glides between values.
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: data.totalUsd),
            duration: const Duration(milliseconds: 1100),
            curve: Curves.easeOutCubic,
            builder: (_, v, _) => Text(
              money(v, 'USD'),
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w600,
                letterSpacing: -1.1,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final (i, b) in data.balances.take(3).indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: _CurrencyTile(code: b['currency'], balance: (b['balance'] as num).toDouble())
                      .animate()
                      .fadeIn(delay: (250 + i * 70).ms, duration: AppMotion.base)
                      .scaleXY(begin: .9, delay: (250 + i * 70).ms, duration: AppMotion.base, curve: AppMotion.spring),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );
}

class _CurrencyTile extends StatelessWidget {
  const _CurrencyTile({required this.code, required this.balance});
  final String code;
  final double balance;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .7), borderRadius: BorderRadius.circular(18)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(code, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(money(balance, code), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
}

class _TuitionCard extends StatelessWidget {
  const _TuitionCard({required this.t});
  final Map<String, dynamic> t;

  @override
  Widget build(BuildContext context) {
    final days = t['days_left'] as int;
    final currency = t['currency'] as String;
    final shortfall = (t['shortfall'] as num).toDouble();
    final convert = t['convert_suggestion'] as Map<String, dynamic>?;
    final university = (t['university'] as String? ?? '').replaceAll(RegExp(r'\s*\(.*\)$'), '');
    final title = days < 0
        ? 'Tuition overdue'
        : days == 0
        ? 'Tuition due today'
        : 'Tuition due in $days day${days == 1 ? '' : 's'}';

    return Pressable(
      onTap: () => context.push('/tuition'),
      scale: 0.98,
      child: Glass(
        radius: 28,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(14)),
                  child: const Icon(LucideIcons.calendar, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                          shortfall > 0
                              ? Badge2(
                                  'Short ${money(shortfall, currency)}',
                                  tone: days <= 3 ? Tone.danger : Tone.warning,
                                )
                              : const Badge2('Covered', tone: Tone.success),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$university · ${money(t['amount'] as num, currency)} · ${shortDate(t['due_date'])}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _SmallButton(
                    label: 'Pay with agent',
                    dark: true,
                    onTap: () => context.go(
                      Uri(
                        path: '/agent',
                        queryParameters: {
                          'prompt': 'Pay my ${t['semester']} tuition',
                          'at': '${DateTime.now().millisecondsSinceEpoch}',
                        },
                      ).toString(),
                    ),
                  ),
                ),
              ],
            ),
            if (shortfall > 0 || convert != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (shortfall > 0)
                    Expanded(
                      child: _SmallButton(
                        label: 'Ask family',
                        onTap: () => context.push(
                          Uri(
                            path: '/request',
                            queryParameters: {'amount': '${shortfall.ceil()}', 'reason': '${t['semester']} tuition'},
                          ).toString(),
                        ),
                      ),
                    ),
                  if (shortfall > 0 && convert != null) const SizedBox(width: 8),
                  if (convert != null)
                    Expanded(
                      child: _SmallButton(
                        label: 'Convert ${money(convert['amount'] as num, convert['from_currency'] as String)}',
                        onTap: () => context.push(
                          Uri(
                            path: '/wallet',
                            queryParameters: {
                              'from': convert['from_currency'],
                              'to': convert['to_currency'],
                              'receive': '${convert['receives']}',
                            },
                          ).toString(),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({required this.label, required this.onTap, this.dark = false});
  final String label;
  final VoidCallback onTap;
  final bool dark;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    haptic: dark,
    child: Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dark ? AppColors.ink : Colors.white.withValues(alpha: .8),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: dark ? Colors.white : AppColors.ink),
      ),
    ),
  );
}

/// "1 payment waiting for your verification": nothing moves until the student verifies it.
class _PendingPill extends StatelessWidget {
  const _PendingPill({required this.pending});
  final List<Map<String, dynamic>> pending;

  @override
  Widget build(BuildContext context) {
    final n = pending.length;
    return Pressable(
      onTap: () => context.push('/verify/${pending.first['id']}'),
      haptic: true,
      child: Glass(
        radius: AppRadius.pill,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // A soft ring keeps pulsing out of the dot so the request is hard to miss.
                  Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(color: Color(0xFFC98A00), shape: BoxShape.circle),
                      )
                      .animate(onPlay: (c) => c.repeat())
                      .scaleXY(end: 2.2, duration: 1400.ms, curve: Curves.easeOut)
                      .fadeOut(duration: 1400.ms, curve: Curves.easeOut),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(color: Color(0xFFC98A00), shape: BoxShape.circle),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$n payment${n == 1 ? '' : 's'} waiting for your verification',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const Icon(LucideIcons.chevronRight, size: 18),
          ],
        ),
      ),
    );
  }
}

class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.data});
  final HomeData data;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 28,
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text('Recent', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              GestureDetector(
                onTap: () => context.go('/activity'),
                child: const Text('See all', style: TextStyle(fontSize: 12, color: AppColors.muted)),
              ),
            ],
          ),
        ),
        if (data.recent.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text('No payments yet', style: TextStyle(fontSize: 13, color: AppColors.muted)),
          ),
        for (final (i, tx) in data.recent.indexed)
          _TxRow(tx: tx, subtitle: data.describe(tx), last: i == data.recent.length - 1)
              .animate()
              .fadeIn(delay: (420 + i * 70).ms, duration: AppMotion.base)
              .slideX(begin: .04, delay: (420 + i * 70).ms, duration: AppMotion.base, curve: AppMotion.smooth),
      ],
    ),
  );
}

class _TxRow extends StatelessWidget {
  const _TxRow({required this.tx, required this.subtitle, required this.last});
  final Map<String, dynamic> tx;
  final String subtitle;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final incoming = tx['direction'] == 'IN';
    final amount = (tx['amount'] as num).toDouble();
    return Pressable(
      onTap: () => context.push('/receipt/${tx['id']}'),
      scale: 0.98,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: Colors.black.withValues(alpha: .06))),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: .85), shape: BoxShape.circle),
              child: Icon(incoming ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (tx['counterparty'] as String? ?? '').replaceAll(RegExp(r'\s*\(.*\)$'), ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              money(incoming ? amount : -amount, tx['currency'] as String, signed: incoming),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: incoming ? AppColors.success : AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shimmer placeholders shaped like the real cards, so nothing jumps when data arrives.
class _Loading extends StatelessWidget {
  const _Loading({super.key});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Glass(
        level: GlassLevel.heavy,
        radius: 28,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Skeleton(width: 90, height: 12),
            const SizedBox(height: 12),
            const Skeleton(width: 150, height: 34),
            const SizedBox(height: 16),
            Row(
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  const Expanded(child: Skeleton(height: 52, radius: 18)),
                ],
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      const Glass(
        radius: 28,
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Skeleton(width: 40, height: 40, radius: 14),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Skeleton(width: 160, height: 14), SizedBox(height: 8), Skeleton(width: 210, height: 11)],
                  ),
                ),
              ],
            ),
            SizedBox(height: 14),
            Skeleton(height: 44, radius: 22),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Glass(
        radius: 28,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (var i = 0; i < 3; i++)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Skeleton(width: 36, height: 36, radius: 18),
                    SizedBox(width: 12),
                    Expanded(child: Skeleton(height: 12)),
                    SizedBox(width: 40),
                    Skeleton(width: 60, height: 12),
                  ],
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

class _Failed extends StatelessWidget {
  const _Failed({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 28,
    padding: const EdgeInsets.all(20),
    child: Column(
      children: [
        const Icon(LucideIcons.wifiOff, size: 28),
        const SizedBox(height: 10),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: AppColors.muted),
        ),
        const SizedBox(height: 14),
        GlassButton(label: 'Try again', icon: LucideIcons.refreshCw, onTap: onRetry),
      ],
    ),
  ).animate().fadeIn(duration: AppMotion.base).shakeX(hz: 3, amount: 4, duration: 400.ms);
}
