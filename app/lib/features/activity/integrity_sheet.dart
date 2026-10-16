import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/anchor_line.dart';
import '../../widgets/pressable.dart';
import '../../widgets/sheet.dart';
import '../../widgets/ui.dart';

final _integrityProvider = FutureProvider.autoDispose<(Map<String, dynamic>, Map<String, dynamic>)>((ref) async {
  final api = ref.watch(apiProvider);
  final r = await Future.wait([api.get('/audit/verify'), api.get('/anchors')]);
  return (Map<String, dynamic>.from(r[0]), Map<String, dynamic>.from(r[1]));
}, retry: (_, _) => null);

String _short(String? h) =>
    h == null || h.length < 14 ? (h ?? '') : '${h.substring(0, 8)}…${h.substring(h.length - 6)}';

/// What "Log intact" means: the hash chain check, and its anchors on a public test blockchain.
class IntegritySheet extends ConsumerStatefulWidget {
  const IntegritySheet({super.key});
  @override
  ConsumerState<IntegritySheet> createState() => _IntegritySheetState();
}

class _IntegritySheetState extends ConsumerState<IntegritySheet> {
  bool _running = false;
  String? _note;

  Future<void> _anchorNow() async {
    setState(() {
      _running = true;
      _note = null;
    });
    try {
      final r = Map<String, dynamic>.from(await ref.read(apiProvider).post('/anchors/run'));
      HapticFeedback.selectionClick();
      setState(
        () => _note = switch (r['status']) {
          'sent' => 'Sent to the blockchain. It is confirmed in about 15 seconds; pull down or reopen to see it.',
          'up_to_date' => 'Already anchored: nothing new since the last anchor.',
          'disabled' => 'Anchoring is switched off on the server.',
          _ => r['message'] as String? ?? 'Couldn\'t anchor right now.',
        },
      );
      ref.invalidate(_integrityProvider);
    } on ApiError catch (e) {
      setState(() => _note = e.message);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_integrityProvider);
    return GlassSheet(
      title: 'Audit log',
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CircularProgressIndicator(color: AppColors.ink, strokeWidth: 2)),
        ),
        error: (e, _) => Text('$e', style: const TextStyle(color: AppColors.muted)),
        data: (data) {
          final (check, listing) = data;
          final anch = Map<String, dynamic>.from(check['anchoring'] as Map? ?? {});
          final valid = check['valid'] == true;
          final latest = anch['latest'] as Map?;
          final onChain = anch['on_chain'] as String?;
          final anchors = [for (final a in listing['anchors'] as List? ?? const []) Map<String, dynamic>.from(a)];
          final (icon, color, title, body) = !valid
              ? (
                  LucideIcons.shieldAlert,
                  AppColors.danger,
                  'The log does not check out',
                  onChain == 'mismatch'
                      ? 'A past record no longer matches the copy anchored on the blockchain.'
                      : 'A past record was changed: the hash chain is broken.',
                )
              : (
                  LucideIcons.shieldCheck,
                  AppColors.success,
                  'All ${check['entries']} records check out',
                  'Every action is chained by SHA-256 hashes, so editing any past record breaks the chain.',
                );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    child: Icon(icon, color: Colors.white, size: 20),
                  ).animate().scaleXY(begin: .5, duration: 500.ms, curve: Curves.elasticOut),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(body, style: const TextStyle(fontSize: 12.5, color: Color(0xFF4A4A4A), height: 1.4)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .8),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(LucideIcons.link, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            latest == null ? 'Blockchain anchor · ${anch['chain'] ?? 'test network'}' : 'Anchored on ${anch['chain']}',
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Badge2(
                          switch (onChain) {
                            'ok' => 'Matches',
                            'mismatch' => 'Mismatch',
                            'unavailable' => 'Can\'t reach chain',
                            _ => 'Not yet',
                          },
                          tone: switch (onChain) {
                            'ok' => Tone.success,
                            'mismatch' => Tone.danger,
                            'unavailable' => Tone.warning,
                            _ => Tone.neutral,
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      latest == null
                          ? 'The latest hash of the log is written to a public test blockchain every day, so even someone '
                                'with database access can\'t rewrite history unnoticed.'
                          : 'Records 1–${latest['entry_id']} are covered. The newest anchor was written in block '
                                '${latest['block_number']}; nobody can change it afterwards.',
                      style: const TextStyle(fontSize: 12, color: AppColors.muted, height: 1.45),
                    ),
                    if (latest != null) ...[
                      const SizedBox(height: 10),
                      Pressable(
                        onTap: () => openExplorer(context, latest['explorer_url'] as String?),
                        child: Container(
                          height: 42,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.ink,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(LucideIcons.externalLink, size: 15, color: Colors.white),
                              SizedBox(width: 6),
                              Text(
                                'View on explorer',
                                style: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (anchors.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Padding(
                  padding: EdgeInsets.only(left: 4, bottom: 4),
                  child: Text('Recent anchors', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                ),
                for (final (i, a) in anchors.take(5).indexed)
                  Pressable(
                    onTap: a['tx_hash'] == null ? null : () => openExplorer(context, a['explorer_url'] as String?),
                    scale: .98,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Records up to #${a['entry_id']}',
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                ),
                                Text(
                                  '${_short(a['tx_hash'] as String?)} · ${shortDate(a['created_at'] as String?)}',
                                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                                ),
                              ],
                            ),
                          ),
                          Badge2(
                            switch (a['status']) {
                              'CONFIRMED' => 'Confirmed',
                              'SENT' => 'Sent',
                              _ => 'Failed',
                            },
                            tone: switch (a['status']) {
                              'CONFIRMED' => Tone.success,
                              'SENT' => Tone.warning,
                              _ => Tone.danger,
                            },
                          ),
                        ],
                      ),
                    ),
                  ).animate().fadeIn(delay: (80 + i * 50).ms),
              ],
              AnimatedSize(
                duration: AppMotion.base,
                child: _note == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _note!,
                          style: const TextStyle(fontSize: 12.5, color: Color(0xFF3A3A3A), height: 1.4),
                        ),
                      ),
              ),
              const SizedBox(height: 14),
              if (listing['enabled'] == true)
                GlassButton(
                  label: _running ? 'Anchoring…' : 'Anchor now (sandbox)',
                  icon: LucideIcons.link,
                  onTap: _running ? null : _anchorNow,
                ),
              if (listing['wallet'] != null) ...[
                const SizedBox(height: 10),
                Text(
                  'Anchor wallet ${_short(listing['wallet'] as String)} · only hashes go on-chain, never personal data',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 10.5, color: AppColors.hint),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
