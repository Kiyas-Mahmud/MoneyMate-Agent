import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../widgets/background.dart';
import '../../widgets/orb.dart';

/// Shown for a moment while the saved session is read.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: DriftBackground(child: Center(child: Orb(height: 40))),
  ).animate().fadeIn(duration: 300.ms);
}
