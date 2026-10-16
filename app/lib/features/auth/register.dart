import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/background.dart';
import '../../widgets/fields.dart';
import '../../widgets/glass.dart';
import '../../widgets/ui.dart';

const _homes = ['Bangladesh', 'United States'];
const _studies = ['China', 'Canada', 'United Kingdom', 'Malaysia'];

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _name = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String _home = _homes.first;
  String _study = _studies.first;
  final Map<String, String?> _errors = {};
  String? _serverError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // An error disappears as soon as the student edits that field.
    for (final (c, key) in [(_name, 'name'), (_user, 'user'), (_pass, 'pass')]) {
      c.addListener(() {
        if (_errors[key] != null) setState(() => _errors[key] = null);
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  bool _validate() {
    _errors
      ..clear()
      ..['name'] = _name.text.trim().length < 2 ? 'Enter your full name' : null
      ..['user'] = _user.text.trim().length < 3 ? 'At least 3 characters' : null
      ..['pass'] = _pass.text.length < 8 ? 'At least 8 characters' : null;
    setState(() {});
    return _errors.values.every((e) => e == null);
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_validate()) return;
    setState(() {
      _busy = true;
      _serverError = null;
    });
    try {
      final res = await ref.read(apiProvider).post('/auth/register', {
        'full_name': _name.text.trim(),
        'username': _user.text.trim(),
        'password': _pass.text,
        'home_country': _home,
        'study_country': _study,
      });
      await ref.read(sessionProvider.notifier).signIn(res['access_token'], Map<String, dynamic>.from(res['user']));
      if (mounted) context.go('/home');
    } on ApiError catch (e) {
      if (mounted) setState(() => _serverError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final items = <Widget>[
      Text('Create your account', style: t.headlineMedium?.copyWith(fontSize: 26)),
      Text('Sandbox demo: you get demo wallets and your university\'s tuition invoice.', style: t.bodySmall),
      GlassField(
        label: 'Full name',
        controller: _name,
        hint: 'Ayesha Rahman',
        error: _errors['name'],
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.name],
      ),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: GlassField(
              label: 'Username',
              controller: _user,
              hint: 'ayesha',
              error: _errors['user'],
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.newUsername],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GlassField(
              label: 'Password',
              controller: _pass,
              obscure: true,
              hint: '8+ chars',
              error: _errors['pass'],
              autofillHints: const [AutofillHints.newPassword],
            ),
          ),
        ],
      ),
      _choices('Home country', _homes, _home, (v) => setState(() => _home = v)),
      _choices('Where you study', _studies, _study, (v) => setState(() => _study = v)),
      Glass(
        level: GlassLevel.light,
        padding: const EdgeInsets.all(14),
        child: const Row(
          children: [
            Icon(LucideIcons.fingerprint, size: 22),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Every payment is verified with your fingerprint. The agent can never pay on its own.',
                style: TextStyle(fontSize: 12.5, height: 1.4),
              ),
            ),
          ],
        ),
      ),
      if (_serverError != null) Text(_serverError!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
    ];

    return Scaffold(
      body: DriftBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: CircleGlassButton(
                    icon: LucideIcons.chevronLeft,
                    tooltip: 'Back',
                    onTap: () => context.canPop() ? context.pop() : context.go('/login'),
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 14),
                  itemBuilder: (_, i) => items[i].enter(i, baseMs: 45),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: PrimaryButton(label: 'Create account', loading: _busy, onTap: _submit),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _choices(String label, List<String> options, String selected, ValueChanged<String> onPick) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
      ),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [for (final o in options) ChoiceChip2(label: o, selected: o == selected, onTap: () => onPick(o))],
      ),
    ],
  );
}
