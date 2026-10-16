import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneymate/widgets/anchor_line.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('an anchored receipt names the chain and block', (tester) async {
    await tester.pumpWidget(_host(const AnchorLine(anchor: {
      'state': 'anchored', 'chain': 'Ethereum Sepolia', 'block_number': 6812345,
      'explorer_url': 'https://sepolia.etherscan.io/tx/0xabc',
    })));
    expect(find.text('Secured on blockchain'), findsOneWidget);
    expect(find.textContaining('Ethereum Sepolia · block 6812345'), findsOneWidget);
  });

  testWidgets('a pending anchor says when it will be added', (tester) async {
    await tester.pumpWidget(_host(const AnchorLine(anchor: {'state': 'pending', 'chain': 'Ethereum Sepolia'})));
    expect(find.text('Blockchain anchor pending'), findsOneWidget);
  });

  testWidgets('nothing is shown without an audit entry', (tester) async {
    await tester.pumpWidget(_host(const AnchorLine(anchor: {'state': 'none'})));
    expect(find.byType(Container), findsNothing);
  });
}
