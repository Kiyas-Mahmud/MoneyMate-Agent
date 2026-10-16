import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/background.dart';
import '../../widgets/glass.dart';
import '../../widgets/orb.dart';
import '../../widgets/ui.dart';

class _Slide {
  const _Slide(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;
}

const _slides = [
  _Slide(
    LucideIcons.graduationCap,
    'Pay tuition the safe way',
    'Your agent pays only official university accounts and reminds you before every deadline.',
  ),
  _Slide(
    LucideIcons.send,
    'Send money home for less',
    'Compare every route at live rates and keep more of what your family sends.',
  ),
  _Slide(
    LucideIcons.shieldCheck,
    'Catch scams before you pay',
    'Paste any message asking for money. Every payment waits for your fingerprint.',
  ),
];

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pager = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _leave(String to) async {
    await ref.read(sessionProvider.notifier).finishOnboarding();
    if (mounted) context.go(to);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final last = _page == _slides.length - 1;
    return Scaffold(
      body: DriftBackground(
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _leave('/login'),
                  child: const Text('Skip', style: TextStyle(color: AppColors.muted, fontSize: 14)),
                ),
              ),
              const Spacer(),
              // The icon card cross-fades and pops when the page changes.
              Glass(
                    radius: 60,
                    child: SizedBox(
                      width: 220,
                      height: 220,
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 450),
                          switchInCurve: Curves.easeOutBack,
                          transitionBuilder: (child, a) => ScaleTransition(
                            scale: Tween(begin: .6, end: 1.0).animate(a),
                            child: FadeTransition(opacity: a, child: child),
                          ),
                          child: Icon(_slides[_page].icon, key: ValueKey(_page), size: 84, weight: 300),
                        ),
                      ),
                    ),
                  )
                  .animate()
                  .fadeIn(duration: 500.ms)
                  .scale(begin: const Offset(.92, .92), curve: AppMotion.spring, duration: 600.ms),
              const Spacer(),
              SizedBox(
                height: 170,
                child: PageView.builder(
                  controller: _pager,
                  itemCount: _slides.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Orb(height: 18),
                        const SizedBox(height: 14),
                        Text(_slides[i].title, style: t.headlineMedium?.copyWith(fontSize: 28, height: 1.15)).enter(0),
                        const SizedBox(height: 10),
                        Text(
                          _slides[i].body,
                          style: t.bodyMedium?.copyWith(fontSize: 15, color: AppColors.muted),
                        ).enter(1),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SmoothPageIndicator(
                        controller: _pager,
                        count: _slides.length,
                        effect: const ExpandingDotsEffect(
                          dotHeight: 6,
                          dotWidth: 6,
                          expansionFactor: 4,
                          spacing: 6,
                          activeDotColor: AppColors.ink,
                          dotColor: Color(0x33000000),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    PrimaryButton(
                      label: last ? 'Get started' : 'Next',
                      onTap: () => last
                          ? _leave('/register')
                          : _pager.nextPage(duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic),
                    ),
                    const SizedBox(height: 14),
                    GestureDetector(
                      onTap: () => _leave('/login'),
                      child: Text.rich(
                        TextSpan(
                          text: 'Have an account? ',
                          style: const TextStyle(color: AppColors.muted),
                          children: [
                            TextSpan(
                              text: 'Sign in',
                              style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
