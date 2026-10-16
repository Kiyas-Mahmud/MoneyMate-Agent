import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/sheet.dart';
import '../../widgets/ui.dart';

/// What happened to a payment that never completed (blocked, cancelled or expired). Completed ones open their receipt.
class TransactionSheet extends StatelessWidget {
  const TransactionSheet({super.key, required this.tx});
  final Map<String, dynamic> tx;

  @override
  Widget build(BuildContext context) {
    final status = tx['status'] as String;
    final currency = tx['currency'] as String;
    final reasons = [for (final r in tx['risk_reasons'] as List? ?? const []) r.toString()];
    final level = tx['risk_level'] as String?;
    final score = (tx['risk_score'] as num?)?.toDouble();
    final (badge, tone, explain) = switch (status) {
      'BLOCKED' => ('Blocked', Tone.danger, 'MoneyMate refused to prepare this payment. No money left your wallet.'),
      'REJECTED' => ('Cancelled', Tone.neutral, 'You rejected this payment on the verify screen. Nothing was sent.'),
      'EXPIRED' => (
        'Expired',
        Tone.neutral,
        'It wasn\'t verified in time, so it was never sent. Ask the agent to prepare it again if you still need it.',
      ),
      'AWAITING_VERIFICATION' => (
        'Needs you',
        Tone.warning,
        'Waiting for your fingerprint. Open it from Home to verify.',
      ),
      _ => (status, Tone.neutral, ''),
    };
    final when = parseUtc(tx['created_at'] as String);
    final rows = <(String, String)>[
      ('To', (tx['counterparty'] as String? ?? '').replaceAll(RegExp(r'\s*\(.*\)$'), '')),
      if (tx['counterparty_account'] != null) ('Account', tx['counterparty_account'] as String),
      if (tx['provider'] != null) ('Via', tx['provider'] as String),
      (
        'Prepared',
        '${shortDate(tx['created_at'] as String)} · ${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}',
      ),
    ];

    return GlassSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Badge2(badge, tone: tone),
              const Spacer(),
              Text(
                money(tx['amount'] as num, currency),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.6,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: AppColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(explain, style: const TextStyle(fontSize: 13, color: Color(0xFF3A3A3A), height: 1.45)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .8),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                for (final (i, (k, v)) in rows.indexed)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      border: i == rows.length - 1
                          ? null
                          : Border(bottom: BorderSide(color: Colors.black.withValues(alpha: .06))),
                    ),
                    child: Row(
                      children: [
                        Text(k, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(v, textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (score != null && level != null) ...[
            const SizedBox(height: 14),
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
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final (i, r) in reasons.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.only(top: 6, right: 8),
                      decoration: BoxDecoration(
                        color: status == 'BLOCKED' ? AppColors.danger : AppColors.muted,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Expanded(child: Text(r, style: const TextStyle(fontSize: 12, height: 1.4))),
                  ],
                ),
              ).animate().fadeIn(delay: (100 + i * 70).ms),
          ],
          const SizedBox(height: 16),
          GlassButton(label: 'Close', onTap: () => Navigator.of(context).maybePop()),
        ],
      ),
    );
  }
}
