import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/background.dart';
import '../../widgets/fields.dart';
import '../../widgets/glass.dart';
import '../../widgets/orb.dart';
import '../../widgets/ui.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Enter your username and password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiProvider).post('/auth/login', {
        'username': _user.text.trim(),
        'password': _pass.text,
      });
      await ref.read(sessionProvider.notifier).signIn(res['access_token'], Map<String, dynamic>.from(res['user']));
      if (mounted) context.go('/home');
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: DriftBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: c.maxHeight),
                child: IntrinsicHeight(
                  child: AutofillGroup(
                    child: Column(
                      children: [
                        const SizedBox(height: 56),
                        Glass(
                              radius: 44,
                              child: const SizedBox(width: 88, height: 88, child: Center(child: Orb(height: 34))),
                            )
                            .animate()
                            .fadeIn(duration: 500.ms)
                            .scale(begin: const Offset(.7, .7), curve: AppMotion.spring, duration: 700.ms),
                        const SizedBox(height: 18),
                        Text('MoneyMate', style: t.headlineMedium?.copyWith(fontSize: 30)).enter(1),
                        const SizedBox(height: 8),
                        Text(
                          'Your AI agent for tuition and\nmoney across borders',
                          textAlign: TextAlign.center,
                          style: t.bodyMedium?.copyWith(color: AppColors.muted, fontSize: 15),
                        ).enter(2),
                        const Spacer(),
                        const SizedBox(height: 24),
                        GlassField(
                          label: 'Username',
                          controller: _user,
                          hint: 'ayesha',
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.username],
                        ).enter(3),
                        const SizedBox(height: 12),
                        GlassField(
                          label: 'Password',
                          controller: _pass,
                          obscure: true,
                          error: _error,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          autofillHints: const [AutofillHints.password],
                        ).enter(4),
                        const SizedBox(height: 18),
                        PrimaryButton(label: 'Sign in', loading: _busy, onTap: _submit).enter(5),
                        const SizedBox(height: 18),
                        GestureDetector(
                          onTap: () => context.push('/register'),
                          child: const Text.rich(
                            TextSpan(
                              text: 'New student? ',
                              style: TextStyle(color: AppColors.muted),
                              children: [
                                TextSpan(
                                  text: 'Create an account',
                                  style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ).enter(6),
                        const SizedBox(height: 10),
                        const Text(
                          'Sandbox demo · no real money moves',
                          style: TextStyle(fontSize: 11, color: AppColors.hint),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
