import 'dart:async';
import 'dart:math' as math;

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
import '../../widgets/pressable.dart';
import '../../widgets/ui.dart';
import '../home/home_data.dart';

final walletProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) async => Map<String, dynamic>.from(await ref.watch(apiProvider).get('/wallet')),
  retry: (_, _) => null,
);

/// Balances in every currency, and conversions between the student's own wallets at live rates.
class WalletScreen extends ConsumerStatefulWidget {
  const WalletScreen({super.key, this.from, this.to, this.receive});
  final String? from, to; // prefilled from a tuition reminder: convert BDT to receive 8,000 CNY
  final double? receive;

  @override
  ConsumerState<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends ConsumerState<WalletScreen> {
  final _amount = TextEditingController();
  late String _from = widget.from ?? 'BDT';
  late String _to = widget.to ?? 'CNY';
  Map<String, dynamic>? _quote;
  bool _quoting = false, _converting = false, _prefilled = false;
  String? _error;
  Timer? _debounce;
  int _seq = 0;
  late final _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(walletProvider));

  @override
  void initState() {
    super.initState();
    _lifecycle;
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefill());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _debounce?.cancel();
    _amount.dispose();
    super.dispose();
  }

  double get _value => double.tryParse(_amount.text.replaceAll(',', '')) ?? 0;

  Future<Map<String, dynamic>> _fetchQuote(double amount) async {
    final r = await ref.read(apiProvider).post('/remittance/compare', {
      'amount': amount,
      'from_currency': _from,
      'to_currency': _to,
    });
    // Conversions between your own wallets use the RemitLite rate (see the backend's convert_currency).
    return Map<String, dynamic>.from((r['options'] as List).firstWhere((o) => o['provider_id'] == 'remitlite'));
  }

  /// If opened to cover a shortfall, work out how much to convert so exactly that amount arrives.
  Future<void> _prefill() async {
    final want = widget.receive;
    if (want == null || want <= 0) {
      _amount.text = '10000';
      _requote(now: true);
      return;
    }
    try {
      // The backend rounds rates to 4 decimals (0.0539 for BDT→CNY, ~0.1% off), so derive the exact rate
      // from a large quote's received amount instead.
      const probe = 1000000.0;
      final q = await _fetchQuote(probe);
      final fee = (q['fee'] as num).toDouble();
      final rate = (q['receive_amount'] as num).toDouble() / (probe - fee);
      final need = (want / rate + fee);
      _amount.text = (need.ceilToDouble()).toStringAsFixed(0);
      _prefilled = true;
      _requote(now: true);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _requote({bool now = false}) {
    _debounce?.cancel();
    _debounce = Timer(now ? Duration.zero : const Duration(milliseconds: 350), () async {
      if (_value <= 0 || _from == _to) {
        setState(() => _quote = null);
        return;
      }
      final seq = ++_seq;
      setState(() {
        _quoting = true;
        _error = null;
      });
      try {
        final q = await _fetchQuote(_value);
        if (seq == _seq && mounted) setState(() => _quote = q);
      } on ApiError catch (e) {
        if (seq == _seq && mounted) setState(() => _error = e.message);
      } finally {
        if (seq == _seq && mounted) setState(() => _quoting = false);
      }
    });
  }

  void _swap() {
    HapticFeedback.selectionClick();
    setState(() {
      final t = _from;
      _from = _to;
      _to = t;
      _prefilled = false;
    });
    _requote(now: true);
  }

  /// Prepares the conversion; it only runs after the student verifies it.
  Future<void> _convert() async {
    setState(() => _converting = true);
    try {
      final res = Map<String, dynamic>.from(
        await ref.read(apiProvider).post('/wallet/convert', {
          'amount': _value,
          'from_currency': _from,
          'to_currency': _to,
        }),
      );
      if (!mounted) return;
      if (res['status'] == 'AWAITING_VERIFICATION') {
        await context.push('/verify/${res['action_id']}');
        ref.invalidate(walletProvider);
        ref.invalidate(homeProvider);
      } else {
        toast(context, res['error'] as String? ?? 'Couldn\'t prepare this conversion', error: true);
      }
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(walletProvider);
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final w = async.value;
    final balances = <String, (double, double)>{
      for (final b in (w?['balances'] as List?) ?? const [])
        b['currency'] as String: ((b['balance'] as num).toDouble(), (b['usd_equivalent'] as num).toDouble()),
    };
    final currencies = balances.keys.toList();
    final have = balances[_from]?.$1 ?? 0;
    final tooMuch = _value > have && w != null;
    final ready = _quote != null && !_quoting && !tooMuch && _value > 0;

    return Scaffold(
      body: DriftBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: TopFade(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(16, top + 68, 16, bottom + 110),
                  children: [
                    if (w == null)
                      const Skeleton(height: 92, radius: 22)
                    else
                      Row(
                        children: [
                          for (final (i, c) in currencies.indexed) ...[
                            if (i > 0) const SizedBox(width: 8),
                            Expanded(
                              child: Glass(
                                radius: 22,
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(c, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                                    const SizedBox(height: 2),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: TweenAnimationBuilder<double>(
                                        tween: Tween(end: balances[c]!.$1),
                                        duration: AppMotion.slow,
                                        curve: AppMotion.smooth,
                                        builder: (_, v, _) => Text(
                                          money(v, c),
                                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '≈ ${money(balances[c]!.$2, 'USD')}',
                                      style: const TextStyle(fontSize: 11, color: AppColors.muted),
                                    ),
                                  ],
                                ),
                              ).enter(i, baseMs: 70),
                            ),
                          ],
                        ],
                      ),
                    const SizedBox(height: 12),
                    Glass(
                      level: GlassLevel.heavy,
                      radius: 28,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Convert', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 12),
                          Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.center,
                            children: [
                              Column(
                                children: [
                                  _Side(
                                    label: 'From $_from',
                                    currency: _from,
                                    currencies: currencies,
                                    onCurrency: (c) {
                                      setState(() {
                                        if (c == _to) _to = _from;
                                        _from = c;
                                        _prefilled = false;
                                      });
                                      _requote(now: true);
                                    },
                                    trailing: Text(
                                      'Balance ${money(have, _from)}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: tooMuch ? AppColors.danger : AppColors.muted,
                                      ),
                                    ),
                                    child: TextField(
                                      controller: _amount,
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                                      onChanged: (_) {
                                        _prefilled = false;
                                        _requote();
                                      },
                                      style: const TextStyle(
                                        fontSize: 26,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -0.6,
                                      ),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        prefixText: currencySymbol(_from),
                                        prefixStyle: const TextStyle(
                                          fontSize: 26,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.ink,
                                        ),
                                        contentPadding: const EdgeInsets.symmetric(vertical: 2),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  _Side(
                                    label: 'To $_to',
                                    currency: _to,
                                    currencies: currencies,
                                    onCurrency: (c) {
                                      setState(() {
                                        if (c == _from) _from = _to;
                                        _to = c;
                                        _prefilled = false;
                                      });
                                      _requote(now: true);
                                    },
                                    trailing: _prefilled
                                        ? const Badge2('Covers tuition', tone: Tone.success)
                                        : const SizedBox.shrink(),
                                    child: AnimatedOpacity(
                                      duration: AppMotion.fast,
                                      opacity: _quoting ? .4 : 1,
                                      child: TweenAnimationBuilder<double>(
                                        tween: Tween(end: (_quote?['receive_amount'] as num?)?.toDouble() ?? 0),
                                        duration: AppMotion.slow,
                                        curve: AppMotion.smooth,
                                        builder: (_, v, _) => Text(
                                          money(v, _to),
                                          style: const TextStyle(
                                            fontSize: 26,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: -0.6,
                                            fontFeatures: [FontFeature.tabularFigures()],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              Semantics(
                                button: true,
                                label: 'Swap currencies',
                                child: Pressable(
                                  onTap: _swap,
                                  scale: .85,
                                  child: Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: AppColors.ink,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 3),
                                    ),
                                    child: const Icon(LucideIcons.arrowUpDown, size: 16, color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          if (_quote != null) ...[
                            _Line('Rate after fees', () {
                              final rate = (_quote!['rate'] as num).toDouble();
                              // Show whichever way round reads naturally: "1 CNY = 18.20 BDT".
                              return rate >= 1
                                  ? '1 $_from = ${rate.toStringAsFixed(2)} $_to'
                                  : '1 $_to = ${(1 / rate).toStringAsFixed(2)} $_from';
                            }()),
                            _Line(
                              'Fee',
                              '${money(_quote!['fee'] as num, _from, decimals: true)} · ${_quote!['total_cost_pct']}% total cost',
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${(w?['rates_source'] as String? ?? '').startsWith('live') ? 'Live' : 'Saved'} mid-market rate '
                              '${math.max((_quote!['mid_rate'] as num).toDouble(), 1 / (_quote!['mid_rate'] as num).toDouble()).toStringAsFixed(2)}'
                              ' · ExchangeRate-API',
                              style: const TextStyle(fontSize: 11, color: AppColors.muted),
                            ),
                          ],
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(_error!, style: const TextStyle(fontSize: 12, color: AppColors.danger)),
                            ),
                          if (tooMuch)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                'Your $_from wallet only has ${money(have, _from)}.',
                                style: const TextStyle(fontSize: 12, color: AppColors.danger),
                              ),
                            ),
                        ],
                      ),
                    ).enter(3),
                    const SizedBox(height: 12),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        'Conversions move money between your own wallets. Like every payment, they wait for your fingerprint.',
                        style: TextStyle(fontSize: 12, color: AppColors.muted, height: 1.45),
                      ),
                    ).enter(4),
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
                      'Wallet',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: bottom + 20,
              child: AnimatedOpacity(
                duration: AppMotion.fast,
                opacity: ready ? 1 : .45,
                child: PrimaryButton(
                  label: 'Verify with fingerprint to convert',
                  icon: LucideIcons.fingerprint,
                  loading: _converting,
                  onTap: ready ? _convert : null,
                ),
              ).animate().fadeIn(delay: 250.ms).slideY(begin: .4, delay: 250.ms, curve: AppMotion.smooth),
            ),
          ],
        ),
      ),
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({
    required this.label,
    required this.currency,
    required this.currencies,
    required this.onCurrency,
    required this.trailing,
    required this.child,
  });
  final String label, currency;
  final List<String> currencies;
  final ValueChanged<String> onCurrency;
  final Widget trailing, child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .8), borderRadius: BorderRadius.circular(20)),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
              child,
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            PopupMenuButton<String>(
              initialValue: currency,
              onSelected: onCurrency,
              color: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              itemBuilder: (_) => [for (final c in currencies) PopupMenuItem(value: c, child: Text(c))],
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: AppColors.canvas, borderRadius: BorderRadius.circular(AppRadius.pill)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(currency, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                    const SizedBox(width: 2),
                    const Icon(LucideIcons.chevronDown, size: 13),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            trailing,
          ],
        ),
      ],
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
        const Spacer(),
        Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
      ],
    ),
  );
}
