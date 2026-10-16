import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/device.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/confirm.dart';
import '../../widgets/glass.dart';
import '../../widgets/pressable.dart';
import '../../widgets/sheet.dart';
import '../../widgets/ui.dart';
import '../activity/activity.dart';
import '../agent/agent_chat.dart';
import '../home/home_data.dart';
import '../notifications/notifications.dart';

class _ProfileData {
  _ProfileData(this.currencies, this.recipients, this.university, this.standing, this.policy, this.fingerprint);
  final List<String> currencies;
  final List<Map<String, dynamic>> recipients;
  final Map<String, dynamic>? university;
  final List<Map<String, dynamic>> standing;
  final Map<String, dynamic> policy;
  final String fingerprint; // ready | none_enrolled | unavailable
}

final _profileProvider = FutureProvider.autoDispose<_ProfileData>((ref) async {
  final api = ref.watch(apiProvider);
  final user = ref.read(sessionProvider).user ?? const {};
  final r = await Future.wait([
    api.get('/wallet'),
    api.get('/payees'),
    api.get('/standing-instructions'),
    api.get('/risk/model'),
  ]);
  String fp;
  try {
    fp = await ref.read(deviceVerifierProvider).keystore.status();
  } catch (_) {
    fp = 'unavailable';
  }
  final payees = Map<String, dynamic>.from(r[1]);
  final registry = [for (final p in payees['registry'] as List) Map<String, dynamic>.from(p)];
  return _ProfileData(
    [for (final b in (r[0] as Map)['balances'] as List) b['currency'] as String],
    [for (final p in payees['recipients'] as List) Map<String, dynamic>.from(p)],
    registry.where((p) => p['name'] == user['university']).firstOrNull,
    [for (final s in r[2] as List) Map<String, dynamic>.from(s)],
    Map<String, dynamic>.from((r[3] as Map)['policy'] as Map? ?? {}),
    fp,
  );
}, retry: (_, _) => null);

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _busy = false;
  late final _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(_profileProvider));

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

  void _refreshAll() {
    for (final p in [homeProvider, activityProvider, notificationsProvider]) {
      ref.invalidate(p);
    }
    ref.invalidate(_profileProvider);
  }

  Future<void> _simulateStranger() async {
    final ok = await confirm(
      context,
      title: 'Simulate money from a stranger?',
      body:
          'A company you have never dealt with sends you ¥30,000 in the sandbox. Watch MoneyMate warn you, '
          'then try to send it on: the transfer will be blocked as money-mule activity.',
      action: 'Simulate',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final tx = await ref.read(apiProvider).post('/sandbox/incoming', {
        'sender': 'Global Remote Jobs Ltd',
        'amount': 30000,
        'currency': 'CNY',
        'note': 'part-time job payment',
      });
      _refreshAll();
      if (mounted) context.push('/safety?tx=${tx['id']}');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final ok = await confirm(
      context,
      title: 'Reset demo data?',
      body: 'Wallets, invoices, recipients and payments go back to the starting demo. The audit log is kept: it can\'t be erased.',
      action: 'Reset',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).post('/sandbox/reset');
      await ref.read(agentChatProvider.notifier).newChat();
      _refreshAll();
      if (mounted) toast(context, 'Demo data reset');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    final ok = await confirm(
      context,
      title: 'Sign out?',
      body: 'You\'ll need your password to sign in again.',
      action: 'Sign out',
    );
    if (ok) await ref.read(sessionProvider.notifier).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider).user ?? const {};
    final async = ref.watch(_profileProvider);
    final d = async.value;
    final top = MediaQuery.paddingOf(context).top;
    final name = user['full_name'] as String? ?? '';

    String recipientsText() {
      final r = d?.recipients ?? const [];
      if (r.isEmpty) return 'None yet';
      final names = r.map((p) => _cap(p['relationship'] as String? ?? (p['name'] as String).split(' ').first)).toList();
      return names.length > 3 ? '${names.take(3).join(', ')} +${names.length - 3}' : names.join(', ');
    }

    final ttl = d?.policy['verification_ttl_minutes'];
    final ttlSched = d?.policy['scheduled_verification_ttl_hours'];

    final sections = <Widget>[
      Row(
        children: [
          Glass(
            radius: 34,
            child: SizedBox(
              width: 68,
              height: 68,
              child: Center(
                child: Text(
                  name.isEmpty ? '' : name[0],
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.3)),
                const SizedBox(height: 2),
                Text(
                  [
                    if (user['university'] != null)
                      (user['university'] as String).replaceAll(RegExp(r'\s*\(.*\)$'), ''),
                    if (user['student_id'] != null) user['student_id'],
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12.5, color: AppColors.muted),
                ),
                Text(
                  '${user['home_country'] ?? ''} → ${user['study_country'] ?? ''}',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ],
      ),
      _Card(
        rows: [
          _RowData('Wallets', d == null ? '…' : d.currencies.join(' · '), onTap: () => context.push('/wallet')),
          _RowData('Saved recipients', d == null ? '…' : recipientsText(), onTap: () => context.push('/send')),
          _RowData(
            'University on file',
            d?.university == null ? (d == null ? '…' : 'Not linked') : 'Verified ${d!.university!['account_hint']}',
            valueColor: d?.university == null ? null : AppColors.success,
          ),
        ],
      ),
      _Card(
        title: 'Security',
        rows: [
          _RowData(
            'Verify with fingerprint',
            switch (d?.fingerprint) {
              'ready' => 'On',
              'none_enrolled' => 'Set up',
              null => '…',
              _ => 'Not available',
            },
            valueColor: d?.fingerprint == 'ready' ? AppColors.success : AppColors.warning,
            onTap: d?.fingerprint == 'none_enrolled'
                ? () => ref.read(deviceVerifierProvider).keystore.openEnroll()
                : null,
          ),
          const _RowData('Agent pays on its own', 'Never · you verify every payment'),
          _RowData('Verification requests expire', ttl == null ? '…' : '$ttl min · scheduled ${ttlSched ?? 24} h'),
          _RowData(
            'Standing instructions',
            d == null
                ? '…'
                : d.standing.isEmpty
                ? 'None'
                : d.standing
                      .map(
                        (s) => s['relationship'] == 'landlord'
                            ? 'Rent'
                            : _cap(s['relationship'] as String? ?? s['recipient'] as String),
                      )
                      .join(', '),
            onTap: () => context.push('/standing'),
          ),
          _RowData('How MoneyMate protects you', '', onTap: () => context.push('/protection')),
        ],
      ),
      _Card(
        title: 'Demo tools (sandbox)',
        rows: [
          _RowData('Simulate money from a stranger', '', onTap: _busy ? null : _simulateStranger),
          _RowData('Reset demo data', 'Keeps the audit log', onTap: _busy ? null : _reset),
        ],
      ),
      Pressable(
        onTap: _signOut,
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .7),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: Colors.white),
          ),
          child: const Text(
            'Sign out',
            style: TextStyle(fontSize: 15, color: AppColors.danger, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    ];

    return RefreshIndicator(
      color: AppColors.ink,
      backgroundColor: Colors.white,
      edgeOffset: top,
      onRefresh: () => ref.refresh(_profileProvider.future),
      child: TopFade(
        from: -6,
        to: 18,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          padding: EdgeInsets.fromLTRB(16, top + 20, 16, 130),
          children: [
            for (final (i, s) in sections.indexed) ...[if (i > 0) const SizedBox(height: 14), s.enter(i, baseMs: 60)],
          ],
        ),
      ),
    );
  }
}

class _RowData {
  const _RowData(this.label, this.value, {this.onTap, this.valueColor});
  final String label, value;
  final VoidCallback? onTap;
  final Color? valueColor;
}

// Information rows aren't buttons: only tappable rows get the press effect (and the disabled fade).
Widget _wrap(_RowData r, Widget child) => r.onTap == null ? child : Pressable(onTap: r.onTap, scale: .98, child: child);

class _Card extends StatelessWidget {
  const _Card({required this.rows, this.title});
  final List<_RowData> rows;
  final String? title;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 24,
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text(
              title!,
              style: const TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w500),
            ),
          ),
        for (final (i, r) in rows.indexed)
          _wrap(
            r,
            Container(
              padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                border: i == rows.length - 1
                    ? null
                    : Border(bottom: BorderSide(color: Colors.black.withValues(alpha: .06))),
              ),
              child: Row(
                children: [
                  Text(r.label, style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      r.value,
                      textAlign: TextAlign.right,
                      maxLines: 2,
                      style: TextStyle(fontSize: 13, color: r.valueColor ?? AppColors.muted, height: 1.35),
                    ),
                  ),
                  if (r.onTap != null) ...[
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

/// Plain-language summary of the safety rules, for the student (and for judges).
class ProtectionSheet extends StatelessWidget {
  const ProtectionSheet({super.key});

  @override
  Widget build(BuildContext context) {
    const items = [
      (
        LucideIcons.fingerprint,
        'You approve every payment',
        'The agent prepares payments but can\'t send one. A key that only your fingerprint unlocks signs each approval.',
      ),
      (
        LucideIcons.badgeCheck,
        'Official accounts only for tuition',
        'Tuition goes only to accounts in the verified university registry. Look-alike accounts are flagged as impersonation.',
      ),
      (
        LucideIcons.brain,
        'Fraud model on every payment',
        'Six models score each payment against your usual behaviour. High risk is blocked, with the reasons shown.',
      ),
      (
        LucideIcons.shieldAlert,
        'Money-mule protection',
        'Money from a stranger that you try to pass on is stopped. Receiving and forwarding money for others is illegal.',
      ),
      (
        LucideIcons.scanText,
        'Scam check before you pay',
        'Paste or photograph any message asking for money. Pressure, threats and fake discounts are explained.',
      ),
      (
        LucideIcons.fileLock,
        'Records nobody can quietly edit',
        'Every action is written to a hash-chained audit log, and every receipt carries a code anyone can check.',
      ),
    ];
    return GlassSheet(
      title: 'How MoneyMate protects you',
      child: Column(
        children: [
          for (final (i, (icon, title, body)) in items.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, size: 17, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(body, style: const TextStyle(fontSize: 12.5, color: Color(0xFF4A4A4A), height: 1.45)),
                      ],
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(delay: (80 + i * 60).ms).slideX(begin: .04, delay: (80 + i * 60).ms),
        ],
      ),
    );
  }
}
