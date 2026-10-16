import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/fields.dart';
import '../../widgets/sheet.dart';
import '../../widgets/ui.dart';

const _relationships = ['Mother', 'Father', 'Sibling', 'Landlord', 'Friend', 'Other'];
const _countries = ['Bangladesh', 'China', 'United States', 'Canada', 'United Kingdom', 'Malaysia'];

/// Saves a new recipient. Returns the saved recipient to the screen that opened it.
class AddRecipientSheet extends ConsumerStatefulWidget {
  const AddRecipientSheet({super.key});
  @override
  ConsumerState<AddRecipientSheet> createState() => _AddRecipientSheetState();
}

class _AddRecipientSheetState extends ConsumerState<AddRecipientSheet> {
  final _name = TextEditingController();
  final _bank = TextEditingController();
  final _account = TextEditingController();
  String _relationship = 'Other';
  late String _country = ref.read(sessionProvider).user?['home_country'] as String? ?? _countries.first;
  final Map<String, String?> _errors = {};
  String? _serverError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final (c, key) in [(_name, 'name'), (_account, 'account')]) {
      c.addListener(() {
        if (_errors[key] != null) setState(() => _errors[key] = null);
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _bank.dispose();
    _account.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final digits = _account.text.replaceAll(RegExp(r'[^0-9A-Za-z]'), '');
    setState(() {
      _errors['name'] = _name.text.trim().length < 2 ? 'Enter the name on the bank account' : null;
      _errors['account'] = digits.length < 6 ? 'Enter the full account number' : null;
      _serverError = null;
    });
    if (_errors.values.any((e) => e != null)) return;
    setState(() => _busy = true);
    try {
      final res = await ref.read(apiProvider).post('/payees', {
        'name': _name.text.trim(),
        'relationship': _relationship == 'Other' ? null : _relationship,
        'country': _country,
        'bank_name': _bank.text.trim().isEmpty ? null : _bank.text.trim(),
        'account_ref': _account.text.trim(),
      });
      if (mounted) context.pop(Map<String, dynamic>.from(res));
    } on ApiError catch (e) {
      if (mounted) setState(() => _serverError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 6),
    child: Text(text, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
  );

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      GlassField(
        label: 'Full name',
        controller: _name,
        hint: 'Name on the bank account',
        error: _errors['name'],
        textInputAction: TextInputAction.next,
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Relationship'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final r in _relationships)
                ChoiceChip2(label: r, selected: r == _relationship, onTap: () => setState(() => _relationship = r)),
            ],
          ),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Country'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in _countries)
                ChoiceChip2(label: c, selected: c == _country, onTap: () => setState(() => _country = c)),
            ],
          ),
        ],
      ),
      GlassField(label: 'Bank', controller: _bank, hint: 'Sonali Bank', textInputAction: TextInputAction.next),
      GlassField(
        label: 'Account number',
        controller: _account,
        hint: '0102 0344 5566 7',
        error: _errors['account'],
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(18)),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LucideIcons.triangleAlert, size: 16, color: Color(0xFF6B4100)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Every payment needs your fingerprint, and new recipients get extra checks. '
                'Never add someone you only met online.',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B4100), height: 1.45),
              ),
            ),
          ],
        ),
      ),
      if (_serverError != null) Text(_serverError!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
      PrimaryButton(label: 'Save recipient', loading: _busy, onTap: _save),
    ];

    return GlassSheet(
      title: 'Add a recipient',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, w) in items.indexed) ...[if (i > 0) const SizedBox(height: 12), w.enter(i, baseMs: 40)],
        ],
      ),
    );
  }
}
