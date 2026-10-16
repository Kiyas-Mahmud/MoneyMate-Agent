import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/session.dart';

/// Everything the Home screen shows, fetched in one go.
class HomeData {
  HomeData({
    required this.wallet,
    required this.reminders,
    required this.recent,
    required this.pending,
    required this.unread,
    required this.relationships,
  });

  final Map<String, dynamic> wallet;
  final List<Map<String, dynamic>> reminders;
  final List<Map<String, dynamic>> recent;
  final List<Map<String, dynamic>> pending; // payments waiting for the student's verification
  final int unread;
  final Map<String, String> relationships; // payee name -> "mother", "landlord", ...

  double get totalUsd => (wallet['total_usd'] as num).toDouble();
  List<Map<String, dynamic>> get balances => _maps(wallet['balances']);
  String get ratesAsOf {
    // "Fri, 16 Oct 2026 00:02:31 +0000" -> "16 Oct"
    final parts = (wallet['rates_as_of'] as String? ?? '').split(' ');
    return parts.length >= 3 ? '${parts[1]} ${parts[2]}' : '';
  }

  bool get liveRates => (wallet['rates_source'] as String? ?? '').startsWith('live');

  /// The open invoice that needs attention first, if any.
  Map<String, dynamic>? get tuition => reminders.isEmpty ? null : reminders.first;

  /// Second line of a Recent row: "From father · 9 Oct", "To mother · RemitLite · 7 Oct".
  String describe(Map<String, dynamic> tx) {
    final rel = relationships[tx['counterparty']];
    final what = switch (tx['kind']) {
      'REMITTANCE_IN' => rel != null ? 'From $rel' : 'Received',
      'REMITTANCE_OUT' =>
        rel == 'landlord'
            ? 'Rent'
            : rel != null
            ? 'To $rel'
            : 'Transfer',
      'TUITION' => 'Tuition',
      'FX' => 'Conversion',
      'CARD' => 'Card',
      _ => (tx['kind'] as String).toLowerCase(),
    };
    return [
      what,
      if (tx['provider'] != null && tx['kind'] != 'FX') tx['provider'],
      shortDate(tx['created_at']),
    ].join(' · ');
  }
}

List<Map<String, dynamic>> _maps(dynamic list) => [for (final e in list as List) Map<String, dynamic>.from(e)];

final homeProvider = FutureProvider.autoDispose<HomeData>((ref) async {
  final api = ref.watch(apiProvider);
  final r = await Future.wait([
    api.get('/wallet'),
    api.get('/tuition/reminders'),
    api.get('/transactions', query: {'limit': 12}),
    api.get('/agent/actions', query: {'status': 'AWAITING_VERIFICATION'}),
    api.get('/notifications'),
    api.get('/payees'),
    api.get('/auth/me'),
  ]);
  // Keep the cached profile (name in the header, home currency) in step with the server.
  await ref.read(sessionProvider.notifier).setUser(Map<String, dynamic>.from(r[6]));
  final payees = Map<String, dynamic>.from(r[5]);
  return HomeData(
    wallet: Map<String, dynamic>.from(r[0]),
    reminders: _maps(r[1]),
    // Only money that actually moved; parked payments show in the verification pill instead.
    recent: _maps(r[2]).where((t) => t['status'] == 'COMPLETED').take(3).toList(),
    pending: _maps(r[3]),
    unread: _maps(r[4]).where((n) => n['read'] != true).length,
    relationships: {
      for (final p in _maps(payees['recipients']))
        if (p['relationship'] != null) p['name'] as String: p['relationship'] as String,
    },
  );
}, retry: (_, _) => null);
