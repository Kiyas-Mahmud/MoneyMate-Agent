import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/orb.dart';
import '../../widgets/pressable.dart';
import '../../widgets/ui.dart';
import 'action_cards.dart';
import 'agent_chat.dart';

class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key, this.prompt, this.promptToken});
  final String? prompt; // handed over from another screen, e.g. "Pay my Spring 2027 tuition"
  final String? promptToken;

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  late int _animateFrom = ref.read(agentChatProvider).items.length; // only new messages slide in

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _toBottom(jump: true);
      _takePrompt();
    });
  }

  @override
  void didUpdateWidget(AgentScreen old) {
    super.didUpdateWidget(old);
    if (widget.promptToken != old.promptToken) _takePrompt();
  }

  void _takePrompt() {
    final p = widget.prompt;
    if (p != null && p.isNotEmpty) ref.read(agentChatProvider.notifier).handOver(p, widget.promptToken ?? p);
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      jump ? _scroll.jumpTo(end) : _scroll.animateTo(end, duration: AppMotion.slow, curve: AppMotion.smooth);
    });
  }

  void _send([String? text]) {
    final msg = text ?? _input.text;
    if (msg.trim().isEmpty) return;
    if (text == null) _input.clear();
    ref.read(agentChatProvider.notifier).send(msg);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(agentChatProvider, (prev, next) {
      if (prev?.items.length != next.items.length || prev?.thinking != next.thinking) _toBottom();
      if (prev != null && !prev.restored && next.restored) {
        _animateFrom = next.items.length;
        _toBottom(jump: true);
      }
    });
    final chat = ref.watch(agentChatProvider);
    final user = ref.watch(sessionProvider).user ?? const {};
    final opener = ref.watch(agentOpenerProvider).value;
    final top = MediaQuery.paddingOf(context).top;
    final keyboard = View.of(context).viewInsets.bottom > 0;
    final inputBottom = keyboard ? 10.0 : 90.0 + MediaQuery.paddingOf(context).bottom;

    final rows = <Widget>[
      _AgentLine(child: Text(_openerText(opener, user))),
      if (chat.items.isEmpty && chat.restored)
        _Suggestions(
          study: user['study_currency'] as String? ?? 'CNY',
          onSend: _send,
          onCheckMessage: () => context.push('/scam'),
        ),
      for (final (i, item) in chat.items.indexed)
        _animated(
          i,
          _ItemView(
            item: item,
            initial: (user['full_name'] as String? ?? ' ')[0],
            onRetry: () => ref.read(agentChatProvider.notifier).retry(),
            officialWay: opener == null ? null : () => _send('Pay my ${opener['semester']} tuition'),
            officialAmount: opener == null ? null : money(opener['amount'] as num, opener['currency'] as String),
          ),
        ),
      if (chat.thinking) const _Thinking(),
    ];

    return GestureDetector(
      onTap: () => _focus.unfocus(),
      child: Stack(
        children: [
          TopFade(
            child: ListView.separated(
              controller: _scroll,
              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              padding: EdgeInsets.fromLTRB(16, top + 72, 16, inputBottom + 76),
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) => rows[i],
            ),
          ),
          Positioned(
            top: top + 8,
            left: 16,
            right: 16,
            child: Row(
              children: [
                const Glass(
                  level: GlassLevel.heavy,
                  radius: AppRadius.pill,
                  padding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Orb(height: 16),
                      SizedBox(width: 8),
                      Text('MoneyMate', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                const Spacer(),
                if (chat.items.isNotEmpty)
                  Semantics(
                    button: true,
                    label: 'New chat',
                    child: Pressable(
                      scale: .9,
                      onTap: () {
                        _animateFrom = 0;
                        ref.read(agentChatProvider.notifier).newChat();
                      },
                      child: const Glass(
                        level: GlassLevel.heavy,
                        radius: 22,
                        child: SizedBox(width: 44, height: 44, child: Icon(LucideIcons.squarePen, size: 19)),
                      ),
                    ),
                  ).animate().fadeIn(duration: AppMotion.fast).scaleXY(begin: .8, curve: AppMotion.spring),
              ],
            ).animate().fadeIn(duration: AppMotion.base).slideY(begin: -.3, curve: AppMotion.smooth),
          ),
          AnimatedPositioned(
            duration: AppMotion.fast,
            curve: AppMotion.smooth,
            left: 16,
            right: 16,
            bottom: inputBottom,
            child: _InputBar(controller: _input, focus: _focus, busy: chat.thinking, onSend: _send),
          ),
        ],
      ),
    );
  }

  Widget _animated(int index, Widget child) => index < _animateFrom
      ? child
      : child
            .animate()
            .fadeIn(duration: AppMotion.base, curve: AppMotion.smooth)
            .slideY(begin: .15, duration: AppMotion.base, curve: AppMotion.smooth);

  String _openerText(Map<String, dynamic>? t, Map user) {
    final first = (user['full_name'] as String? ?? '').split(' ').first;
    if (t == null) return 'Hi $first. What can I do for you?';
    final days = t['days_left'] as int;
    final when = days < 0
        ? 'is overdue'
        : days == 0
        ? 'is due today'
        : 'is due in $days day${days == 1 ? '' : 's'}';
    final short = (t['shortfall'] as num) > 0
        ? ' You\'re ${money(t['shortfall'] as num, t['currency'] as String)} short.'
        : '';
    return 'Your tuition $when.$short';
  }
}

/// Agent avatar + glass bubble.
class _AgentLine extends StatelessWidget {
  const _AgentLine({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const OrbAvatar(),
      const SizedBox(width: 8),
      Flexible(
        child: Glass(
          radius: 20,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 14, height: 1.45), child: child),
        ),
      ),
      const SizedBox(width: 24),
    ],
  );
}

class _ItemView extends StatelessWidget {
  const _ItemView({
    required this.item,
    required this.initial,
    required this.onRetry,
    this.officialWay,
    this.officialAmount,
  });
  final ChatItem item;
  final String initial;
  final VoidCallback onRetry;
  final VoidCallback? officialWay;
  final String? officialAmount;

  @override
  Widget build(BuildContext context) {
    if (item.fromUser) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const SizedBox(width: 48),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.ink,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(6),
                ),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: .14), blurRadius: 20, offset: const Offset(0, 8)),
                ],
              ),
              child: Text(item.text, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.45)),
            ),
          ),
          const SizedBox(width: 8),
          Glass(
            radius: 16,
            child: SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child: Text(initial.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      );
    }

    if (item.failed) {
      return _AgentLine(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.text, style: const TextStyle(color: AppColors.danger)),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: onRetry,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.refreshCw, size: 14),
                  SizedBox(width: 6),
                  Text('Try again', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final plan = item.actions.expand((a) => (a['plan'] as List?) ?? const []).cast<Map>();
    final converts = plan.any((p) => p['step'] == 'convert');
    final cards = [for (final a in item.actions) ?actionCard(a)];
    final scam = item.actions.any((a) => a['tool'] == 'analyze_payment_request' && a['verdict'] == 'LIKELY_SCAM');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AgentLine(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.text),
              if (converts)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .85),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.listChecks, size: 13, color: Color(0xFF3A3A3A)),
                      SizedBox(width: 6),
                      Text(
                        'Plan: convert, then pay · one verification',
                        style: TextStyle(fontSize: 11, color: Color(0xFF3A3A3A)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        for (final (i, c) in cards.indexed)
          Padding(
            padding: const EdgeInsets.only(left: 40, top: 12),
            child: c
                .animate()
                .fadeIn(delay: (200 + i * 120).ms, duration: AppMotion.base)
                .slideY(begin: .08, delay: (200 + i * 120).ms, duration: AppMotion.base, curve: AppMotion.smooth),
          ),
        // After a scam, offer the safe route straight away.
        if (scam && officialWay != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                const OrbAvatar(),
                const SizedBox(width: 8),
                Pressable(
                  onTap: officialWay,
                  child: Glass(
                    radius: AppRadius.pill,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Pay $officialAmount the official way', style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 8),
                        const Icon(LucideIcons.arrowRight, size: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ).animate().fadeIn(delay: 600.ms, duration: AppMotion.base).slideY(begin: .2, delay: 600.ms),
          ),
      ],
    );
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.study, required this.onSend, required this.onCheckMessage});
  final String study;
  final ValueChanged<String> onSend;
  final VoidCallback onCheckMessage;

  @override
  Widget build(BuildContext context) {
    final chips = <(String, VoidCallback)>[
      ('Pay tuition', () => onSend('Pay my tuition')),
      ('Send home', () => onSend('Compare fees to send 1000 $study home')),
      ('Check a message', onCheckMessage),
      ('My balance', () => onSend('What is my balance?')),
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 40),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final (i, (label, onTap)) in chips.indexed)
            Pressable(
                  onTap: onTap,
                  child: Glass(
                    radius: AppRadius.pill,
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                    child: Text(label, style: const TextStyle(fontSize: 13)),
                  ),
                )
                .animate()
                .fadeIn(delay: (150 + i * 70).ms, duration: AppMotion.base)
                .scaleXY(begin: .85, delay: (150 + i * 70).ms, duration: AppMotion.base, curve: AppMotion.spring),
        ],
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) => const _AgentLine(
    child: SizedBox(
      height: 20,
      child: Align(alignment: Alignment.centerLeft, child: Orb(height: 14)),
    ),
  ).animate().fadeIn(duration: AppMotion.fast).slideY(begin: .2, curve: AppMotion.smooth);
}

class _InputBar extends StatelessWidget {
  const _InputBar({required this.controller, required this.focus, required this.busy, required this.onSend});
  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final ready = controller.text.trim().isNotEmpty && !busy;
    return Glass(
      level: GlassLevel.heavy,
      radius: 28,
      padding: const EdgeInsets.fromLTRB(18, 4, 6, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focus,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontSize: 14, height: 1.4),
              decoration: const InputDecoration(
                hintText: 'Ask MoneyMate',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Semantics(
              button: true,
              label: 'Send',
              child: Pressable(
                onTap: ready ? onSend : null,
                scale: .88,
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  curve: AppMotion.smooth,
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: ready ? AppColors.ink : Colors.black.withValues(alpha: .06),
                    shape: BoxShape.circle,
                  ),
                  child: AnimatedSwitcher(
                    duration: AppMotion.fast,
                    child: busy
                        ? const Padding(
                            key: ValueKey('b'),
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted),
                          )
                        : Icon(
                            LucideIcons.arrowUp,
                            key: const ValueKey('s'),
                            size: 19,
                            color: ready ? Colors.white : AppColors.hint,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
