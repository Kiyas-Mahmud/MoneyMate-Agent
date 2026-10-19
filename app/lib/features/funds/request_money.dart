import 'dart:async';

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
import '../../widgets/fields.dart';
import '../../widgets/glass.dart';
import '../../widgets/pressable.dart';
import '../../widgets/ui.dart';
import '../agent/agent_chat.dart';
import '../home/home_data.dart';
import '../wallet/wallet.dart';

final _familyProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref.watch(apiProvider).get('/funds/family') as List;
  return [for (final r in rows) Map<String, dynamic>.from(r)];
}, retry: (_, _) => null);

final _requestsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref.watch(apiProvider).get('/funds/requests') as List;
  return [for (final r in rows) Map<String, dynamic>.from(r)];
}, retry: (_, _) => null);

String _cap(String? s) => s == null || s.isEmpty ? '' : s[0].toUpperCase() + s.substring(1);

/// Ask family at home for money when the study-currency wallet is short. Shows what the family sends through
/// each provider (cheapest first) at live rates. In the sandbox the student marks the family's transfer as sent.
class RequestMoneyScreen extends ConsumerStatefulWidget {
  const RequestMoneyScreen({super.key, this.amount, this.reason});
  final double? amount;
  final String? reason;
  @override
  ConsumerState<RequestMoneyScreen> createState() => _RequestMoneyScreenState();
}

class _RequestMoneyScreenState extends ConsumerState<RequestMoneyScreen> {
  late final _amount = TextEditingController(text: widget.amount == null ? '' : widget.amount!.ceil().toString());
  late final _reason = TextEditingController(text: widget.reason ?? '');
  int? _familyId;
  List<Map<String, dynamic>> _options = [];
  bool _sending = false, _quoting = false;
  int? _busyRequest;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.amount != null) WidgetsBinding.instance.addPostFrameCallback((_) => _quote());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  double get _value => double.tryParse(_amount.text.replaceAll(',', '').trim()) ?? 0;

  void _onAmount(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _quote);
  }

  Future<void> _quote() async {
    if (_value <= 0) {
      setState(() => _options = []);
      return;
    }
    setState(() => _quoting = true);
    try {
      final r = await ref.read(apiProvider).get('/funds/quote', query: {'amount': _value});
      if (mounted) setState(() => _options = [for (final o in r['options'] as List) Map<String, dynamic>.from(o)]);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _quoting = false);
    }
  }

  Future<void> _send(List<Map<String, dynamic>> family) async {
    final id = _familyId ?? family.firstOrNull?['id'] as int?;
    if (id == null || _value <= 0) {
      toast(context, 'Choose who to ask and enter an amount', error: true);
      return;
    }
    setState(() => _sending = true);
    try {
      await ref.read(apiProvider).post('/funds/requests', {
        'payee_id': id,
        'amount': _value,
        if (_reason.text.trim().isNotEmpty) 'reason': _reason.text.trim(),
      });
      HapticFeedback.mediumImpact();
      ref.invalidate(_requestsProvider);
      if (mounted) toast(context, 'Request sent');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _arrive(Map<String, dynamic> req, String providerId) async {
    setState(() => _busyRequest = req['id'] as int);
    try {
      await ref.read(apiProvider).post('/funds/requests/${req['id']}/receive', {'provider_id': providerId});
      HapticFeedback.heavyImpact();
      ref.invalidate(_requestsProvider);
      ref.invalidate(walletProvider);
      ref.invalidate(homeProvider);
      ref.invalidate(agentOpenerProvider);
      if (mounted) toast(context, '${money(req['amount'] as num, req['currency'] as String)} received');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busyRequest = null);
    }
  }

  Future<void> _cancel(Map<String, dynamic> req) async {
    setState(() => _busyRequest = req['id'] as int);
    try {
      await ref.read(apiProvider).post('/funds/requests/${req['id']}/cancel');
      ref.invalidate(_requestsProvider);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busyRequest = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final family = ref.watch(_familyProvider).value ?? const [];
    final requests = ref.watch(_requestsProvider).value ?? const [];
    final selected = _familyId ?? family.firstOrNull?['id'] as int?;

    return Scaffold(
      body: DriftBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: TopFade(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(16, top + 68, 16, bottom + 40),
                  children: [
                    Glass(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Who should send it?', style: TextStyle(fontSize: 13, color: AppColors.muted)),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final f in family)
                                ChoiceChip2(
                                  label: '${_cap(f['relationship'] as String?)} · ${f['name']}',
                                  selected: selected == f['id'],
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    setState(() => _familyId = f['id'] as int);
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          GlassField(
                            label: 'Amount you need (CNY)',
                            controller: _amount,
                            hint: 'e.g. 8000',
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            onChanged: _onAmount,
                          ),
                          const SizedBox(height: 10),
                          GlassField(label: 'Reason (optional)', controller: _reason, hint: 'e.g. Spring 2027 tuition'),
                        ],
                      ),
                    ).animate().fadeIn(duration: AppMotion.base).slideY(begin: .06, curve: AppMotion.smooth),
                    if (_options.isNotEmpty || _quoting) ...[
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 8),
                        child: Text(
                          _quoting ? 'Checking live rates…' : 'What your family sends, at live rates',
                          style: const TextStyle(fontSize: 12, color: AppColors.muted),
                        ),
                      ),
                      Glass(
                        level: GlassLevel.light,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: Column(
                          children: [
                            for (final (i, o) in _options.indexed) ...[
                              if (i > 0) const Divider(height: 1, color: AppColors.line),
                              _OptionRow(o: o, best: i == 0),
                            ],
                          ],
                        ),
                      ).animate().fadeIn(duration: AppMotion.base),
                    ],
                    const SizedBox(height: 14),
                    PrimaryButton(
                      label: 'Send request',
                      icon: LucideIcons.send,
                      loading: _sending,
                      onTap: () => _send(family),
                    ),
                    if (requests.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      const Padding(
                        padding: EdgeInsets.only(left: 4, bottom: 8),
                        child: Text('Your requests', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                      ),
                      for (final (i, req) in requests.take(6).indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _RequestCard(
                            req: req,
                            busy: _busyRequest == req['id'],
                            onArrive: (p) => _arrive(req, p),
                            onCancel: () => _cancel(req),
                          ),
                        ).animate().fadeIn(delay: (60 * i).ms, duration: AppMotion.base),
                    ],
                    const SizedBox(height: 8),
                    const Text(
                      'Sandbox: no real money moves. In production a licensed bank or remittance partner sends it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10.5, color: AppColors.hint),
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
                      'Ask family for money',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  CircleGlassButton(
                    icon: LucideIcons.chartLine,
                    tooltip: 'Exchange rates',
                    onTap: () => context.push('/rates'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.o, required this.best});
  final Map<String, dynamic> o;
  final bool best;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      o['provider'] as String,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                  ),
                  if (best) ...[const SizedBox(width: 6), const Badge2('Cheapest', tone: Tone.success)],
                ],
              ),
              Text(
                '${o['eta']} · fee ${money(o['fee'] as num, o['send_currency'] as String)}',
                style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
              ),
            ],
          ),
        ),
        Text(
          money(o['send_amount'] as num, o['send_currency'] as String),
          style: TextStyle(fontSize: 15, fontWeight: best ? FontWeight.w600 : FontWeight.w500),
        ),
      ],
    ),
  );
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.req, required this.busy, required this.onArrive, required this.onCancel});
  final Map<String, dynamic> req;
  final bool busy;
  final ValueChanged<String> onArrive;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final status = req['status'] as String;
    final fam = req['family'] as Map?;
    final (label, tone) = switch (status) {
      'RECEIVED' => ('Received', Tone.success),
      'CANCELLED' => ('Cancelled', Tone.neutral),
      _ => ('Waiting for family', Tone.warning),
    };
    final best = (req['options'] as List?)?.firstOrNull as Map?;
    final via = req['received_via'] as Map?;
    return Glass(
      level: GlassLevel.light,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${money(req['amount'] as num, req['currency'] as String)} from ${fam?['name'] ?? 'family'}',
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
              ),
              Badge2(label, tone: tone),
            ],
          ),
          if ((req['reason'] as String?)?.isNotEmpty ?? false)
            Text(req['reason'] as String, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          if (via != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Sent ${money(via['send_amount'] as num, req['send_currency'] as String)} via ${via['provider']}',
                style: const TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ),
          if (status == 'REQUESTED' && best != null) ...[
            const SizedBox(height: 4),
            Text(
              'Best: ${best['provider']}, ${money(best['send_amount'] as num, best['send_currency'] as String)}',
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Pressable(
                    onTap: busy ? null : () => onArrive(best['provider_id'] as String),
                    child: Container(
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.ink,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : const Text(
                              'Family sent it (sandbox)',
                              style: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w500),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Pressable(
                  onTap: busy ? null : onCancel,
                  child: Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .85),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: const Text('Cancel', style: TextStyle(fontSize: 13.5)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
