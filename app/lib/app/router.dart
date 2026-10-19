import 'package:flutter/material.dart' show ChangeNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/session.dart';
import '../features/activity/activity.dart';
import '../features/activity/integrity_sheet.dart';
import '../features/activity/tx_sheet.dart';
import '../features/agent/agent.dart';
import '../features/auth/login.dart';
import '../features/auth/onboarding.dart';
import '../features/auth/register.dart';
import '../features/auth/splash.dart';
import '../features/funds/request_money.dart';
import '../features/history/history.dart';
import '../features/home/home.dart';
import '../features/notifications/notifications.dart';
import '../features/pay/pay_menu.dart';
import '../features/profile/profile.dart';
import '../features/rates/rates.dart';
import '../features/receipt/receipt.dart';
import '../features/safety/safety.dart';
import '../features/scam/scam_input.dart';
import '../features/scam/scam_result.dart';
import '../features/send/add_recipient.dart';
import '../features/send/send_money.dart';
import '../features/send/sent.dart';
import '../features/standing/standing.dart';
import '../features/tuition/tuition.dart';
import '../features/verify/verify.dart';
import '../features/wallet/wallet.dart';
import 'shell.dart';
import 'transitions.dart';

const _authPages = {'/onboarding', '/login', '/register'};

/// Lets GoRouter re-run its redirect whenever the session changes (sign in, sign out, restore).
class _SessionRefresh extends ChangeNotifier {
  void ping() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _SessionRefresh();
  ref.listen(sessionProvider, (_, _) => refresh.ping());
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final s = ref.read(sessionProvider);
      final loc = state.uri.path;
      if (!s.ready) return loc == '/splash' ? null : '/splash';
      if (!s.signedIn) {
        if (_authPages.contains(loc)) return null;
        return s.onboarded ? '/login' : '/onboarding';
      }
      if (_authPages.contains(loc) || loc == '/splash') return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', pageBuilder: (c, s) => fadeThroughPage(s, const SplashScreen())),
      GoRoute(path: '/onboarding', pageBuilder: (c, s) => fadeThroughPage(s, const OnboardingScreen())),
      GoRoute(path: '/login', pageBuilder: (c, s) => fadeThroughPage(s, const LoginScreen())),
      GoRoute(path: '/register', pageBuilder: (c, s) => sharedAxisPage(s, const RegisterScreen())),
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(path: '/home', pageBuilder: (c, s) => fadeThroughPage(s, const HomeScreen())),
          GoRoute(
            path: '/agent',
            pageBuilder: (c, s) => fadeThroughPage(
              s,
              AgentScreen(prompt: s.uri.queryParameters['prompt'], promptToken: s.uri.queryParameters['at']),
            ),
          ),
          GoRoute(path: '/activity', pageBuilder: (c, s) => fadeThroughPage(s, const ActivityScreen())),
          GoRoute(path: '/profile', pageBuilder: (c, s) => fadeThroughPage(s, const ProfileScreen())),
        ],
      ),
      GoRoute(path: '/pay', pageBuilder: (c, s) => sheetPage(s, const PayMenu())),
      GoRoute(
        path: '/send',
        pageBuilder: (c, s) => sharedAxisPage(s, SendMoneyScreen(to: s.uri.queryParameters['to'])),
      ),
      GoRoute(path: '/recipients/new', pageBuilder: (c, s) => sheetPage(s, const AddRecipientSheet())),
      GoRoute(
        path: '/sent/:id',
        pageBuilder: (c, s) => fadeThroughPage(s, SentScreen(txId: int.parse(s.pathParameters['id']!))),
      ),
      GoRoute(
        path: '/tx',
        pageBuilder: (c, s) => s.extra is Map
            ? sheetPage(s, TransactionSheet(tx: Map<String, dynamic>.from(s.extra as Map)))
            : fadeThroughPage(s, const ActivityScreen()),
      ),
      GoRoute(path: '/history', pageBuilder: (c, s) => sharedAxisPage(s, const HistoryScreen())),
      GoRoute(path: '/integrity', pageBuilder: (c, s) => sheetPage(s, const IntegritySheet())),
      GoRoute(path: '/standing', pageBuilder: (c, s) => sharedAxisPage(s, const StandingScreen())),
      GoRoute(path: '/standing/new', pageBuilder: (c, s) => sheetPage(s, const NewStandingSheet())),
      GoRoute(path: '/protection', pageBuilder: (c, s) => sheetPage(s, const ProtectionSheet())),
      GoRoute(
        path: '/safety',
        pageBuilder: (c, s) => sharedAxisPage(
          s,
          SafetyScreen(
            txId: int.tryParse(s.uri.queryParameters['tx'] ?? ''),
            actionId: int.tryParse(s.uri.queryParameters['action'] ?? ''),
          ),
        ),
      ),
      GoRoute(path: '/scam', pageBuilder: (c, s) => sharedAxisPage(s, const ScamInputScreen())),
      GoRoute(
        path: '/scam/result',
        pageBuilder: (c, s) =>
            sharedAxisPage(s, s.extra is String ? ScamResultScreen(text: s.extra as String) : const ScamInputScreen()),
      ),
      GoRoute(
        path: '/verify/:id',
        pageBuilder: (c, s) => sheetPage(s, VerifySheet(actionId: int.parse(s.pathParameters['id']!))),
      ),
      GoRoute(
        path: '/receipt/:id',
        pageBuilder: (c, s) => sharedAxisPage(s, ReceiptScreen(txId: int.parse(s.pathParameters['id']!))),
      ),
      GoRoute(path: '/tuition', pageBuilder: (c, s) => sharedAxisPage(s, const TuitionScreen())),
      GoRoute(
        path: '/wallet',
        pageBuilder: (c, s) => sharedAxisPage(
          s,
          WalletScreen(
            from: s.uri.queryParameters['from'],
            to: s.uri.queryParameters['to'],
            receive: double.tryParse(s.uri.queryParameters['receive'] ?? ''),
          ),
        ),
      ),
      GoRoute(path: '/rates', pageBuilder: (c, s) => sharedAxisPage(s, const RatesScreen())),
      GoRoute(
        path: '/request',
        pageBuilder: (c, s) => sharedAxisPage(
          s,
          RequestMoneyScreen(
            amount: double.tryParse(s.uri.queryParameters['amount'] ?? ''),
            reason: s.uri.queryParameters['reason'],
          ),
        ),
      ),
      GoRoute(path: '/notifications', pageBuilder: (c, s) => sharedAxisPage(s, const NotificationsScreen())),
    ],
  );
});
