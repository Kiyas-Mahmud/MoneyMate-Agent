import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneymate/features/agent/action_cards.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  testWidgets('a prepared tuition payment asks for verification and shows the convert-then-pay plan', (tester) async {
    final card = actionCard({
      'tool': 'pay_tuition',
      'status': 'AWAITING_VERIFICATION',
      'action_id': 7,
      'payee_verification': {'status': 'VERIFIED'},
      'invoice': {'semester': 'Spring 2027', 'due_date': '2026-10-22'},
      'plan': [
        {'step': 'convert', 'amount': 148543.49, 'from': 'BDT', 'receive': 8000.0, 'to': 'CNY'},
        {'step': 'pay', 'amount': 26000.0, 'currency': 'CNY'},
      ],
      'risk': {'score': 0.013, 'level': 'LOW', 'reasons': []},
      'transaction': {
        'kind': 'TUITION', 'amount': 26000.0, 'currency': 'CNY',
        'counterparty': 'Pearl River University (Shenzhen)', 'fee': 0.0,
      },
    });
    expect(card, isNotNull);
    await tester.pumpWidget(_host(card!));
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('Verified account'), findsOneWidget);
    expect(find.text('¥26,000'), findsOneWidget);
    expect(find.textContaining('First converts ৳148,543'), findsOneWidget);
    expect(find.text('Review and verify'), findsOneWidget);
    expect(find.text('Low · 1%'), findsOneWidget);
  });

  testWidgets('a blocked payment shows no verify button and lists the reasons', (tester) async {
    final card = actionCard({
      'tool': 'send_remittance',
      'status': 'BLOCKED',
      'action_id': 9,
      'policy': {'rules': ['Money-mule pattern: forwarding money just received from a first-time sender']},
      'risk': {'score': 0.99, 'level': 'HIGH', 'reasons': [{'text': 'Amount is 30.3x your usual payment'}]},
      'transaction': {
        'kind': 'REMITTANCE_OUT', 'amount': 27000.0, 'currency': 'CNY', 'counterparty': 'Kevin Tan', 'fee': 13.41,
        'memo': 'Recipient gets 16,288.41 MYR', 'provider': 'RemitLite',
      },
    });
    await tester.pumpWidget(_host(card!));
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('Blocked'), findsOneWidget);
    expect(find.text('Review and verify'), findsNothing);
    expect(find.textContaining('Money-mule pattern'), findsOneWidget);
    expect(find.text('High · 99%'), findsOneWidget);
  });

  testWidgets('a scam check strikes out the amount and explains the flags', (tester) async {
    final card = actionCard({
      'tool': 'analyze_payment_request',
      'verdict': 'LIKELY_SCAM',
      'red_flags': [
        {'explanation': 'Pushes you to pay immediately'},
        {'explanation': 'Offers a discount on fees'},
      ],
      'extracted': {'payee': null, 'amount': 22100.0, 'currency': 'CNY', 'account': '6222 0011 2233 7788'},
      'payee_verification': {'status': 'UNKNOWN'},
    });
    await tester.pumpWidget(_host(card!));
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('Likely scam'), findsOneWidget);
    expect(find.text('Account 6222 …7788'), findsOneWidget);
    expect(find.text('Not a verified university account'), findsOneWidget);
    expect(find.text('Pushes you to pay immediately'), findsOneWidget);
  });

  test('read-only tools without a card return nothing', () {
    expect(actionCard({'tool': 'get_tuition_reminders', 'status': 'READ'}), isNull);
  });
}
