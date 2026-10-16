import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/background.dart';
import '../../widgets/glass.dart';
import '../../widgets/pressable.dart';
import '../../widgets/ui.dart';

class _SendSetup {
  _SendSetup(this.recipients, this.balances);
  final List<Map<String, dynamic>> recipients;
  final Map<String, double> balances; // currency -> wallet balance
}

final recipientsProvider = FutureProvider.autoDispose<_SendSetup>((ref) async {
  final api = ref.watch(apiProvider);
  final r = await Future.wait([api.get('/payees'), api.get('/wallet')]);
  return _SendSetup(
    [for (final p in (r[0] as Map)['recipients'] as List) Map<String, dynamic>.from(p)],
    {for (final b in (r[1] as Map)['balances'] as List) b['currency'] as String: (b['balance'] as num).toDouble()},
  );
}, retry: (_, _) => null);

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class SendMoneyScreen extends ConsumerStatefulWidget {
  const SendMoneyScreen({super.key, this.to});
  final String? to; // preselect a recipient by name
  @override
  ConsumerState<SendMoneyScreen> createState() => _SendMoneyScreenState();
}

class _SendMoneyScreenState extends ConsumerState<SendMoneyScreen> {
  final _amount = TextEditingController(text: '2000');
  int? _payeeId;
  String? _from; // currency the student sends
  List<Map<String, dynamic>> _options = [];
  String? _providerId;
  String? _quoteError;
  bool _quoting = false, _sending = false;
  Map<String, dynamic>? _blocked;
  Timer? _debounce;
  int _quoteSeq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _amount.dispose();
    super.dispose();
  }

  double get _value => double.tryParse(_amount.text.replaceAll(',', '')) ?? 0;

  Map<String, dynamic>? _payee(_SendSetup s) => s.recipients.where((p) => p['id'] == _payeeId).firstOrNull;
  Map<String, dynamic>? get _chosen =>
      _options.where((o) => o['provider_id'] == _providerId).firstOrNull ?? _options.firstOrNull;

  void _init(_SendSetup s) {
    if (_payeeId != null || s.recipients.isEmpty) return;
    final to = widget.to?.toLowerCase();
    final pre = to == null
        ? null
        : s.recipients.where((p) => p['name'].toString().toLowerCase() == to || p['relationship'] == to).firstOrNull;
    _payeeId = (pre ?? s.recipients.first)['id'] as int;
    _from ??= ref.read(sessionProvider).user?['study_currency'] as String? ?? 'CNY';
    WidgetsBinding.instance.addPostFrameCallback((_) => _quote(s));
  }

  /// Live quotes from every route, cheapest first. Debounced while the student types.
  void _requote(_SendSetup s) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _quote(s));
  }

  Future<void> _quote(_SendSetup s) async {
    final payee = _payee(s);
    if (payee == null || _value <= 0) {
      setState(() => _options = []);
      return;
    }
    final seq = ++_quoteSeq;
    setState(() {
      _quoting = true;
      _quoteError = null;
      _blocked = null;
    });
    try {
      final r = await ref.read(apiProvider).post('/remittance/compare', {
        'amount': _value,
        'from_currency': _from,
        'to_currency': payee['currency'],
      });
      if (seq != _quoteSeq || !mounted) return; // a newer quote is on its way
      setState(() {
        _options = [for (final o in r['options'] as List) Map<String, dynamic>.from(o)];
        if (_options.every((o) => o['provider_id'] != _providerId)) _providerId = _options.firstOrNull?['provider_id'];
      });
    } on ApiError catch (e) {
      if (seq == _quoteSeq && mounted) setState(() => _quoteError = e.message);
    } finally {
      if (seq == _quoteSeq && mounted) setState(() => _quoting = false);
    }
  }

  /// Prepares the transfer. It is only sent after the student verifies it on the next sheet.
  Future<void> _review(_SendSetup s) async {
    final payee = _payee(s)!;
    final chosen = _chosen;
    if (chosen == null) return;
    setState(() => _sending = true);
    try {
      final res = Map<String, dynamic>.from(
        await ref.read(apiProvider).post('/remittance/send', {
          'recipient': payee['name'],
          'amount': _value,
          'currency': _from,
          'provider_id': chosen['provider_id'],
        }),
      );
      if (!mounted) return;
      if (res['status'] == 'AWAITING_VERIFICATION') {
        context.push('/verify/${res['action_id']}');
      } else if (res['status'] == 'BLOCKED') {
        final txId = (res['transaction'] as Map?)?['id'];
        if (txId != null) {
          context.push('/safety?tx=$txId');
        } else {
          HapticFeedback.heavyImpact();
          setState(() => _blocked = res);
        }
      } else {
        toast(context, res['error'] as String? ?? 'Couldn\'t prepare this transfer', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _addRecipient(_SendSetup s) async {
    final added = await context.push<Map<String, dynamic>>('/recipients/new');
    if (added == null || !mounted) return;
    ref.invalidate(recipientsProvider);
    final fresh = await ref.read(recipientsProvider.future);
    setState(() => _payeeId = added['id'] as int);
    _quote(fresh);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(recipientsProvider);
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final s = async.value;
    if (s != null) _init(s);
    final payee = s == null ? null : _payee(s);
    final chosen = _chosen;

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
                    async.when(
                      loading: () => const Column(
                        children: [
                          Skeleton(height: 80, radius: 20),
                          SizedBox(height: 12),
                          Skeleton(height: 190, radius: 28),
                        ],
                      ),
                      error: (e, _) => Glass(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          '$e',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.muted),
                        ),
                      ),
                      data: (s) => Column(
                        children: [
                          _Recipients(
                            recipients: s.recipients,
                            selected: _payeeId,
                            onPick: (id) {
                              HapticFeedback.selectionClick();
                              setState(() => _payeeId = id);
                              _quote(s);
                            },
                            onAdd: () => _addRecipient(s),
                          ).enter(0),
                          const SizedBox(height: 12),
                          if (payee != null) ...[
                            _AmountCard(
                              controller: _amount,
                              from: _from!,
                              balance: s.balances[_from] ?? 0,
                              currencies: s.balances.keys.toList(),
                              payee: payee,
                              chosen: chosen,
                              quoting: _quoting,
                              onChanged: () => _requote(s),
                              onCurrency: (c) {
                                setState(() => _from = c);
                                _quote(s);
                              },
                            ).enter(1),
                            const SizedBox(height: 12),
                            AnimatedSize(
                              duration: AppMotion.base,
                              curve: AppMotion.smooth,
                              child: _quoteError != null
                                  ? Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Text(
                                        _quoteError!,
                                        style: const TextStyle(fontSize: 13, color: AppColors.danger),
                                      ),
                                    )
                                  : _options.isEmpty
                                  ? const SizedBox(width: double.infinity)
                                  : _Routes(
                                      options: _options,
                                      chosen: chosen?['provider_id'] as String?,
                                      onPick: (id) {
                                        HapticFeedback.selectionClick();
                                        setState(() => _providerId = id);
                                      },
                                    ),
                            ).enter(2),
                            const SizedBox(height: 12),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Row(
                                children: [
                                  payee['verified'] == true
                                      ? const Badge2('Verified', tone: Tone.success)
                                      : const Badge2('Saved recipient'),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'Nothing is sent until you verify it with your fingerprint.',
                                      style: TextStyle(fontSize: 12, color: AppColors.muted),
                                    ),
                                  ),
                                ],
                              ),
                            ).enter(3),
                            if (_blocked != null) ...[const SizedBox(height: 12), _Blocked(result: _blocked!)],
                          ] else
                            Glass(
                              padding: const EdgeInsets.all(20),
                              child: const Text(
                                'Add someone to send money to.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppColors.muted),
                              ),
                            ),
                        ],
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
                    onTap: () => context.canPop() ? context.pop() : context.go('/home'),
                  ),
                  const Expanded(
                    child: Text(
                      'Send money',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            if (s != null && payee != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: bottom + 20,
                child: AnimatedOpacity(
                  duration: AppMotion.fast,
                  opacity: chosen != null && !_quoting ? 1 : .5,
                  child: PrimaryButton(
                    icon: LucideIcons.fingerprint,
                    label: chosen == null
                        ? 'Enter an amount'
                        : 'Review ${money(_value, _from!)} with ${chosen['provider']}',
                    loading: _sending,
                    onTap: chosen != null && !_quoting ? () => _review(s) : null,
                  ),
                ).animate().fadeIn(delay: 250.ms).slideY(begin: .4, delay: 250.ms, curve: AppMotion.smooth),
              ),
          ],
        ),
      ),
    );
  }
}

class _Recipients extends StatelessWidget {
  const _Recipients({required this.recipients, required this.selected, required this.onPick, required this.onAdd});
  final List<Map<String, dynamic>> recipients;
  final int? selected;
  final ValueChanged<int> onPick;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 82,
    child: ListView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      children: [
        for (final p in recipients)
          _Person(
            letter: (p['name'] as String)[0],
            label: _cap(p['relationship'] as String? ?? (p['name'] as String).split(' ').first),
            selected: p['id'] == selected,
            onTap: () => onPick(p['id'] as int),
          ),
        Semantics(
          button: true,
          label: 'Add a recipient',
          child: Pressable(
            onTap: onAdd,
            child: const SizedBox(
              width: 70,
              child: Column(
                children: [
                  Glass(radius: 27, child: SizedBox(width: 54, height: 54, child: Icon(LucideIcons.plus, size: 20))),
                  SizedBox(height: 6),
                  Text('Add', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _Person extends StatelessWidget {
  const _Person({required this.letter, required this.label, required this.selected, required this.onTap});
  final String letter, label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    child: SizedBox(
      width: 70,
      child: Column(
        children: [
          AnimatedContainer(
            duration: AppMotion.base,
            curve: AppMotion.spring,
            width: 54,
            height: 54,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? AppColors.ink : Colors.white.withValues(alpha: .6),
              border: Border.all(color: Colors.white.withValues(alpha: .9)),
              boxShadow: selected
                  ? [BoxShadow(color: Colors.black.withValues(alpha: .18), blurRadius: 16, offset: const Offset(0, 6))]
                  : null,
            ),
            child: Text(
              letter.toUpperCase(),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.ink,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: selected ? AppColors.ink : AppColors.muted,
              fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ],
      ),
    ),
  );
}

class _AmountCard extends StatelessWidget {
  const _AmountCard({
    required this.controller,
    required this.from,
    required this.balance,
    required this.currencies,
    required this.payee,
    required this.chosen,
    required this.quoting,
    required this.onChanged,
    required this.onCurrency,
  });
  final TextEditingController controller;
  final String from;
  final double balance;
  final List<String> currencies;
  final Map<String, dynamic> payee;
  final Map<String, dynamic>? chosen;
  final bool quoting;
  final VoidCallback onChanged;
  final ValueChanged<String> onCurrency;

  @override
  Widget build(BuildContext context) {
    final to = payee['currency'] as String;
    final receive = (chosen?['receive_amount'] as num?)?.toDouble();
    final first = (payee['name'] as String).split(' ').first;
    final mid = (chosen?['mid_rate'] as num?)?.toDouble();
    return Glass(
      level: GlassLevel.heavy,
      radius: 28,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('You send', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                    Row(
                      children: [
                        Text(
                          currencySymbol(from),
                          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w600, letterSpacing: -0.9),
                        ),
                        Expanded(
                          child: TextField(
                            controller: controller,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                            onChanged: (_) => onChanged(),
                            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w600, letterSpacing: -0.9),
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(vertical: 2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                initialValue: from,
                onSelected: onCurrency,
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                itemBuilder: (_) => [for (final c in currencies) PopupMenuItem(value: c, child: Text(c))],
                child: _Chip(from, icon: LucideIcons.chevronDown),
              ),
            ],
          ),
          Text('Balance ${money(balance, from)}', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
          Container(
            height: 1,
            color: Colors.black.withValues(alpha: .07),
            margin: const EdgeInsets.symmetric(vertical: 14),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$first receives', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                    AnimatedOpacity(
                      duration: AppMotion.fast,
                      opacity: quoting ? .4 : 1,
                      child: receive == null
                          ? const Text('—', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600))
                          : TweenAnimationBuilder<double>(
                              tween: Tween(end: receive),
                              duration: AppMotion.slow,
                              curve: AppMotion.smooth,
                              builder: (_, v, _) => Text(
                                money(v, to),
                                style: const TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.9,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              _Chip(to),
            ],
          ),
          if (mid != null) ...[
            const SizedBox(height: 10),
            Text(
              'Mid-market 1 $from = ${mid.toStringAsFixed(mid < 1 ? 4 : 2)} $to · live rate',
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {this.icon});
  final String text;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .85),
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        if (icon != null) ...[const SizedBox(width: 4), Icon(icon, size: 14)],
      ],
    ),
  );
}

/// Every route side by side: the agent's pick is the cheapest, the student can choose another.
class _Routes extends StatelessWidget {
  const _Routes({required this.options, required this.chosen, required this.onPick});
  final List<Map<String, dynamic>> options;
  final String? chosen;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 26,
    padding: const EdgeInsets.all(8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Text(
            'Cheapest first · fee + exchange-rate margin',
            style: TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        ),
        for (final (i, o) in options.indexed)
          Pressable(
            onTap: () => onPick(o['provider_id'] as String),
            scale: .98,
            child: AnimatedContainer(
              duration: AppMotion.base,
              curve: AppMotion.smooth,
              margin: const EdgeInsets.only(bottom: 2),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: o['provider_id'] == chosen ? Colors.white.withValues(alpha: .95) : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
                boxShadow: o['provider_id'] == chosen
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .06),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.ink, width: 1.5),
                    ),
                    child: AnimatedScale(
                      duration: AppMotion.fast,
                      curve: AppMotion.spring,
                      scale: o['provider_id'] == chosen ? 1 : 0,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              o['provider'] as String,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                            ),
                            if (i == 0) ...[const SizedBox(width: 6), const Badge2('Cheapest', tone: Tone.success)],
                          ],
                        ),
                        const SizedBox(height: 1),
                        Text(o['eta'] as String? ?? '', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        money(o['receive_amount'] as num, o['receive_currency'] as String),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '${o['total_cost_pct']}% cost',
                        style: const TextStyle(fontSize: 11, color: AppColors.muted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ).animate().fadeIn(delay: (i * 60).ms, duration: AppMotion.base),
      ],
    ),
  );
}

/// The agent refused to prepare this transfer (e.g. money-mule pattern or a known scam account).
class _Blocked extends StatelessWidget {
  const _Blocked({required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final risk = result['risk'] as Map?;
    final reasons = [
      ...?(result['policy']?['rules'] as List?)?.cast<String>(),
      ...?(risk?['reasons'] as List?)?.map((r) => r['text'] as String),
    ];
    return Glass(
      radius: 24,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Badge2('Blocked', tone: Tone.danger),
              SizedBox(width: 8),
              Expanded(
                child: Text('MoneyMate won\'t send this', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          for (final r in reasons)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(top: 6, right: 8),
                    decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                  ),
                  Expanded(child: Text(r, style: const TextStyle(fontSize: 12, height: 1.4))),
                ],
              ),
            ),
        ],
      ),
    ).animate().fadeIn(duration: AppMotion.base).shakeX(hz: 3, amount: 4, duration: 400.ms);
  }
}
