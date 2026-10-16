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

final notificationsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref.watch(apiProvider).get('/notifications', query: {'limit': 80}) as List;
  return [for (final n in rows) Map<String, dynamic>.from(n)];
}, retry: (_, _) => null);

/// What each kind of notification looks like and where tapping it goes.
(IconData, Tone, String?) _style(Map<String, dynamic> n) {
  final data = Map<String, dynamic>.from(n['data'] as Map? ?? {});
  return switch (n['kind']) {
    'VERIFY_PAYMENT' => (
      LucideIcons.fingerprint,
      Tone.ink,
      n['action_id'] == null ? null : '/verify/${n['action_id']}',
    ),
    'PAYMENT_DONE' => (
      LucideIcons.circleCheck,
      Tone.success,
      data['transaction_id'] == null ? null : '/receipt/${data['transaction_id']}',
    ),
    'PAYMENT_BLOCKED' => (
      LucideIcons.shieldX,
      Tone.danger,
      n['action_id'] == null ? '/activity' : '/safety?action=${n['action_id']}',
    ),
    'MULE_ALERT' => (
      LucideIcons.shieldAlert,
      Tone.warning,
      data['transaction_id'] == null ? '/activity' : '/safety?tx=${data['transaction_id']}',
    ),
    'TUITION_REMINDER' => (LucideIcons.calendar, Tone.warning, '/tuition'),
    'LOW_BALANCE' => (LucideIcons.wallet, Tone.warning, '/wallet'),
    'DEVICE_ADDED' || 'PAYEE_ADDED' => (LucideIcons.userCheck, Tone.neutral, null),
    _ => (LucideIcons.bell, Tone.neutral, null),
  };
}

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});
  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  final Set<int> _readLocally = {};

  Future<void> _readAll(List<Map<String, dynamic>> items) async {
    HapticFeedback.selectionClick();
    setState(() => _readLocally.addAll(items.map((n) => n['id'] as int)));
    try {
      await ref.read(apiProvider).post('/notifications/read-all');
      ref.invalidate(homeProvider);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }

  Future<void> _open(Map<String, dynamic> n, String? to) async {
    final id = n['id'] as int;
    if (n['read'] != true && !_readLocally.contains(id)) {
      setState(() => _readLocally.add(id));
      ref.read(apiProvider).post('/notifications/$id/read').then((_) => ref.invalidate(homeProvider)).ignore();
    }
    if (to != null) context.push(to);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(notificationsProvider);
    final top = MediaQuery.paddingOf(context).top;
    final items = async.value ?? const [];
    final unread = items.where((n) => n['read'] != true && !_readLocally.contains(n['id'])).length;

    // "Today" and "Earlier", the way people think about alerts.
    final now = DateTime.now();
    bool isToday(Map<String, dynamic> n) {
      final d = parseUtc(n['created_at'] as String);
      return d.year == now.year && d.month == now.month && d.day == now.day;
    }

    final today = items.where(isToday).toList();
    final earlier = items.where((n) => !isToday(n)).toList();

    Widget section(String title, List<Map<String, dynamic>> list, int base) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
          child: Text(
            title,
            style: const TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w500),
          ),
        ),
        for (final (i, n) in list.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _Item(
              n: n,
              unread: n['read'] != true && !_readLocally.contains(n['id']),
              onTap: (to) => _open(n, to),
            ).enter(base + i, baseMs: 40),
          ),
      ],
    );

    return Scaffold(
      body: DriftBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: RefreshIndicator(
                color: AppColors.ink,
                backgroundColor: Colors.white,
                edgeOffset: top + 60,
                onRefresh: () => ref.refresh(notificationsProvider.future),
                child: TopFade(
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                    padding: EdgeInsets.fromLTRB(16, top + 68, 16, 40),
                    children: [
                      if (async.isLoading && async.value == null)
                        for (var i = 0; i < 5; i++)
                          const Padding(padding: EdgeInsets.only(bottom: 8), child: Skeleton(height: 76, radius: 22))
                      else if (async.hasError && async.value == null)
                        Glass(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            '${async.error}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.muted),
                          ),
                        )
                      else if (items.isEmpty)
                        const _Empty()
                      else ...[
                        if (today.isNotEmpty) section('Today', today, 0),
                        if (earlier.isNotEmpty) section('Earlier', earlier, today.length),
                      ],
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
                  SizedBox(
                    width: 84,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: CircleGlassButton(
                        icon: LucideIcons.chevronLeft,
                        tooltip: 'Back',
                        onTap: () => context.canPop() ? context.pop() : context.go('/home'),
                      ),
                    ),
                  ),
                  const Expanded(
                    child: Text(
                      'Notifications',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  SizedBox(
                    width: 72,
                    child: AnimatedOpacity(
                      duration: AppMotion.fast,
                      opacity: unread > 0 ? 1 : 0,
                      child: TextButton(
                        onPressed: unread > 0 ? () => _readAll(items) : null,
                        child: const Text(
                          'Read all',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(color: AppColors.ink, fontSize: 13),
                        ),
                      ),
                    ),
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

class _Item extends StatelessWidget {
  const _Item({required this.n, required this.unread, required this.onTap});
  final Map<String, dynamic> n;
  final bool unread;
  final ValueChanged<String?> onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, tone, to) = _style(n);
    final (bg, fg) = switch (tone) {
      Tone.ink => (AppColors.ink, Colors.white),
      Tone.success => (AppColors.successBg, AppColors.success),
      Tone.warning => (AppColors.warningBg, AppColors.warning),
      Tone.danger => (AppColors.dangerBg, AppColors.danger),
      Tone.neutral => (Colors.white.withValues(alpha: .9), AppColors.ink),
    };
    final d = parseUtc(n['created_at'] as String);
    final age = DateTime.now().difference(d);
    final when = age.inMinutes < 1
        ? 'now'
        : age.inHours < 24
        ? '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'
        : shortDate(n['created_at'] as String);

    return Pressable(
      onTap: () => onTap(to),
      scale: .98,
      child: Glass(
        radius: 22,
        level: unread ? GlassLevel.heavy : GlassLevel.light,
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: Icon(icon, size: 17, color: fg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          n['title'] as String? ?? '',
                          style: TextStyle(fontSize: 14, fontWeight: unread ? FontWeight.w600 : FontWeight.w500),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(when, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                      AnimatedContainer(
                        duration: AppMotion.base,
                        width: unread ? 8 : 0,
                        height: 8,
                        margin: EdgeInsets.only(left: unread ? 6 : 0),
                        decoration: const BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    n['body'] as String? ?? '',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: Color(0xFF4A4A4A), height: 1.4),
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

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 80),
    child: Column(
      children: [
        const Glass(radius: 34, child: SizedBox(width: 68, height: 68, child: Icon(LucideIcons.bellOff, size: 26))),
        const SizedBox(height: 14),
        const Text('All quiet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          'Deadlines, payments to verify and safety alerts show up here.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppColors.muted),
        ),
      ],
    ).animate().fadeIn(duration: AppMotion.base),
  );
}
