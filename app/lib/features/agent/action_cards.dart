import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/pressable.dart';
import '../../widgets/ui.dart';

const moneyTools = {'pay_tuition', 'send_remittance', 'convert_currency'};

String _plainName(String? s) => (s ?? '').replaceAll(RegExp(r'\s*\(.*\)$'), '');

/// Picks the card for one tool result, or nothing for tools that only feed the reply text.
Widget? actionCard(Map<String, dynamic> a) {
  final tool = a['tool'];
  if (a['status'] == 'ERROR') return null; // a tool call the agent retried; the reply explains
  if (moneyTools.contains(tool) && a['transaction'] != null) return PaymentCard(action: a);
  return switch (tool) {
    'analyze_payment_request' => ScamCard(result: a),
    'get_wallet_balances' => BalancesCard(result: a),
    'compare_remittance_providers' when a['options'] != null => CompareCard(result: a),
    'create_standing_instruction' when a['standing_instruction'] != null => StandingCard(result: a),
    _ => null,
  };
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Glass(radius: 26, padding: const EdgeInsets.all(15), child: child);
}

class _RiskLine extends StatelessWidget {
  const _RiskLine({required this.risk});
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
    final label = '${level[0]}${level.substring(1).toLowerCase()} · ${(score * 100).round()}%';
    return Column(
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Fraud risk', style: TextStyle(fontSize: 11, color: AppColors.muted)),
            ),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 6),
        RiskBar(score: score, level: level),
      ],
    );
  }
}

class _Bullets extends StatelessWidget {
  const _Bullets(this.lines, {this.color = AppColors.danger});
  final List<String> lines;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final (i, l) in lines.indexed)
        Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(top: 6, right: 8),
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  Expanded(
                    child: Text(l, style: const TextStyle(fontSize: 12, color: Color(0xFF3A3A3A), height: 1.4)),
                  ),
                ],
              ),
            )
            .animate()
            .fadeIn(delay: (150 + i * 90).ms, duration: AppMotion.base)
            .slideX(begin: .05, delay: (150 + i * 90).ms),
    ],
  );
}

class _Amount extends StatelessWidget {
  const _Amount(this.text, {this.struck = false});
  final String text;
  final bool struck;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.8,
      decoration: struck ? TextDecoration.lineThrough : null,
      decorationColor: AppColors.danger.withValues(alpha: .6),
      decorationThickness: 2,
    ),
  );
}

/// A payment the agent prepared (waiting for verification) or refused (blocked).
class PaymentCard extends StatefulWidget {
  const PaymentCard({super.key, required this.action});
  final Map<String, dynamic> action;

  @override
  State<PaymentCard> createState() => _PaymentCardState();
}

class _PaymentCardState extends State<PaymentCard> {
  bool _later = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.action;
    final tx = Map<String, dynamic>.from(a['transaction']);
    final status = a['status'] as String;
    final blocked = status == 'BLOCKED';
    final waiting = status == 'AWAITING_VERIFICATION';
    final verified = (a['payee_verification'] as Map?)?['status'] == 'VERIFIED';
    final invoice = a['invoice'] as Map?;
    final plan = (a['plan'] as List?)?.cast<Map>() ?? const [];
    final convert = plan.where((p) => p['step'] == 'convert').firstOrNull;
    final risk = a['risk'] as Map<String, dynamic>?;

    final badge = switch (status) {
      'BLOCKED' => const Badge2('Blocked', tone: Tone.danger),
      'COMPLETED' || 'EXECUTED' || 'VERIFIED' => const Badge2('Paid', tone: Tone.success),
      'REJECTED' => const Badge2('Cancelled'),
      'EXPIRED' => const Badge2('Expired'),
      _ =>
        verified
            ? const Badge2('Verified account', tone: Tone.ink)
            : Badge2(switch (a['tool']) {
                'send_remittance' => 'Transfer',
                'convert_currency' => 'Conversion',
                _ => 'Payment',
              }),
    };
    final corner = invoice != null
        ? 'Due ${shortDate(invoice['due_date'])}'
        : tx['provider'] != null
        ? 'via ${tx['provider']}'
        : (tx['counterparty_account'] as String? ?? '');
    final reasons = blocked
        ? [
            ...?(a['policy']?['rules'] as List?)?.cast<String>(),
            ...?(risk?['reasons'] as List?)?.map((r) => r['text'] as String),
          ]
        : const <String>[];

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              badge,
              const Spacer(),
              Text(corner, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 12),
          Text(_plainName(tx['counterparty']), style: const TextStyle(fontSize: 13, color: Color(0xFF4A4A4A))),
          const SizedBox(height: 2),
          _Amount(money(tx['amount'] as num, tx['currency'] as String), struck: blocked),
          if (tx['kind'] == 'REMITTANCE_OUT' && tx['memo'] != null)
            Text(
              '${tx['memo']} · fee ${money(tx['fee'] as num, tx['currency'] as String)}',
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          if (convert != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .7),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const Icon(LucideIcons.arrowLeftRight, size: 15),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'First converts ${money(convert['amount'] as num, convert['from'] as String)} → '
                      '${money(convert['receive'] as num, convert['to'] as String)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (reasons.isNotEmpty) ...[const SizedBox(height: 4), _Bullets(reasons)],
          if (risk != null) ...[const SizedBox(height: 12), _RiskLine(risk: risk)],
          if (waiting)
            AnimatedSize(
              duration: AppMotion.base,
              curve: AppMotion.smooth,
              child: _later
                  ? const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'It waits on Home until you verify it or it expires. Nothing is sent before then.',
                        style: TextStyle(fontSize: 12, color: AppColors.muted),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Row(
                        children: [
                          Expanded(child: _VerifyButton(onTap: () => context.push('/verify/${a['action_id']}'))),
                          const SizedBox(width: 8),
                          Pressable(
                            onTap: () => setState(() => _later = true),
                            child: Container(
                              height: 46,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: .8),
                                borderRadius: BorderRadius.circular(AppRadius.pill),
                              ),
                              child: const Text('Not now', style: TextStyle(fontSize: 14)),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

/// Black pill with a light sheen sweeping across it, the one call to action in the chat.
class _VerifyButton extends StatelessWidget {
  const _VerifyButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    haptic: true,
    child:
        Container(
              height: 46,
              decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(AppRadius.pill)),
              clipBehavior: Clip.antiAlias,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.fingerprint, color: Colors.white, size: 18),
                  SizedBox(width: 6),
                  Text(
                    'Review and verify',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            )
            .animate(onPlay: (c) => c.repeat())
            .shimmer(delay: 800.ms, duration: 2400.ms, color: Colors.white.withValues(alpha: .28)),
  );
}

/// Result of checking a pasted message that asks for money.
class ScamCard extends StatelessWidget {
  const ScamCard({super.key, required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final verdict = result['verdict'] as String? ?? 'CAUTION';
    final scam = verdict == 'LIKELY_SCAM';
    final ex = Map<String, dynamic>.from(result['extracted'] as Map? ?? {});
    final pv = result['payee_verification'] as Map?;
    final op = result['second_opinion'] as Map?;
    final flags = [for (final f in result['red_flags'] as List? ?? const []) f['explanation'] as String];
    if (pv?['status'] == 'UNKNOWN') flags.insert(0, 'Not a verified university account');
    final account = ex['account'] as String?;
    final digits = account?.replaceAll(RegExp(r'\D'), '') ?? '';

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              switch (verdict) {
                'LIKELY_SCAM' => const Badge2('Likely scam', tone: Tone.danger),
                'NO_RED_FLAGS_FOUND' => const Badge2('No red flags', tone: Tone.success),
                _ => const Badge2('Be careful', tone: Tone.warning),
              },
              const Spacer(),
              if (digits.length >= 8)
                Text(
                  'Account ${digits.substring(0, 4)} …${digits.substring(digits.length - 4)}',
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            ex['payee'] as String? ?? 'Unknown payee',
            style: const TextStyle(fontSize: 13, color: Color(0xFF4A4A4A)),
          ),
          if (ex['amount'] != null) ...[
            const SizedBox(height: 2),
            _Amount(money(ex['amount'] as num, ex['currency'] as String? ?? 'USD'), struck: scam),
          ],
          if (flags.isNotEmpty) ...[
            const SizedBox(height: 4),
            _Bullets(flags, color: scam ? AppColors.danger : AppColors.warning),
          ],
          if (op?['available'] == true && op?['explanation'] != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(LucideIcons.sparkles, size: 14, color: AppColors.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'AI second opinion: ${op!['explanation']}',
                    style: const TextStyle(fontSize: 12, color: AppColors.muted, height: 1.4),
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

class BalancesCard extends StatelessWidget {
  const BalancesCard({super.key, required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) => _Card(
    child: Row(
      children: [
        for (final (i, b) in (result['balances'] as List).take(3).indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b['currency'] as String, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    money(b['balance'] as num, b['currency'] as String),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

/// Transfer routes side by side, cheapest first.
class CompareCard extends StatelessWidget {
  const CompareCard({super.key, required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final options = (result['options'] as List).cast<Map>();
    return _Card(
      child: Column(
        children: [
          for (final (i, o) in options.take(4).indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
              child: Row(
                children: [
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
                        Text(
                          '${o['total_cost_pct']}% total cost',
                          style: const TextStyle(fontSize: 11, color: AppColors.muted),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    money(o['receive_amount'] as num, o['receive_currency'] as String),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: i == 0 ? AppColors.ink : AppColors.muted,
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(delay: (100 + i * 80).ms, duration: AppMotion.base),
        ],
      ),
    );
  }
}

class StandingCard extends StatelessWidget {
  const StandingCard({super.key, required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final si = result['standing_instruction'] as Map;
    return _Card(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(14)),
            child: const Icon(LucideIcons.repeat, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${money(si['amount'] as num, si['currency'] as String)} to ${si['recipient']}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                Text(
                  'Day ${si['day_of_month']} of every month · you verify each one',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
