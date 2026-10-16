import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/config.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/anchor_line.dart';
import '../../widgets/background.dart';
import '../../widgets/fields.dart';
import '../../widgets/glass.dart';
import '../../widgets/pressable.dart';
import '../../widgets/ui.dart';

final _recordProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int>(
  (ref, months) async =>
      Map<String, dynamic>.from(await ref.watch(apiProvider).get('/history', query: {'months': months})),
  retry: (_, _) => null,
);

final _reportsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref.watch(apiProvider).get('/history/reports') as List;
  return [for (final r in rows) Map<String, dynamic>.from(r)];
}, retry: (_, _) => null);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _plain(String? s) => (s ?? '').replaceAll(RegExp(r'\s*\(.*\)$'), '');

(String, Color, Color) _status(String s) => switch (s) {
  'ON_TIME' => ('On time', AppColors.success, AppColors.successBg),
  'LATE' => ('Late', AppColors.warning, AppColors.warningBg),
  'MISSED' => ('Missed', AppColors.danger, AppColors.dangerBg),
  _ => ('Paid', AppColors.muted, Colors.white),
};

/// The student's on-time payment record, and a verifiable report to give a landlord, bank or university.
/// A payment record for people without local credit history, not a credit score.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});
  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  int _months = 6;
  bool _issuing = false, _sharing = false, _showAll = false;
  Map<String, dynamic>? _issued; // the report issued in this visit

  Future<void> _issue() async {
    setState(() => _issuing = true);
    try {
      final rep = Map<String, dynamic>.from(await ref.read(apiProvider).post('/history/reports', {'months': _months}));
      HapticFeedback.mediumImpact();
      ref.invalidate(_reportsProvider);
      setState(() => _issued = rep);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _issuing = false);
    }
  }

  Future<void> _sharePdf(Map<String, dynamic> rep) async {
    setState(() => _sharing = true);
    try {
      final path = (rep['pdf_path'] as String).replaceFirst('/api', '');
      final bytes = await ref.read(apiProvider).bytes(path);
      final name = '${rep['reference']}.pdf';
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(Uint8List.fromList(bytes), mimeType: 'application/pdf', name: name)],
          fileNameOverrides: [name],
          subject: 'Payment history report ${rep['reference']}',
        ),
      );
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_recordProvider(_months));
    final latest = _issued ?? ref.watch(_reportsProvider).value?.firstOrNull;
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final r = async.value;
    final empty = r != null && (r['summary']['payments_due'] as int) == 0 && (r['items'] as List).isEmpty;

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
                    Row(
                      children: [
                        for (final m in const [3, 6, 12]) ...[
                          ChoiceChip2(
                            label: '$m months',
                            selected: _months == m,
                            onTap: () {
                              HapticFeedback.selectionClick();
                              setState(() => _months = m);
                            },
                          ),
                          const SizedBox(width: 6),
                        ],
                      ],
                    ).enter(0),
                    const SizedBox(height: 12),
                    AnimatedSwitcher(
                      duration: AppMotion.base,
                      switchInCurve: AppMotion.smooth,
                      child: async.when(
                        loading: () => const Column(
                          key: ValueKey('l'),
                          children: [
                            Skeleton(height: 170, radius: 28),
                            SizedBox(height: 12),
                            Skeleton(height: 120, radius: 24),
                          ],
                        ),
                        error: (e, _) => Glass(
                          key: const ValueKey('e'),
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            '$e',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.muted),
                          ),
                        ),
                        data: (r) => empty
                            ? const _Empty(key: ValueKey('empty'))
                            : Column(
                                key: ValueKey('d$_months'),
                                children: [
                                  if (latest != null) ...[
                                    _ReportCard(
                                      rep: latest,
                                      sharing: _sharing,
                                      onShare: () => _sharePdf(latest),
                                    ).enter(0),
                                    const SizedBox(height: 12),
                                  ],
                                  _Hero(r: r).enter(1),
                                  const SizedBox(height: 12),
                                  _Timeline(r: r).enter(2),
                                  const SizedBox(height: 12),
                                  _ByType(r: r).enter(3),
                                  const SizedBox(height: 12),
                                  _Payments(
                                    r: r,
                                    showAll: _showAll,
                                    onToggle: () => setState(() => _showAll = !_showAll),
                                  ).enter(4),
                                  const SizedBox(height: 12),
                                  _About(rules: r['rules'] as String? ?? '').enter(5),
                                ],
                              ),
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
                    onTap: () => context.canPop() ? context.pop() : context.go('/profile'),
                  ),
                  const Expanded(
                    child: Text(
                      'Payment history',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            if (r != null && !empty)
              Positioned(
                left: 16,
                right: 16,
                bottom: bottom + 20,
                child: PrimaryButton(
                  label: _issued == null ? 'Issue verifiable report' : 'Issue a new report',
                  icon: LucideIcons.fileCheck,
                  loading: _issuing,
                  onTap: _issue,
                ).animate().fadeIn(delay: 250.ms).slideY(begin: .4, delay: 250.ms, curve: AppMotion.smooth),
              ),
          ],
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.r});
  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final s = r['summary'] as Map;
    final rate = (s['on_time_rate'] as num?)?.toDouble();
    final due = s['payments_due'] as int;
    final streak = s['current_streak'] as int;
    String d(String iso) {
      final x = DateTime.parse(iso);
      return '${x.day} ${_months[x.month - 1]}';
    }

    return Glass(
      level: GlassLevel.heavy,
      radius: 28,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Paid on time', style: TextStyle(fontSize: 13, color: AppColors.muted)),
              ),
              Text(
                '${d(r['period_start'])} – ${d(r['period_end'])}',
                style: const TextStyle(fontSize: 11, color: AppColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: rate ?? 0),
                duration: const Duration(milliseconds: 1100),
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => Text(
                  rate == null ? '—' : '${v.round()}%',
                  style: const TextStyle(
                    fontSize: 44,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -1.6,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  '${s['on_time']} of $due payments',
                  style: const TextStyle(fontSize: 14, color: Color(0xFF3A3A3A)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child:
                SizedBox(
                  height: 8,
                  child: Row(
                    children: [
                      for (final (n, color) in [
                        (s['on_time'] as int, AppColors.success),
                        (s['late'] as int, AppColors.warning),
                        (s['missed'] as int, AppColors.danger),
                      ])
                        if (n > 0)
                          Expanded(
                            flex: n,
                            child: Container(color: color),
                          ),
                      if (due == 0) Expanded(child: Container(color: Colors.black.withValues(alpha: .08))),
                    ],
                  ),
                ).animate().scaleX(
                  begin: 0,
                  alignment: Alignment.centerLeft,
                  delay: 200.ms,
                  duration: 900.ms,
                  curve: AppMotion.smooth,
                ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (streak > 0) Badge2('$streak on time in a row', tone: Tone.success),
              if ((s['late'] as int) > 0) Badge2('${s['late']} late', tone: Tone.warning),
              if ((s['missed'] as int) > 0) Badge2('${s['missed']} missed', tone: Tone.danger),
              Badge2('${s['months_with_payments']} months of payments'),
            ],
          ),
        ],
      ),
    );
  }
}

/// One column per month, one dot per payment that was due: the pattern a landlord looks for.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.r});
  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final start = DateTime.parse(r['period_start'] as String);
    final months = r['months'] as int;
    final cols = [for (var i = 0; i < months; i++) DateTime(start.year, start.month + i)];
    final byMonth = <String, List<String>>{};
    for (final it in r['items'] as List) {
      final due = it['due_date'] as String?;
      if (due == null) continue;
      byMonth.putIfAbsent(due.substring(0, 7), () => []).add(it['status'] as String);
    }
    return Glass(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Month by month', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (i, m) in cols.indexed)
                Expanded(
                  child: Column(
                    children: [
                      for (final (j, st)
                          in (byMonth['${m.year}-${m.month.toString().padLeft(2, '0')}'] ?? const []).indexed)
                        Container(
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(color: _status(st).$2, shape: BoxShape.circle),
                        ).animate().scaleXY(
                          begin: 0,
                          delay: (150 + i * 60 + j * 40).ms,
                          duration: 350.ms,
                          curve: AppMotion.spring,
                        ),
                      const SizedBox(height: 2),
                      Text(
                        months > 6 ? _months[m.month - 1][0] : _months[m.month - 1],
                        style: const TextStyle(fontSize: 10.5, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final (label, color) in [
                ('On time', AppColors.success),
                ('Late', AppColors.warning),
                ('Missed', AppColors.danger),
              ]) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 4),
                Text(label, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                const SizedBox(width: 12),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ByType extends StatelessWidget {
  const _ByType({required this.r});
  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final cats = (r['categories'] as List).cast<Map>();
    final icons = {
      'Rent': LucideIcons.house,
      'Family support': LucideIcons.heartHandshake,
      'Tuition': LucideIcons.graduationCap,
    };
    return Glass(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        children: [
          for (final (i, c) in cats.indexed)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: i == cats.length - 1
                    ? null
                    : Border(bottom: BorderSide(color: Colors.black.withValues(alpha: .06))),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .9), shape: BoxShape.circle),
                    child: Icon(icons[c['name']] ?? LucideIcons.repeat, size: 16),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(c['name'] as String, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  ),
                  Text(
                    '${c['on_time']} of ${c['due']} on time',
                    style: TextStyle(
                      fontSize: 13,
                      color: c['on_time'] == c['due'] ? AppColors.success : AppColors.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Payments extends StatelessWidget {
  const _Payments({required this.r, required this.showAll, required this.onToggle});
  final Map<String, dynamic> r;
  final bool showAll;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final items = (r['items'] as List).cast<Map>();
    final shown = showAll ? items : items.take(4).toList();
    return Glass(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Payments', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          AnimatedSize(
            duration: AppMotion.base,
            curve: AppMotion.smooth,
            alignment: Alignment.topCenter,
            child: Column(
              children: [
                for (final it in shown)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _plain(it['payee'] as String?),
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                              Text(
                                '${it['category']} · ${shortDate((it['paid_date'] ?? it['due_date']) as String?)}',
                                style: const TextStyle(fontSize: 11, color: AppColors.muted),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              money(it['amount'] as num, it['currency'] as String),
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            () {
                              final (label, fg, bg) = _status(it['status'] as String);
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: bg,
                                  borderRadius: BorderRadius.circular(AppRadius.pill),
                                ),
                                child: Text(
                                  label,
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg),
                                ),
                              );
                            }(),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (items.length > 4)
            Center(
              child: TextButton(
                onPressed: onToggle,
                child: Text(
                  showAll ? 'Show fewer' : 'Show all ${items.length} payments',
                  style: const TextStyle(color: AppColors.ink, fontSize: 13),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The issued report: reference, verification code and QR code, ready to share.
class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.rep, required this.sharing, required this.onShare});
  final Map<String, dynamic> rep;
  final bool sharing;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final link = '$publicBase${rep['verify_url']}';
    return Glass(
      level: GlassLevel.heavy,
      radius: 26,
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: QrImageView(data: link, size: 88, padding: const EdgeInsets.all(6)),
              ).animate().fadeIn(duration: AppMotion.base).scaleXY(begin: .85, curve: AppMotion.spring),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Badge2('Verifiable report', tone: Tone.ink),
                    const SizedBox(height: 6),
                    Text(rep['reference'] as String, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    Text(
                      'Code ${rep['verification_code']}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.muted,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'A landlord or bank can scan it to check it is genuine.',
                      style: TextStyle(fontSize: 11, color: AppColors.muted, height: 1.35),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (rep['anchor'] != null) ...[
            const SizedBox(height: 10),
            AnchorLine(anchor: Map<String, dynamic>.from(rep['anchor'] as Map)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: PrimaryButton(
                  label: 'Share PDF',
                  icon: LucideIcons.fileDown,
                  height: 46,
                  loading: sharing,
                  onTap: onShare,
                ),
              ),
              const SizedBox(width: 8),
              Pressable(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: link));
                  HapticFeedback.selectionClick();
                  toast(context, 'Verification link copied');
                },
                child: Container(
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .85),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: const Text('Copy link', style: TextStyle(fontSize: 14)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _About extends StatelessWidget {
  const _About({required this.rules});
  final String rules;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(LucideIcons.info, size: 15, color: AppColors.muted),
            SizedBox(width: 6),
            Text(
              'What this is',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.muted),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'New in a country, you have no local credit history. This is a record of the payments you made through '
          'MoneyMate, which a landlord, bank or university can verify. It is not a credit score. $rules',
          style: const TextStyle(fontSize: 12, color: AppColors.muted, height: 1.45),
        ),
      ],
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 50),
    child: Column(
      children: [
        const Glass(
          radius: 34,
          child: SizedBox(width: 68, height: 68, child: Icon(LucideIcons.calendarCheck, size: 26)),
        ),
        const SizedBox(height: 14),
        const Text('No payment record yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'Pay rent and family support through MoneyMate, and each on-time payment builds a record you '
            'can share with a landlord or bank.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.muted, height: 1.45),
          ),
        ),
        const SizedBox(height: 16),
        GlassButton(
          label: 'Set up rent or family support',
          icon: LucideIcons.repeat,
          onTap: () => context.push('/standing'),
        ),
      ],
    ),
  ).animate().fadeIn(duration: AppMotion.base);
}
