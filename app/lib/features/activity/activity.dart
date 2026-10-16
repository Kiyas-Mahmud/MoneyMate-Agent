import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/pressable.dart';
import '../../widgets/ui.dart';

class _ActivityData {
  _ActivityData(this.txs, this.logIntact, this.logEntries, this.waiting, this.relationships);
  final List<Map<String, dynamic>> txs;
  final bool logIntact;
  final int logEntries;
  final Map<int, int> waiting; // transaction id -> action id still waiting for verification
  final Map<String, String> relationships;
}

List<Map<String, dynamic>> _maps(dynamic l) => [for (final e in l as List) Map<String, dynamic>.from(e)];

final activityProvider = FutureProvider.autoDispose<_ActivityData>((ref) async {
  final api = ref.watch(apiProvider);
  final r = await Future.wait([
    api.get('/transactions', query: {'limit': 100}),
    api.get('/audit/verify'),
    api.get('/agent/actions', query: {'status': 'AWAITING_VERIFICATION'}),
    api.get('/payees'),
  ]);
  final audit = Map<String, dynamic>.from(r[1]);
  return _ActivityData(
    _maps(r[0]),
    audit['valid'] == true,
    audit['entries'] as int? ?? 0,
    {
      for (final a in _maps(r[2]))
        if (a['transaction_id'] != null) a['transaction_id'] as int: a['id'] as int,
    },
    {
      for (final p in _maps((r[3] as Map)['recipients']))
        if (p['relationship'] != null) p['name'] as String: p['relationship'] as String,
    },
  );
}, retry: (_, _) => null);

enum _Filter { all, tuition, transfers, blocked }

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _plain(String? s) => (s ?? '').replaceAll(RegExp(r'\s*\(.*\)$'), '');

/// Every payment, transfer and conversion, newest first, with what happened to it.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});
  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  _Filter _filter = _Filter.all;
  late final _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(activityProvider));

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

  bool _matches(Map<String, dynamic> t) => switch (_filter) {
    _Filter.all => true,
    _Filter.tuition => t['kind'] == 'TUITION',
    _Filter.transfers => (t['kind'] as String).startsWith('REMITTANCE'),
    _Filter.blocked => t['status'] == 'BLOCKED',
  };

  /// "Today", "Yesterday", "Mon 12 Oct" (this week) or "9 Oct".
  String _day(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${d.day} ${_months[d.month - 1]}${d.year != now.year ? ' ${d.year}' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(activityProvider);
    final top = MediaQuery.paddingOf(context).top;
    final data = async.value;

    final children = <Widget>[];
    if (data != null) {
      final rows = data.txs.where(_matches).toList();
      if (rows.isEmpty) {
        children.add(_Empty(filter: _filter).enter(0));
      } else {
        // One glass card per day, so a long history stays easy to scan.
        final groups = <String, List<Map<String, dynamic>>>{};
        for (final t in rows) {
          groups.putIfAbsent(_day(parseUtc(t['created_at'] as String)), () => []).add(t);
        }
        var i = 0;
        for (final MapEntry(key: day, value: txs) in groups.entries) {
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
              child: Text(
                day,
                style: const TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w500),
              ),
            ).enter(i),
          );
          children.add(
            Glass(
              radius: 26,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Column(
                children: [
                  for (final (j, t) in txs.indexed)
                    _Row(
                      tx: t,
                      last: j == txs.length - 1,
                      relationships: data.relationships,
                      waitingAction: data.waiting[t['id']],
                    ),
                ],
              ),
            ).enter(i + 1),
          );
          children.add(const SizedBox(height: 10));
          i += 2;
        }
      }
    }

    final Widget list = async.isLoading && data == null
        ? Column(
            children: [
              for (var i = 0; i < 6; i++)
                const Padding(padding: EdgeInsets.only(bottom: 10), child: Skeleton(height: 58, radius: 20)),
            ],
          )
        : async.hasError && data == null
        ? Glass(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text(
                  '${async.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted),
                ),
                const SizedBox(height: 12),
                GlassButton(label: 'Try again', onTap: () => ref.invalidate(activityProvider)),
              ],
            ),
          )
        // Re-key on the filter so the list cross-fades instead of jumping.
        : AnimatedSwitcher(
            duration: AppMotion.base,
            switchInCurve: AppMotion.smooth,
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
            child: Column(key: ValueKey(_filter), crossAxisAlignment: CrossAxisAlignment.start, children: children),
          );

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, top + 12, 16, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Activity',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, letterSpacing: -0.5),
                ),
              ),
              if (data != null) _LogChip(intact: data.logIntact, entries: data.logEntries),
            ],
          ).enter(0),
        ),
        _FilterBar(
          filter: _filter,
          onPick: (f) {
            HapticFeedback.selectionClick();
            setState(() => _filter = f);
          },
        ).enter(1),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.ink,
            backgroundColor: Colors.white,
            onRefresh: () => ref.refresh(activityProvider.future),
            child: TopFade(
              belowStatusBar: false,
              from: 0,
              to: 18,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 130),
                children: [list],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Filter chips under the title; the list scrolls beneath them.
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.filter, required this.onPick});
  final _Filter filter;
  final ValueChanged<_Filter> onPick;

  @override
  Widget build(BuildContext context) {
    const labels = {
      _Filter.all: 'All',
      _Filter.tuition: 'Tuition',
      _Filter.transfers: 'Transfers',
      _Filter.blocked: 'Blocked',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          for (final f in _Filter.values) ...[
            Pressable(
              onTap: () => onPick(f),
              child: AnimatedContainer(
                duration: AppMotion.base,
                curve: AppMotion.smooth,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: f == filter ? AppColors.ink : Colors.white.withValues(alpha: .75),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: Colors.white.withValues(alpha: .9)),
                ),
                child: Text(
                  labels[f]!,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: f == filter ? Colors.white : AppColors.ink,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

/// The audit log is hash-chained: any edit to past records breaks the chain and this chip turns red.
class _LogChip extends StatelessWidget {
  const _LogChip({required this.intact, required this.entries});
  final bool intact;
  final int entries;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => toast(
      context,
      intact
          ? 'Audit log intact: all $entries records check out. Any edit would break the hash chain.'
          : 'The audit log does not check out. A past record was changed.',
      error: !intact,
    ),
    child: Glass(
      radius: AppRadius.pill,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            intact ? LucideIcons.shieldCheck : LucideIcons.shieldAlert,
            size: 15,
            color: intact ? AppColors.success : AppColors.danger,
          ),
          const SizedBox(width: 6),
          Text(
            intact ? 'Log intact' : 'Log altered',
            style: TextStyle(fontSize: 12, color: intact ? AppColors.ink : AppColors.danger),
          ),
        ],
      ),
    ),
  ).animate().fadeIn(delay: 200.ms).scaleXY(begin: .85, delay: 200.ms, curve: AppMotion.spring);
}

class _Row extends StatelessWidget {
  const _Row({required this.tx, required this.last, required this.relationships, this.waitingAction});
  final Map<String, dynamic> tx;
  final bool last;
  final Map<String, String> relationships;
  final int? waitingAction;

  @override
  Widget build(BuildContext context) {
    final kind = tx['kind'] as String;
    final status = tx['status'] as String;
    final incoming = tx['direction'] == 'IN';
    final blocked = status == 'BLOCKED';
    final done = status == 'COMPLETED';
    final name = kind == 'FX' ? 'Conversion' : _plain(tx['counterparty'] as String?);
    final rel = relationships[tx['counterparty']];
    final when = parseUtc(tx['created_at'] as String);
    final time = '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
    final what = switch (kind) {
      'TUITION' => 'Tuition',
      'FX' => tx['memo'] as String? ?? 'Between your wallets',
      'CARD' => 'Card',
      'REMITTANCE_IN' => rel != null ? 'From $rel' : 'Received',
      _ =>
        rel == 'landlord'
            ? 'Rent'
            : rel != null
            ? 'To $rel'
            : 'Transfer',
    };
    // For a blocked payment, lead with the reason a student recognises (mule pattern, fake account) over model details.
    final reasons = [for (final r in tx['risk_reasons'] as List? ?? const []) r.toString()];
    final keyReason =
        reasons
            .where((r) => RegExp(r'mule|scam|official|imperson|stranger', caseSensitive: false).hasMatch(r))
            .firstOrNull ??
        reasons.firstOrNull;
    final meta = [
      if (blocked && keyReason != null) keyReason else what,
      if (tx['provider'] != null && kind != 'FX' && !blocked) tx['provider'],
      time,
    ].join(' · ');
    final (label, tone) = switch (status) {
      'COMPLETED' => (
        kind == 'TUITION' || (!incoming && kind != 'FX' && kind != 'CARD') ? 'Paid' : 'Done',
        kind == 'TUITION' || (!incoming && kind != 'FX' && kind != 'CARD') ? Tone.success : Tone.neutral,
      ),
      'BLOCKED' => ('Blocked', Tone.danger),
      'AWAITING_VERIFICATION' => ('Needs you', Tone.warning),
      'REJECTED' => ('Cancelled', Tone.neutral),
      'EXPIRED' => ('Expired', Tone.neutral),
      _ => (status[0] + status.substring(1).toLowerCase(), Tone.neutral),
    };
    final amount = (tx['amount'] as num).toDouble();
    final icon = switch (kind) {
      'TUITION' => LucideIcons.graduationCap,
      'FX' => LucideIcons.arrowLeftRight,
      'CARD' => LucideIcons.creditCard,
      _ => incoming ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight,
    };

    void open() {
      if (waitingAction != null) {
        context.push('/verify/$waitingAction');
      } else if (blocked) {
        context.push('/safety?tx=${tx['id']}');
      } else if (done) {
        context.push('/receipt/${tx['id']}');
      } else {
        context.push('/tx', extra: tx);
      }
    }

    return Pressable(
      onTap: open,
      scale: .98,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: Colors.black.withValues(alpha: .06))),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: blocked ? AppColors.dangerBg : Colors.white.withValues(alpha: .9),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 16, color: blocked ? AppColors.danger : AppColors.ink),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  money(incoming ? amount : -amount, tx['currency'] as String, signed: incoming),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: blocked
                        ? AppColors.danger
                        : incoming && done
                        ? AppColors.success
                        : done
                        ? AppColors.ink
                        : AppColors.muted,
                    decoration: blocked || status == 'REJECTED' || status == 'EXPIRED'
                        ? TextDecoration.lineThrough
                        : null,
                    decorationColor: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 3),
                _MiniBadge(label: label, tone: tone),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({required this.label, required this.tone});
  final String label;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      Tone.success => (AppColors.successBg, AppColors.success),
      Tone.warning => (AppColors.warningBg, AppColors.warning),
      Tone.danger => (AppColors.dangerBg, AppColors.danger),
      _ => (Colors.white.withValues(alpha: .9), AppColors.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(AppRadius.pill)),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: fg),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.filter});
  final _Filter filter;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = switch (filter) {
      _Filter.blocked => (
        LucideIcons.shieldCheck,
        'Nothing blocked',
        'When MoneyMate stops a risky payment, it shows up here with the reason.',
      ),
      _Filter.tuition => (
        LucideIcons.graduationCap,
        'No tuition payments yet',
        'Paid invoices appear here with their receipts.',
      ),
      _ => (LucideIcons.receipt, 'No activity yet', 'Payments, transfers and conversions appear here.'),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Column(
        children: [
          Glass(radius: 34, child: SizedBox(width: 68, height: 68, child: Icon(icon, size: 26))),
          const SizedBox(height: 14),
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}
