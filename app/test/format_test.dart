import 'package:flutter_test/flutter_test.dart';
import 'package:moneymate/core/format.dart';

void main() {
  group('money', () {
    test('uses the currency symbol and thousands separators', () {
      expect(money(250000, 'BDT'), '৳250,000');
      expect(money(26000, 'CNY'), '¥26,000');
      expect(money(16288.41, 'MYR'), 'RM16,288');
    });

    test('shows cents only for small, non-round amounts unless asked', () {
      expect(money(12.5, 'USD'), r'$12.50');
      expect(money(300, 'USD'), r'$300');
      expect(money(246.27, 'BDT', decimals: true), '৳246.27');
    });

    test('signs incoming and outgoing amounts', () {
      expect(money(60000, 'BDT', signed: true), '+৳60,000');
      expect(money(-1500, 'CNY'), '−¥1,500');
    });

    test('falls back to the code for unknown currencies', () {
      expect(money(10, 'JPY'), 'JPY 10');
    });
  });

  group('parseUtc', () {
    test('treats times without an offset as UTC, never phone-local', () {
      final a = parseUtc('2026-10-16T07:26:56');
      final b = parseUtc('2026-10-16T07:26:56+00:00');
      expect(a.isAtSameMomentAs(b), isTrue);
      expect(a.toUtc().hour, 7);
    });

    test('respects an explicit offset', () {
      final d = parseUtc('2026-10-16T15:26:56+08:00');
      expect(d.toUtc().hour, 7);
    });
  });

  test('shortDate', () {
    expect(shortDate('2026-10-22'), '22 Oct');
    expect(shortDate(null), '');
  });

  test('greeting follows the local hour', () {
    expect(greeting(DateTime(2026, 10, 16, 8)), 'Good morning');
    expect(greeting(DateTime(2026, 10, 16, 14)), 'Good afternoon');
    expect(greeting(DateTime(2026, 10, 16, 20)), 'Good evening');
  });
}
