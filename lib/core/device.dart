import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'session.dart';

const _storage = FlutterSecureStorage();

/// Why a verification could not go ahead, in words the student can act on.
class VerifyProblem implements Exception {
  VerifyProblem(this.message, {this.cancelled = false, this.needsFingerprint = false});
  final String message;
  final bool cancelled; // the student closed the fingerprint prompt: not an error
  final bool needsFingerprint; // no fingerprint enrolled on this phone yet
  @override
  String toString() => message;
}

/// The Kotlin side (MainActivity): a hardware-backed P-256 key that only fingerprint unlock can use.
class Keystore {
  static const _ch = MethodChannel('moneymate/keystore');

  Future<String> status() async => await _ch.invokeMethod<String>('status') ?? 'unavailable';
  Future<String> publicKey() async => (await _ch.invokeMethod<String>('publicKey'))!;
  Future<String> sign(String challenge, String reason) async =>
      (await _ch.invokeMethod<String>('sign', {'challenge': challenge, 'reason': reason}))!;
  Future<void> reset() => _ch.invokeMethod('reset');
  Future<void> openEnroll() => _ch.invokeMethod('openEnroll');
}

/// Registers this phone's payment key with the backend once, then signs payment challenges with it.
class DeviceVerifier {
  DeviceVerifier(this._api, this._userId);
  final Api _api;
  final Object? _userId;
  final keystore = Keystore();

  String get _key => 'device_id_$_userId';

  Future<int> _deviceId() async {
    final saved = await _storage.read(key: _key);
    if (saved != null) return int.parse(saved);
    final String publicKey;
    try {
      publicKey = await keystore.publicKey();
    } on PlatformException catch (e) {
      throw VerifyProblem(e.message ?? 'Set up fingerprint unlock first', needsFingerprint: true);
    }
    final res = await _api.post('/devices', {'name': 'Android phone', 'key_type': 'p256', 'public_key': publicKey});
    final id = res['id'] as int;
    await _storage.write(key: _key, value: '$id');
    return id;
  }

  /// Fingerprint → signature over the one-time challenge → backend verifies and settles the payment.
  Future<Map<String, dynamic>> verify(int actionId) async {
    final status = await keystore.status();
    if (status == 'none_enrolled') {
      throw VerifyProblem('Add a fingerprint to this phone to verify payments.', needsFingerprint: true);
    }
    if (status != 'ready') throw VerifyProblem('This phone has no fingerprint sensor MoneyMate can use.');

    final deviceId = await _deviceId();
    final ch = await _api.get('/agent/actions/$actionId/challenge');
    final String signature;
    try {
      signature = await keystore.sign(ch['challenge'] as String, ch['summary'] as String);
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') throw VerifyProblem('Verification cancelled', cancelled: true);
      if (e.code == 'KEY_INVALID') await _forget(resetKey: true);
      throw VerifyProblem(e.message ?? 'Fingerprint check failed');
    }
    try {
      final res = await _api.post('/agent/actions/$actionId/verify', {'device_id': deviceId, 'signature': signature});
      return Map<String, dynamic>.from(res);
    } on ApiError catch (e) {
      // 403: the backend no longer knows this phone or its key. Register again on the next try.
      if (e.status == 403) {
        await _forget();
        throw VerifyProblem('This phone needs to be registered again. Tap verify once more.');
      }
      rethrow;
    }
  }

  Future<void> _forget({bool resetKey = false}) async {
    await _storage.delete(key: _key);
    if (resetKey) await keystore.reset();
  }
}

final deviceVerifierProvider = Provider<DeviceVerifier>(
  (ref) => DeviceVerifier(ref.watch(apiProvider), ref.watch(sessionProvider.select((s) => s.user?['id']))),
);
