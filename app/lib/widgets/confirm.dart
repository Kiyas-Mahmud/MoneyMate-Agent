import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'glass.dart';
import 'ui.dart';

/// A small glass confirmation dialog. Resolves to true only when the student taps the confirm button.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool danger = false,
}) async {
  final ok = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: .28),
    transitionDuration: AppMotion.base,
    pageBuilder: (ctx, _, _) => Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Material(
          type: MaterialType.transparency,
          child: Glass(
            level: GlassLevel.heavy,
            radius: 28,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(body, style: const TextStyle(fontSize: 13.5, color: Color(0xFF3A3A3A), height: 1.45)),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: GlassButton(label: 'Cancel', onTap: () => Navigator.of(ctx).pop(false)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: danger
                          ? GestureDetector(
                              onTap: () => Navigator.of(ctx).pop(true),
                              child: Container(
                                height: 50,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: AppColors.danger,
                                  borderRadius: BorderRadius.circular(AppRadius.pill),
                                ),
                                child: Text(
                                  action,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            )
                          : PrimaryButton(label: action, height: 50, onTap: () => Navigator.of(ctx).pop(true)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (_, a, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: AppMotion.smooth),
      child: ScaleTransition(
        scale: Tween(begin: .92, end: 1.0).animate(CurvedAnimation(parent: a, curve: AppMotion.spring)),
        child: child,
      ),
    ),
  );
  return ok == true;
}
