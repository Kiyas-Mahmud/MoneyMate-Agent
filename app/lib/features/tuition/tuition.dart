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
import '../../widgets/pressable.dart';
import '../../widgets/ui.dart';

class _TuitionData {
  _TuitionData(this.invoices, this.reminders, this.pending);
  final List<Map<String, dynamic>> invoices;
  final List<Map<String, dynamic>> reminders; // open invoices with wallet coverage
  final List<Map<String, dynamic>> pending; // tuition payments waiting for verification

  Map<String, dynamic>? get open => reminders.isEmpty ? null : reminders.first;
  List<Map<String, dynamic>> get paid => invoices.where((i) => i['status'] == 'PAID').toList();
  Map<String, dynamic>? get openInvoice => invoices.where((i) => i['status'] == 'OPEN').firstOrNull;
}

List<Map<String, dynamic>> _maps(dynamic l) => [for (final e in l as List) Map<String, dynamic>.from(e)];

final _tuitionProvider = FutureProvider.autoDispose<_TuitionData>((ref) async {
  final api = ref.watch(apiProvider);
  final r = await Future.wait([
    api.get('/tuition/invoices'),
    api.get('/tuition/reminders'),
    api.get('/agent/actions', query: {'status': 'AWAITING_VERIFICATION'}),
  ]);
  return _TuitionData(_maps(r[0]), _maps(r[1]), _maps(r[2]).where((a) => a['tool'] == 'pay_tuition').toList());
}, retry: (_, _) => null);

String _plain(String? s) => (s ?? '').replaceAll(RegExp(r'\s*\(.*\)$'), '');

class TuitionScreen extends ConsumerStatefulWidget {
  const TuitionScreen({super.key});
  @override
  ConsumerState<TuitionScreen> createState() => _TuitionScreenState();
}

class _TuitionScreenState extends ConsumerState<TuitionScreen> {
  late final _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(_tuitionProvider));
  bool _paying = false;

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

  /// Prepares the payment (and the conversion, if short); nothing moves until the student verifies.
  Future<void> _pay() async {
    setState(() => _paying = true);
    try {
      final res = await ref.read(apiProvider).post('/tuition/pay', {});
      if (!mounted) return;
      if (res['status'] == 'AWAITING_VERIFICATION') {
        await context.push('/verify/${res['action_id']}');
      } else {
        toast(context, res['error'] as String? ?? 'This payment was blocked', error: true);
      }
      ref.invalidate(_tuitionProvider);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  void _askAgent(String prompt) => context.go(
    Uri(
      path: '/agent',
      queryParameters: {'prompt': prompt, 'at': '${DateTime.now().millisecondsSinceEpoch}'},
    ).toString(),
  );

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_tuitionProvider);
    final top = MediaQuery.paddingOf(context).top;

    return Scaffold(
      body: DriftBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: TopFade(
                child: RefreshIndicator(
                  color: AppColors.ink,
                  backgroundColor: Colors.white,
                  edgeOffset: top + 60,
                  onRefresh: () => ref.refresh(_tuitionProvider.future),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                    padding: EdgeInsets.fromLTRB(16, top + 68, 16, MediaQuery.paddingOf(context).bottom + 40),
                    children: [
                      async.when(
                        loading: () => const Column(
                          children: [
                            Skeleton(height: 250, radius: 28),
                            SizedBox(height: 12),
                            Skeleton(height: 90, radius: 24),
                          ],
                        ),
                        error: (e, _) => Glass(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              Text(
                                '$e',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 13, color: AppColors.muted),
                              ),
                              const SizedBox(height: 12),
                              GlassButton(label: 'Try again', onTap: () => ref.invalidate(_tuitionProvider)),
                            ],
                          ),
                        ),
                        data: (d) {
                          final cards = <Widget>[
                            if (d.open != null)
                              _InvoiceCard(
                                t: d.open!,
                                accountHint: d.openInvoice?['account_hint'] as String?,
                                pending: d.pending.firstOrNull,
                                paying: _paying,
                                onPay: _pay,
                                onAsk: () => _askAgent('Pay my ${d.open!['semester']} tuition'),
                              )
                            else
                              const _AllPaid(),
                            if (d.open != null) _Timeline(daysLeft: d.open!['days_left'] as int),
                            _CheckRequest(onCheck: (text) => context.push('/scam/result', extra: text)),
                            const _VerifyAccount(),
                            if (d.paid.isNotEmpty) _PaidList(invoices: d.paid),
                          ];
                          return Column(
                            children: [
                              for (final (i, c) in cards.indexed) ...[
                                if (i > 0) const SizedBox(height: 12),
                                c.enter(i, baseMs: 80),
                              ],
                            ],
                          );
                        },
                      ),
                    ],
                  ),
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
                      'Tuition',
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

class _InvoiceCard extends StatelessWidget {
  const _InvoiceCard({
    required this.t,
    required this.accountHint,
    required this.pending,
    required this.paying,
    required this.onPay,
    required this.onAsk,
  });
  final Map<String, dynamic> t;
  final String? accountHint;
  final Map<String, dynamic>? pending;
  final bool paying;
  final VoidCallback onPay, onAsk;

  @override
  Widget build(BuildContext context) {
    final days = t['days_left'] as int;
    final currency = t['currency'] as String;
    final amount = (t['amount'] as num).toDouble();
    final have = (t['wallet_balance'] as num).toDouble();
    final shortfall = (t['shortfall'] as num).toDouble();
    final convert = t['convert_suggestion'] as Map?;
    final due = DateTime.parse(t['due_date'] as String);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

    final badge = days < 0
        ? Badge2('Overdue ${-days}d', tone: Tone.danger)
        : Badge2(
            days == 0 ? 'Due today' : '$days day${days == 1 ? '' : 's'} left',
            tone: days <= 3
                ? Tone.danger
                : days <= 7
                ? Tone.warning
                : Tone.neutral,
          );

    return Glass(
      level: GlassLevel.heavy,
      radius: 28,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${t['semester']} · ${_plain(t['university'])}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: AppColors.muted),
                ),
              ),
              badge,
            ],
          ),
          const SizedBox(height: 6),
          Text(
            money(amount, currency),
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600, letterSpacing: -1),
          ),
          Text(
            'Due ${due.day} ${months[due.month - 1]} ${due.year}${accountHint != null ? ' · official account $accountHint' : ''}',
            style: const TextStyle(fontSize: 12, color: AppColors.muted),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Your $currency wallet covers',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ),
              Text(
                '${money(have.clamp(0, amount), currency)} of ${money(amount, currency)}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: SizedBox(
              height: 6,
              child: Stack(
                children: [
                  Container(color: Colors.black.withValues(alpha: .08)),
                  FractionallySizedBox(
                    widthFactor: (have / amount).clamp(0.0, 1.0),
                    child: Container(color: AppColors.ink),
                  ).animate().scaleX(
                    begin: 0,
                    alignment: Alignment.centerLeft,
                    delay: 300.ms,
                    duration: 1000.ms,
                    curve: AppMotion.smooth,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            shortfall > 0 && convert != null
                ? 'Short ${money(shortfall, currency)} · convert about ${money(convert['amount'] as num, convert['from_currency'] as String)} at today\'s rate'
                : 'Your wallet covers it',
            style: const TextStyle(fontSize: 12, color: AppColors.muted),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: pending != null
                    ? PrimaryButton(
                        label: 'Verify waiting payment',
                        icon: LucideIcons.fingerprint,
                        height: 46,
                        onTap: () => context.push('/verify/${pending!['id']}'),
                      )
                    : PrimaryButton(
                        label: shortfall > 0 ? 'Convert and pay' : 'Pay now',
                        height: 46,
                        loading: paying,
                        onTap: onPay,
                      ),
              ),
              const SizedBox(width: 8),
              GlassButton(label: 'Ask agent', height: 46, onTap: onAsk),
            ],
          ),
        ],
      ),
    );
  }
}

/// Where the reminder schedule stands: 14, 7 and 3 days before, then the due date.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.daysLeft});
  final int daysLeft;

  @override
  Widget build(BuildContext context) {
    final stops = [(14, '14 days'), (7, '7 days'), (3, '3 days'), (0, 'Due')];
    // The current stop is the nearest one the student has reached.
    final current = stops.lastIndexWhere((s) => daysLeft <= s.$1);
    return Glass(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Reminders', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final (i, s) in stops.indexed) ...[
                if (i > 0)
                  Expanded(
                    child: Container(height: 1, color: Colors.black.withValues(alpha: i <= current ? .5 : .15)),
                  ),
                _Stop(
                      label: i == current ? '${s.$2} · now' : s.$2,
                      state: i < current
                          ? 1
                          : i == current
                          ? 2
                          : 0,
                    )
                    .animate()
                    .fadeIn(delay: (200 + i * 90).ms, duration: AppMotion.base)
                    .scaleXY(begin: .8, delay: (200 + i * 90).ms, curve: AppMotion.spring),
              ],
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'MoneyMate reminds you at each step and checks your wallet covers the invoice.',
            style: TextStyle(fontSize: 11, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

class _Stop extends StatelessWidget {
  const _Stop({required this.label, required this.state});
  final String label;
  final int state; // 0 upcoming, 1 passed, 2 current

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: state == 2 ? AppColors.ink : Colors.white.withValues(alpha: .85),
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state == 1) ...[const Icon(LucideIcons.check, size: 11, color: AppColors.muted), const SizedBox(width: 3)],
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: state == 2 ? Colors.white : AppColors.muted,
            fontWeight: state == 2 ? FontWeight.w500 : FontWeight.w400,
          ),
        ),
      ],
    ),
  );
}

class _CheckRequest extends StatefulWidget {
  const _CheckRequest({required this.onCheck});
  final ValueChanged<String> onCheck;
  @override
  State<_CheckRequest> createState() => _CheckRequestState();
}

class _CheckRequestState extends State<_CheckRequest> {
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _text.text.trim().length > 10;
    return Glass(
      radius: 24,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Someone else asked you to pay?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          const Text(
            'Agents, "discounts" and personal accounts are blocked. Check the message first.',
            style: TextStyle(fontSize: 12, color: AppColors.muted, height: 1.45),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .8),
              borderRadius: BorderRadius.circular(18),
            ),
            child: TextField(
              controller: _text,
              minLines: 2,
              maxLines: 6,
              style: const TextStyle(fontSize: 13, height: 1.4),
              decoration: const InputDecoration(
                hintText: 'Paste the email, WeChat message or invoice',
                contentPadding: EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 10),
          AnimatedOpacity(
            duration: AppMotion.fast,
            opacity: ready ? 1 : .45,
            child: PrimaryButton(
              label: 'Check before paying',
              icon: LucideIcons.shieldCheck,
              height: 44,
              onTap: ready ? () => widget.onCheck(_text.text.trim()) : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Check any account number against the verified university registry before sending money to it.
class _VerifyAccount extends ConsumerStatefulWidget {
  const _VerifyAccount();
  @override
  ConsumerState<_VerifyAccount> createState() => _VerifyAccountState();
}

class _VerifyAccountState extends ConsumerState<_VerifyAccount> {
  final _account = TextEditingController();
  Map<String, dynamic>? _result;
  bool _busy = false;
  final _resultKey = GlobalKey();

  @override
  void dispose() {
    _account.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_account.text.trim().length < 4) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final r = await ref.read(apiProvider).post('/payees/verify', {'account_ref': _account.text.trim()});
      setState(() => _result = Map<String, dynamic>.from(r));
      // Bring the verdict into view; it can appear below the fold.
      Future.delayed(AppMotion.base, () {
        final ctx = _resultKey.currentContext;
        if (ctx != null && ctx.mounted) {
          final pos = Scrollable.of(ctx).position;
          pos.animateTo(pos.maxScrollExtent, duration: AppMotion.base, curve: AppMotion.smooth);
        }
      });
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final (icon, color, text) = switch (r?['status']) {
      'VERIFIED' => (
        LucideIcons.badgeCheck,
        AppColors.success,
        'Official account of ${r!['official_name']}${r['bank'] != null ? ' · ${r['bank']}' : ''}',
      ),
      'IMPERSONATION' => (
        LucideIcons.shieldAlert,
        AppColors.danger,
        r!['message'] as String? ?? 'Not the official account',
      ),
      _ => (
        LucideIcons.circleHelp,
        AppColors.warning,
        'Not a verified university account. Don\'t send tuition here unless your university confirms it.',
      ),
    };
    return Column(
      children: [
        Glass(
          radius: AppRadius.pill,
          padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
          child: Row(
            children: [
              const Icon(LucideIcons.landmark, size: 18, color: AppColors.muted),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _account,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _check(),
                  onChanged: (_) => _result == null ? null : setState(() => _result = null),
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(hintText: 'Verify an account number', isDense: true),
                ),
              ),
              Pressable(
                onTap: _busy ? null : _check,
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(AppRadius.pill)),
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text(
                          'Verify',
                          style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                ),
              ),
            ],
          ),
        ),
        AnimatedSize(
          duration: AppMotion.base,
          curve: AppMotion.smooth,
          child: r == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  key: _resultKey,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, size: 16, color: color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(text, style: TextStyle(fontSize: 12, color: color, height: 1.4)),
                      ),
                    ],
                  ).animate().fadeIn(duration: AppMotion.base).slideY(begin: -.3, curve: AppMotion.smooth),
                ),
        ),
      ],
    );
  }
}

class _AllPaid extends StatelessWidget {
  const _AllPaid();
  @override
  Widget build(BuildContext context) => Glass(
    level: GlassLevel.heavy,
    radius: 28,
    padding: const EdgeInsets.all(22),
    child: Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: const BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
          child: const Icon(LucideIcons.check, color: Colors.white, size: 26),
        ).animate().scaleXY(begin: .6, duration: 500.ms, curve: Curves.elasticOut),
        const SizedBox(height: 12),
        const Text('No tuition due', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          'MoneyMate will remind you 14 days before the next invoice is due.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: AppColors.muted),
        ),
      ],
    ),
  );
}

class _PaidList extends StatelessWidget {
  const _PaidList({required this.invoices});
  final List<Map<String, dynamic>> invoices;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 24,
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Paid', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        for (final inv in invoices)
          Pressable(
            onTap: inv['transaction_id'] == null ? null : () => context.push('/receipt/${inv['transaction_id']}'),
            scale: .98,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  const Icon(LucideIcons.receipt, size: 16),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${inv['semester']} · ${_plain(inv['university'])}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  Text(
                    money(inv['amount'] as num, inv['currency'] as String),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  if (inv['transaction_id'] != null) ...[
                    const SizedBox(width: 6),
                    const Icon(LucideIcons.chevronRight, size: 16, color: AppColors.muted),
                  ],
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
