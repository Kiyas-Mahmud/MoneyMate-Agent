import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Tab switches: content fades through (old fades out, new scales in slightly).
CustomTransitionPage<void> fadeThroughPage(GoRouterState state, Widget child) => CustomTransitionPage(
  key: state.pageKey,
  child: child,
  transitionDuration: const Duration(milliseconds: 420),
  transitionsBuilder: (_, a, sa, c) =>
      FadeThroughTransition(animation: a, secondaryAnimation: sa, fillColor: Colors.transparent, child: c),
);

/// Drill-down screens: shared horizontal axis (new slides in, old slides out, both fade).
CustomTransitionPage<void> sharedAxisPage(GoRouterState state, Widget child) => CustomTransitionPage(
  key: state.pageKey,
  child: child,
  transitionDuration: const Duration(milliseconds: 450),
  reverseTransitionDuration: const Duration(milliseconds: 380),
  transitionsBuilder: (_, a, sa, c) => SharedAxisTransition(
    animation: a,
    secondaryAnimation: sa,
    transitionType: SharedAxisTransitionType.horizontal,
    fillColor: Colors.transparent,
    child: c,
  ),
);

/// Bottom sheets (verify, pay menu): slide up over a dimmed screen. A popup route, not a page route, so the
/// screen underneath stays put instead of playing its own exit transition (which faded it to black).
Page<void> sheetPage(GoRouterState state, Widget child) => _SheetPage(key: state.pageKey, child: child);

class _SheetPage extends Page<void> {
  const _SheetPage({super.key, required this.child});
  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) => _SheetRoute(settings: this);
}

class _SheetRoute extends PopupRoute<void> {
  _SheetRoute({required _SheetPage settings}) : super(settings: settings);

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.28);
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Close';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 520);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 320);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      (settings as _SheetPage).child;

  @override
  Widget buildTransitions(BuildContext context, Animation<double> a, Animation<double> sa, Widget child) =>
      SlideTransition(
        position: Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
        child: child,
      );
}
