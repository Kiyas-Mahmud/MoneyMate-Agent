import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _storage = FlutterSecureStorage();

class Session {
  const Session({this.token, this.user, this.ready = false, this.onboarded = false});
  final String? token;
  final Map<String, dynamic>? user;
  final bool ready; // storage has been read
  final bool onboarded; // welcome slides seen

  bool get signedIn => token != null;
  String get firstName => (user?['full_name'] as String? ?? '').split(' ').first;

  Session copyWith({String? token, Map<String, dynamic>? user, bool? ready, bool? onboarded, bool clear = false}) =>
      Session(
        token: clear ? null : token ?? this.token,
        user: clear ? null : user ?? this.user,
        ready: ready ?? this.ready,
        onboarded: onboarded ?? this.onboarded,
      );
}

class SessionController extends Notifier<Session> {
  @override
  Session build() {
    _restore();
    return const Session();
  }

  Future<void> _restore() async {
    final token = await _storage.read(key: 'token');
    final onboarded = await _storage.read(key: 'onboarded') == '1';
    final saved = await _storage.read(key: 'user');
    final user = saved == null ? null : Map<String, dynamic>.from(jsonDecode(saved));
    state = state.copyWith(token: token, user: user, ready: true, onboarded: onboarded);
  }

  Future<void> signIn(String token, Map<String, dynamic> user) async {
    await _storage.write(key: 'token', value: token);
    await _storage.write(key: 'user', value: jsonEncode(user));
    state = state.copyWith(token: token, user: user);
  }

  Future<void> setUser(Map<String, dynamic> user) async {
    await _storage.write(key: 'user', value: jsonEncode(user));
    state = state.copyWith(user: user);
  }

  Future<void> finishOnboarding() async {
    await _storage.write(key: 'onboarded', value: '1');
    state = state.copyWith(onboarded: true);
  }

  Future<void> signOut() async {
    await _storage.delete(key: 'token');
    await _storage.delete(key: 'user');
    state = state.copyWith(clear: true);
  }
}

final sessionProvider = NotifierProvider<SessionController, Session>(SessionController.new);
