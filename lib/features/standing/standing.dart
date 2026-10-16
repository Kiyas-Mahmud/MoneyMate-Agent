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
import '../../widgets/fields.dart';
import '../../widgets/glass.dart';
import '../../widgets/pressable.dart';
import '../../widgets/sheet.dart';
import '../../widgets/ui.dart';

final standingProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref.watch(apiProvider).get('/standing-instructions') as List;
  return [for (final r in rows) Map<String, dynamic>.from(r)];
}, retry: (_, _) => null);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _ordinal(int d) =>
    '$d${d >= 11 && d <= 13 ? 'th' : switch (d % 10) {
            1 => 'st',
            2 => 'nd',
            3 => 'rd',
            _ => 'th',
          }}';

/// The next day the agent will prepare this payment (it skips a month it already prepared).
DateTime _nextDate(Map<String, dynamic> si) {
  final now = DateTime.now();
  final day = si['day_of_month'] as int;
  final thisMonth = '${now.year}-${now.month.toString().padLeft(2, '0')}';
  final doneThisMonth = si['last_prepared_period'] == thisMonth;
  if (!doneThisMonth && now.day <= day) return DateTime(now.year, now.month, day);
  return DateTime(now.year, now.month + 1, day);
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class StandingScreen extends ConsumerStatefulWidget {
  const StandingScreen({super.key});
  @override
  ConsumerState<StandingScreen> createState() => _StandingScreenState();
}

class _StandingScreenState extends ConsumerState<StandingScreen> {
  final Map<int, bool> _optimistic = {};

  Future<void> _toggle(Map<String, dynamic> si, bool on) async {
    final id = si['id'] as int;
    HapticFeedback.selectionClick();
    setState(() => _optimistic[id] = on);
    try {
      await ref.read(apiProvider).post('/standing-instructions/$id/${on ? 'resume' : 'pause'}');
      ref.invalidate(standingProvider);
    } on ApiError catch (e) {
      if (mounted) {
        setState(() => _optimistic.remove(id));
        toast(context, e.message, error: true);
      }
    }
  }

  Future<void> _add() async {
    final created = await context.push<bool>('/standing/new');
    if (created == true) {
      ref.invalidate(standingProvider);
      if (mounted) toast(context, 'Saved. You\'ll be asked to verify each payment on the day.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(standingProvider);
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final items = async.value ?? const [];

    final how = [
      'On the due day at 08:00 your agent prepares the payment and finds the cheapest route.',
      'You get a notification: verify to complete the payment.',
      'Nothing is sent until you verify with your fingerprint. Not verified in 24 h? It\'s cancelled.',
    ];

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
                    Glass(
                      level: GlassLevel.heavy,
                      radius: 26,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('How it works', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 10),
                          for (final (i, line) in how.indexed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 22,
                                    height: 22,
                                    alignment: Alignment.center,
                                    decoration: const BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
                                    child: Text(
                                      '${i + 1}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      line,
                                      style: const TextStyle(fontSize: 12.5, height: 1.45, color: Color(0xFF3A3A3A)),
                                    ),
                                  ),
                                ],
                              ),
                            ).animate().fadeIn(delay: (100 + i * 90).ms).slideX(begin: .04, delay: (100 + i * 90).ms),
                        ],
                      ),
                    ).enter(0),
                    const SizedBox(height: 12),
                    if (async.isLoading && async.value == null)
                      const Skeleton(height: 80, radius: 24)
                    else if (items.isEmpty)
                      Glass(
                        padding: const EdgeInsets.all(20),
                        child: const Text(
                          'No standing instructions yet. Set one up for rent or family support.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: AppColors.muted),
                        ),
                      ).enter(1)
                    else
                      for (final (i, si) in items.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _Item(
                            si: si,
                            on: _optimistic[si['id']] ?? si['active'] == true,
                            onToggle: (v) => _toggle(si, v),
                          ).enter(i + 1),
                        ),
                    const SizedBox(height: 4),
                    Glass(
                      radius: 22,
                      padding: const EdgeInsets.all(14),
                      child: const Row(
                        children: [
                          Icon(LucideIcons.sparkles, size: 16),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Or just tell your agent: "every month send 1,000 CNY to father on the 3rd"',
                              style: TextStyle(fontSize: 12.5, color: Color(0xFF3A3A3A), height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ).enter(items.length + 1),
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
                    onTap: () => context.canPop() ? context.pop() : context.go('/profile'),
                  ),
                  const Expanded(
                    child: Text(
                      'Standing instructions',
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
              child: PrimaryButton(
                label: 'New standing instruction',
                icon: LucideIcons.plus,
                onTap: _add,
              ).animate().fadeIn(delay: 250.ms).slideY(begin: .4, delay: 250.ms, curve: AppMotion.smooth),
            ),
          ],
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.si, required this.on, required this.onToggle});
  final Map<String, dynamic> si;
  final bool on;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final next = _nextDate(si);
    final name = si['recipient'] as String? ?? '';
    final rel = si['relationship'] as String?;
    return AnimatedOpacity(
      duration: AppMotion.base,
      opacity: on ? 1 : .6,
      child: Glass(
        radius: 24,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: .9), shape: BoxShape.circle),
              child: Text(
                name.isEmpty ? '?' : name[0],
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${money(si['amount'] as num, si['currency'] as String)} to $name',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (rel != null) _cap(rel),
                      'every month on the ${_ordinal(si['day_of_month'] as int)}',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                  const SizedBox(height: 2),
                  AnimatedSwitcher(
                    duration: AppMotion.fast,
                    child: Text(
                      key: ValueKey(on),
                      on
                          ? 'Next: ${next.day} ${_months[next.month - 1]} · you\'ll verify it'
                          : 'Paused · nothing will be prepared',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: on ? AppColors.ink : AppColors.muted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Semantics(
              toggled: on,
              label: 'Active',
              child: _Switch(on: on, onChanged: onToggle),
            ),
          ],
        ),
      ),
    );
  }
}

/// Monochrome iOS-style switch with a springy knob.
class _Switch extends StatelessWidget {
  const _Switch({required this.on, required this.onChanged});
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => onChanged(!on),
    child: AnimatedContainer(
      duration: AppMotion.base,
      curve: AppMotion.smooth,
      width: 50,
      height: 30,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: on ? AppColors.ink : Colors.black.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: AnimatedAlign(
        duration: AppMotion.base,
        curve: AppMotion.spring,
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: .15), blurRadius: 4, offset: const Offset(0, 1)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Sheet: who, how much, which day. Returns true when saved.
class NewStandingSheet extends ConsumerStatefulWidget {
  const NewStandingSheet({super.key});
  @override
  ConsumerState<NewStandingSheet> createState() => _NewStandingSheetState();
}

class _NewStandingSheetState extends ConsumerState<NewStandingSheet> {
  final _amount = TextEditingController();
  List<Map<String, dynamic>>? _recipients;
  String? _recipient;
  int _day = 1;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ref
        .read(apiProvider)
        .get('/payees')
        .then((r) {
          if (!mounted) return;
          setState(() {
            _recipients = [for (final p in (r as Map)['recipients'] as List) Map<String, dynamic>.from(p)];
            _recipient = _recipients!.firstOrNull?['name'] as String?;
          });
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = '$e');
        });
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.replaceAll(',', ''));
    if (_recipient == null || amount == null || amount <= 0) {
      setState(() => _error = 'Choose a recipient and enter an amount');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).post('/standing-instructions', {
        'recipient': _recipient,
        'amount': amount,
        'day_of_month': _day,
        'currency': ref.read(sessionProvider).user?['study_currency'],
      });
      if (mounted) context.pop(true);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = ref.watch(sessionProvider).user?['study_currency'] as String? ?? 'CNY';
    return GlassSheet(
      title: 'New standing instruction',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 6),
            child: Text('Who', style: TextStyle(fontSize: 12, color: AppColors.muted)),
          ),
          if (_recipients == null)
            const Skeleton(height: 40, radius: 20)
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in _recipients!)
                  ChoiceChip2(
                    label: p['relationship'] != null ? '${p['name']} · ${p['relationship']}' : p['name'] as String,
                    selected: p['name'] == _recipient,
                    onTap: () => setState(() => _recipient = p['name'] as String),
                  ),
              ],
            ),
          const SizedBox(height: 14),
          GlassField(
            label: 'Amount ($currency)',
            controller: _amount,
            hint: '1,500',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              'Day of the month · the ${_ordinal(_day)}',
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: 28,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) => Pressable(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _day = i + 1);
                },
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  width: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _day == i + 1 ? AppColors.ink : Colors.white.withValues(alpha: .85),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _day == i + 1 ? Colors.white : AppColors.ink,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .7),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.fingerprint, size: 16),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'The agent prepares it on that day and asks you to verify. It is never paid automatically.',
                    style: TextStyle(fontSize: 12, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(fontSize: 13, color: AppColors.danger)),
          ],
          const SizedBox(height: 14),
          PrimaryButton(label: 'Save', loading: _busy, onTap: _save),
        ],
      ),
    );
  }
}
