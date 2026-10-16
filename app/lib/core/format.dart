/// Money and date formatting shared by every screen.
library;

const _symbols = {'BDT': '৳', 'CNY': '¥', 'USD': r'$', 'CAD': r'C$', 'GBP': '£', 'MYR': 'RM', 'EUR': '€'};
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String currencySymbol(String code) => _symbols[code] ?? '$code ';

/// "৳250,000", "¥1,500", "$12.50". Amounts of 100 or more drop the decimals.
String money(num amount, String currency, {bool signed = false, bool? decimals}) {
  final abs = amount.abs();
  final showCents = decimals ?? (abs < 100 && abs != abs.roundToDouble());
  final fixed = abs.toStringAsFixed(showCents ? 2 : 0);
  final parts = fixed.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  final sign = amount < 0 ? '−' : (signed ? '+' : '');
  return '$sign${currencySymbol(currency)}$whole${parts.length > 1 ? '.${parts[1]}' : ''}';
}

/// "22 Oct" from an ISO date or date-time string.
String shortDate(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso);
  return d == null ? '' : '${d.day} ${_months[d.month - 1]}';
}

/// Parses a backend time; one without an offset is UTC (never the phone's local time).
DateTime parseUtc(String iso) =>
    DateTime.parse(RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(iso) ? iso : '${iso}Z').toLocal();

/// "Good morning" / "Good afternoon" / "Good evening" for the device's local time.
String greeting([DateTime? now]) {
  final h = (now ?? DateTime.now()).hour;
  return h < 12
      ? 'Good morning'
      : h < 17
      ? 'Good afternoon'
      : 'Good evening';
}
