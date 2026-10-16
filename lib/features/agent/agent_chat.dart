import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api.dart';
import '../../core/session.dart';

const _storage = FlutterSecureStorage();
const _sessionKey = 'agent_session';

/// One line in the conversation. Agent messages carry the tool results the agent produced
/// (a prepared payment, a scam check, balances...), which the screen draws as cards.
class ChatItem {
  const ChatItem({required this.fromUser, required this.text, this.actions = const [], this.failed = false});
  final bool fromUser;
  final String text;
  final List<Map<String, dynamic>> actions;
  final bool failed; // the request never reached the agent; offer a retry
}

class AgentChat {
  const AgentChat({this.sessionId, this.items = const [], this.thinking = false, this.restored = false});
  final String? sessionId;
  final List<ChatItem> items;
  final bool thinking;
  final bool restored; // history for a saved session has been loaded

  AgentChat copyWith({String? sessionId, List<ChatItem>? items, bool? thinking, bool? restored}) => AgentChat(
    sessionId: sessionId ?? this.sessionId,
    items: items ?? this.items,
    thinking: thinking ?? this.thinking,
    restored: restored ?? this.restored,
  );
}

class AgentChatController extends Notifier<AgentChat> {
  String? _lastHandOver; // token of the last prompt handed over from another screen, so each is sent once
  Future<void> _ready = Future.value(); // saved history finished loading

  @override
  AgentChat build() {
    // A different student (or a sign-out) starts from a clean conversation.
    ref.watch(sessionProvider.select((s) => s.token));
    _ready = _restore();
    return const AgentChat();
  }

  Api get _api => ref.read(apiProvider);

  Future<void> _restore() async {
    final id = await _storage.read(key: _sessionKey);
    if (id == null) {
      state = state.copyWith(restored: true);
      return;
    }
    try {
      final rows = await _api.get('/agent/sessions/$id/messages') as List;
      state = state.copyWith(
        sessionId: id,
        restored: true,
        items: [
          for (final m in rows)
            ChatItem(
              fromUser: m['role'] == 'user',
              text: m['content'] as String? ?? '',
              actions: [for (final a in m['actions'] as List? ?? const []) Map<String, dynamic>.from(a)],
            ),
        ],
      );
    } on ApiError {
      state = state.copyWith(restored: true);
    }
  }

  Future<void> send(String text) async {
    text = text.trim();
    if (text.isEmpty || state.thinking) return;
    await _ready;
    state = state.copyWith(
      thinking: true,
      items: [
        ...state.items,
        ChatItem(fromUser: true, text: text),
      ],
    );
    try {
      final res = await _api.post('/agent/chat', {'message': text, 'session_id': state.sessionId});
      final id = res['session_id'] as String;
      if (id != state.sessionId) await _storage.write(key: _sessionKey, value: id);
      state = state.copyWith(
        sessionId: id,
        thinking: false,
        items: [
          ...state.items,
          ChatItem(
            fromUser: false,
            text: res['reply'] as String? ?? '',
            actions: [for (final a in res['actions'] as List? ?? const []) Map<String, dynamic>.from(a)],
          ),
        ],
      );
    } on ApiError catch (e) {
      state = state.copyWith(
        thinking: false,
        items: [
          ...state.items,
          ChatItem(fromUser: false, text: e.message, failed: true),
        ],
      );
    }
  }

  /// Sends the last student message again after a failed request.
  Future<void> retry() async {
    final items = [...state.items];
    if (items.isEmpty || !items.last.failed) return;
    items.removeLast();
    final last = items.removeLast();
    state = state.copyWith(items: items);
    await send(last.text);
  }

  /// Sends a prompt passed in from another screen ("Pay with agent" on Home) exactly once per tap.
  void handOver(String prompt, String token) {
    if (token == _lastHandOver) return;
    _lastHandOver = token;
    send(prompt);
  }

  /// Reflects a decision made on the verify sheet (VERIFIED / REJECTED) in the chat's payment cards.
  void markAction(int actionId, String status) {
    state = state.copyWith(
      items: [
        for (final item in state.items)
          item.actions.any((a) => a['action_id'] == actionId)
              ? ChatItem(
                  fromUser: item.fromUser,
                  text: item.text,
                  failed: item.failed,
                  actions: [
                    for (final a in item.actions) a['action_id'] == actionId ? {...a, 'status': status} : a,
                  ],
                )
              : item,
      ],
    );
  }

  Future<void> newChat() async {
    await _storage.delete(key: _sessionKey);
    state = const AgentChat(restored: true);
  }
}

final agentChatProvider = NotifierProvider<AgentChatController, AgentChat>(AgentChatController.new);

/// The opening line: the agent speaks first about whatever needs attention.
final agentOpenerProvider = FutureProvider.autoDispose<Map<String, dynamic>?>((ref) async {
  final reminders = await ref.watch(apiProvider).get('/tuition/reminders') as List;
  return reminders.isEmpty ? null : Map<String, dynamic>.from(reminders.first);
}, retry: (_, _) => null);
