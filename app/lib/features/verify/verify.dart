import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/device.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/pressable.dart';
import '../../widgets/ui.dart';
import '../agent/agent_chat.dart';
import '../home/home_data.dart';

final _actionProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int>(
  (ref, id) async => Map<String, dynamic>.from(await ref.watch(apiProvider).get('/agent/actions/$id')),
  retry: (_, _) => null,
);

enum _Phase { review, scanning, done, rejected }

String _plainName(String? s) => (s ?? '').replaceAll(RegExp(r'\s*\(.*\)$'), '');

/// Bottom sheet where the student approves (fingerprint) or rejects one prepared payment.
class VerifySheet extends ConsumerStatefulWidget {
  const VerifySheet({super.key, required this.actionId});
  final int actionId;

  @override
  ConsumerState<VerifySheet> createState() => _VerifySheetState();
}

class _VerifySheetState extends ConsumerState<VerifySheet> with SingleTickerProviderStateMixin {
  _Phase _phase = _Phase.review;
  Map<String, dynamic>? _outcome; // verify response: receipt, transaction
  String? _problem;
  bool _needsFingerprint = false;
  bool _rejecting = false;
  Timer? _tick;
  Duration _left = Duration.zero;
  double _drag = 0, _dragFrom = 0;
  late final AnimationController _snap = AnimationController(vsync: this, duration: AppMotion.fast)
    ..addListener(() => setState(() => _drag = _dragFrom * (1 - Curves.easeOut.transform(_snap.value))));

  // Back from the system fingerprint setup: offer the verify button again.
  late final _lifecycle = AppLifecycleListener(
    onResume: () {
      if (_needsFingerprint && mounted) {
        setState(() {
          _needsFingerprint = false;
          _problem = null;
        });
      }
    },
  );

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _tick?.cancel();
    _snap.dispose();
    super.dispose();
  }

  void _startCountdown(String? expiresAt) {
    if (_tick != null || expiresAt == null) return;
    final end = parseUtc(expiresAt);
    void update() {
      final left = end.difference(DateTime.now());
      if (!mounted) return;
      setState(() => _left = left.isNegative ? Duration.zero : left);
      if (left.isNegative) _tick?.cancel();
    }

    _tick = Timer.periodic(const Duration(seconds: 1), (_) => update());
    WidgetsBinding.instance.addPostFrameCallback((_) => update());
  }

  Future<void> _verify() async {
    setState(() {
      _phase = _Phase.scanning;
      _problem = null;
      _needsFingerprint = false;
    });
    try {
      final res = await ref.read(deviceVerifierProvider).verify(widget.actionId);
      HapticFeedback.heavyImpact();
      _tick?.cancel();
      ref.read(agentChatProvider.notifier).markAction(widget.actionId, 'VERIFIED');
      ref.invalidate(homeProvider);
      final txId = res['transaction_id'] ?? (res['result'] as Map?)?['transaction']?['id'];
      if (ref.read(_actionProvider(widget.actionId)).value?['tool'] == 'send_remittance' && txId != null && mounted) {
        // Transfers get the full "Sent" confirmation screen.
        context.pushReplacement('/sent/$txId');
        return;
      }
      setState(() {
        _outcome = res;
        _phase = _Phase.done;
      });
    } on VerifyProblem catch (e) {
      setState(() {
        _phase = _Phase.review;
        _problem = e.cancelled ? null : e.message;
        _needsFingerprint = e.needsFingerprint;
      });
    } on ApiError catch (e) {
      setState(() {
        _phase = _Phase.review;
        _problem = e.message;
      });
    }
  }

  Future<void> _reject() async {
    setState(() => _rejecting = true);
    try {
      await ref.read(apiProvider).post('/agent/actions/${widget.actionId}/reject');
      _tick?.cancel();
      ref.read(agentChatProvider.notifier).markAction(widget.actionId, 'REJECTED');
      ref.invalidate(homeProvider);
      setState(() => _phase = _Phase.rejected);
    } on ApiError catch (e) {
      setState(() => _problem = e.message);
    } finally {
      if (mounted) setState(() => _rejecting = false);
    }
  }

  void _close() => context.canPop() ? context.pop() : context.go('/home');

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_actionProvider(widget.actionId));
    final bottom = MediaQuery.paddingOf(context).bottom;

    Widget body = async.when(
      loading: () => const SizedBox(
        height: 320,
        child: Center(child: CircularProgressIndicator(color: AppColors.ink, strokeWidth: 2)),
      ),
      error: (e, _) =>
          _Message(icon: LucideIcons.circleAlert, title: 'Couldn\'t open this payment', body: '$e', onDone: _close),
      data: (a) {
        final status = a['status'] as String;
        if (_phase == _Phase.review && status != 'AWAITING_VERIFICATION') {
          // Opened from an old notification: show how it ended instead of a dead verify button.
          return switch (status) {
            'VERIFIED' => _Success(action: a, outcome: a, onDone: _close),
            'REJECTED' => _Message(
              icon: LucideIcons.x,
              title: 'Payment cancelled',
              body: 'You rejected it. Nothing was sent.',
              onDone: _close,
            ),
            'EXPIRED' => _Message(
              icon: LucideIcons.clock,
              title: 'This request expired',
              body: 'Nothing was sent. Ask the agent to prepare it again.',
              onDone: _close,
            ),
            _ => _Message(
              icon: LucideIcons.shieldX,
              title: 'Nothing to verify',
              body: 'This action does not need your verification.',
              onDone: _close,
            ),
          };
        }
        _startCountdown(a['expires_at'] as String?);
        return switch (_phase) {
          _Phase.done => _Success(action: a, outcome: _outcome!, onDone: _close),
          _Phase.rejected => _Message(
            icon: LucideIcons.x,
            title: 'Payment cancelled',
            body: 'Nothing was sent.',
            onDone: _close,
          ),
          _ => _Review(
            action: a,
            left: _left,
            scanning: _phase == _Phase.scanning,
            rejecting: _rejecting,
            problem: _problem,
            needsFingerprint: _needsFingerprint,
            onVerify: _verify,
            onReject: _reject,
            onEnroll: () => ref.read(deviceVerifierProvider).keystore.openEnroll(),
          ),
        };
      },
    );

    return Align(
      alignment: Alignment.bottomCenter,
      child: GestureDetector(
        // Drag the sheet down to close it, like a native sheet.
        onVerticalDragUpdate: (d) => setState(() => _drag = (_drag + d.delta.dy).clamp(0, 400)),
        onVerticalDragEnd: (d) {
          if (_drag > 120 || d.velocity.pixelsPerSecond.dy > 900) return _close();
          _dragFrom = _drag;
          _snap.forward(from: 0);
        },
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .92),
            child: Glass(
              level: GlassLevel.heavy,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
              padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + bottom),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .18),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: SingleChildScrollView(
                        child: AnimatedSize(
                          duration: AppMotion.base,
                          curve: AppMotion.smooth,
                          child: AnimatedSwitcher(
                            duration: AppMotion.base,
                            child: KeyedSubtree(key: ValueKey(_phase), child: body),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Review extends StatelessWidget {
  const _Review({
    required this.action,
    required this.left,
    required this.scanning,
    required this.rejecting,
    required this.problem,
    required this.needsFingerprint,
    required this.onVerify,
    required this.onReject,
    required this.onEnroll,
  });
  final Map<String, dynamic> action;
  final Duration left;
  final bool scanning, rejecting, needsFingerprint;
  final String? problem;
  final VoidCallback onVerify, onReject, onEnroll;

  @override
  Widget build(BuildContext context) {
    final r = Map<String, dynamic>.from(action['result'] as Map? ?? {});
    final tx = Map<String, dynamic>.from(r['transaction'] as Map? ?? {});
    final currency = tx['currency'] as String? ?? 'USD';
    final pv = r['payee_verification'] as Map?;
    final verified = pv?['status'] == 'VERIFIED';
    final plan = (r['plan'] as List?)?.cast<Map>() ?? const [];
    final risk = r['risk'] as Map<String, dynamic>?;
    final invoice = r['invoice'] as Map?;
    final expired = left == Duration.zero && action['expires_at'] != null;
    final mm = left.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = left.inSeconds.remainder(60).toString().padLeft(2, '0');
    final clock = left.inHours > 0 ? '${left.inHours}:$mm:$ss' : '$mm:$ss';

    final subtitle = switch (action['tool']) {
      'pay_tuition' => '${invoice?['semester'] ?? ''} tuition'.trim(),
      'send_remittance' => tx['memo'] as String? ?? 'Transfer',
      'convert_currency' => tx['memo'] as String? ?? 'Currency conversion',
      _ => action['summary'] as String? ?? '',
    };
    final account = [
      if (pv?['bank'] != null) _short(pv!['bank'] as String),
      tx['counterparty_account'],
    ].whereType<String>().join(' ');
    final good = [...?(risk?['protective_factors'] as List?)?.cast<String>()];
    final watch = [...?(risk?['reasons'] as List?)?.map((e) => e['text'] as String)];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Verify to complete payment', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            Text(
              expired ? 'Expired' : 'Expires in $clock',
              style: TextStyle(
                fontSize: 12,
                color: expired ? AppColors.danger : AppColors.muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text(
              money(tx['amount'] as num? ?? 0, currency),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 42, fontWeight: FontWeight.w600, letterSpacing: -1.6),
            )
            .animate()
            .fadeIn(duration: AppMotion.base)
            .scaleXY(begin: .9, curve: AppMotion.spring, duration: AppMotion.slow),
        const SizedBox(height: 4),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: AppColors.muted),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: .8), borderRadius: BorderRadius.circular(22)),
          child: Column(
            children: [
              _Row(
                'To',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _plainName(tx['counterparty']),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                    ),
                    if (verified) ...[
                      const SizedBox(width: 6),
                      const Icon(LucideIcons.badgeCheck, size: 15, color: AppColors.success),
                    ],
                  ],
                ),
              ),
              if (account.isNotEmpty) _Row('Account', value: account),
              if (tx['provider'] != null && action['tool'] == 'send_remittance')
                _Row('Via', value: tx['provider'] as String),
              if (plan.length > 1)
                _Row(
                  'Plan',
                  value: [
                    for (final (i, p) in plan.indexed)
                      p['step'] == 'convert'
                          ? '${i + 1}. Convert ${money(p['amount'] as num, p['from'] as String)} → ${money(p['receive'] as num, p['to'] as String)}'
                          : '${i + 1}. Pay ${money(p['amount'] as num, p['currency'] as String)}',
                  ].join('\n'),
                ),
              if ((tx['fee'] as num? ?? 0) > 0) _Row('Fee', value: money(tx['fee'] as num, currency, decimals: true)),
              if (risk != null) _RiskRow(risk: risk),
            ],
          ),
        ),
        const SizedBox(height: 14),
        for (final (i, line) in [
          for (final g in good) (LucideIcons.circleCheck, g, AppColors.success),
          for (final w in watch) (LucideIcons.info, w, AppColors.warning),
          (
            LucideIcons.shieldCheck,
            'Every payment needs your verification. The agent can\'t move money on its own.',
            AppColors.ink,
          ),
        ].indexed)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(line.$1, size: 15, color: line.$3),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(line.$2, style: const TextStyle(fontSize: 12, color: Color(0xFF3A3A3A), height: 1.35)),
                ),
              ],
            ),
          ).animate().fadeIn(delay: (120 + i * 70).ms, duration: AppMotion.base),
        AnimatedSize(
          duration: AppMotion.fast,
          child: problem == null
              ? const SizedBox(width: double.infinity)
              : Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.dangerBg, borderRadius: BorderRadius.circular(16)),
                  child: Text(problem!, style: const TextStyle(fontSize: 13, color: AppColors.danger)),
                ).animate().shakeX(hz: 4, amount: 3, duration: 350.ms),
        ),
        const SizedBox(height: 12),
        if (needsFingerprint)
          PrimaryButton(label: 'Set up fingerprint', icon: LucideIcons.fingerprint, onTap: onEnroll)
        else
          _ScanButton(scanning: scanning, enabled: !expired && !rejecting, onTap: onVerify),
        const SizedBox(height: 10),
        GlassButton(label: rejecting ? 'Rejecting…' : 'Reject', onTap: scanning || rejecting ? null : onReject),
      ],
    );
  }

  static String _short(String bank) => bank.split(',').first;
}

class _Row extends StatelessWidget {
  const _Row(this.label, {this.value, this.trailing});
  final String label;
  final String? value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 11),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: Colors.black.withValues(alpha: .06))),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
        const SizedBox(width: 16),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child:
                trailing ??
                Text(value ?? '', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, height: 1.5)),
          ),
        ),
      ],
    ),
  );
}

class _RiskRow extends StatelessWidget {
  const _RiskRow({required this.risk});
  final Map<String, dynamic> risk;

  @override
  Widget build(BuildContext context) {
    final level = risk['level'] as String? ?? 'LOW';
    final score = (risk['score'] as num? ?? 0).toDouble();
    final color = level == 'HIGH'
        ? AppColors.danger
        : level == 'MEDIUM'
        ? AppColors.warning
        : AppColors.success;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Fraud risk', style: TextStyle(fontSize: 13, color: AppColors.muted)),
              ),
              Text(
                '${level[0]}${level.substring(1).toLowerCase()} · ${(score * 100).round()}%',
                style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          const SizedBox(height: 8),
          RiskBar(score: score, level: level),
        ],
      ),
    );
  }
}

/// The fingerprint button. While the system prompt is up it pulses, mirroring the sensor.
class _ScanButton extends StatelessWidget {
  const _ScanButton({required this.scanning, required this.enabled, required this.onTap});
  final bool scanning, enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final button = Pressable(
      onTap: enabled && !scanning ? onTap : null,
      haptic: true,
      child: AnimatedOpacity(
        duration: AppMotion.fast,
        opacity: enabled ? 1 : .4,
        child: Container(
          height: 54,
          decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(AppRadius.pill)),
          child: AnimatedSwitcher(
            duration: AppMotion.fast,
            child: Row(
              key: ValueKey(scanning),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(LucideIcons.fingerprint, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(
                  scanning ? 'Touch the fingerprint sensor' : 'Verify with fingerprint',
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!scanning) return button;
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child:
              DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      color: AppColors.ink.withValues(alpha: .25),
                    ),
                  )
                  .animate(onPlay: (c) => c.repeat())
                  .scaleXY(end: 1.12, duration: 900.ms, curve: Curves.easeOut)
                  .fadeOut(duration: 900.ms),
        ),
        button,
      ],
    );
  }
}

class _Success extends StatelessWidget {
  const _Success({required this.action, required this.outcome, required this.onDone});
  final Map<String, dynamic> action;
  final Map<String, dynamic> outcome;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final r = Map<String, dynamic>.from(outcome['result'] as Map? ?? {});
    final tx = Map<String, dynamic>.from(r['transaction'] as Map? ?? {});
    final receipt = r['receipt'] as Map?;
    final title = switch (action['tool']) {
      'pay_tuition' => 'Tuition paid',
      'send_remittance' => 'Money sent',
      'convert_currency' => 'Converted',
      _ => 'Payment complete',
    };
    final amount = tx['amount'] == null ? '' : money(tx['amount'] as num, tx['currency'] as String);
    final txId = tx['id'] ?? outcome['transaction_id'];

    return Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 4),
      child: Column(
        children: [
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Two soft rings ripple out once, then the badge settles.
                for (final d in [0, 180])
                  Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.ink.withValues(alpha: .25), width: 2),
                        ),
                      )
                      .animate()
                      .scaleXY(begin: 1, end: 1.6, delay: (250 + d).ms, duration: 900.ms, curve: Curves.easeOut)
                      .fadeOut(delay: (250 + d).ms, duration: 900.ms),
                Container(
                  width: 76,
                  height: 76,
                  decoration: const BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
                  child: const Icon(
                    LucideIcons.check,
                    color: Colors.white,
                    size: 36,
                  ).animate().scaleXY(begin: 0, delay: 220.ms, duration: 420.ms, curve: Curves.elasticOut),
                ).animate().scaleXY(begin: .5, duration: 520.ms, curve: Curves.elasticOut).fadeIn(duration: 200.ms),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ).animate().fadeIn(delay: 300.ms).slideY(begin: .3, delay: 300.ms, curve: AppMotion.smooth),
          const SizedBox(height: 6),
          Text(
            [
              if (amount.isNotEmpty) '$amount to ${_plainName(tx['counterparty'])}',
              if (receipt?['reference'] != null) 'Receipt ${receipt!['reference']}',
            ].join('\n'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: AppColors.muted, height: 1.5),
          ).animate().fadeIn(delay: 420.ms),
          const SizedBox(height: 26),
          if (txId != null)
            PrimaryButton(
              label: 'View receipt',
              onTap: () => context.pushReplacement('/receipt/$txId'),
            ).animate().fadeIn(delay: 520.ms).slideY(begin: .3, delay: 520.ms, curve: AppMotion.smooth),
          const SizedBox(height: 10),
          GlassButton(label: 'Done', onTap: onDone).animate().fadeIn(delay: 600.ms),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body, required this.onDone});
  final IconData icon;
  final String title, body;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 4),
    child: Column(
      children: [
        Glass(
          radius: 38,
          child: SizedBox(width: 76, height: 76, child: Icon(icon, size: 30)),
        ).animate().scaleXY(begin: .6, duration: 480.ms, curve: Curves.elasticOut).fadeIn(duration: 200.ms),
        const SizedBox(height: 18),
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: AppColors.muted, height: 1.5),
        ),
        const SizedBox(height: 26),
        GlassButton(label: 'Done', onTap: onDone),
      ],
    ),
  ).animate().fadeIn(duration: AppMotion.base);
}
