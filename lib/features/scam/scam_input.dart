import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme.dart';
import '../../widgets/background.dart';
import '../../widgets/glass.dart';
import '../../widgets/pressable.dart';
import '../../widgets/ui.dart';

const _examples = [
  (
    'Fake tuition agent',
    'URGENT · Pearl River University Bursary Office. Pay your Spring 2027 tuition today only and get a 15% discount. '
        'CNY 22,100 by WeChat transfer to our agent. Account 6222 9911 0042 7788. Do not contact the university office.',
  ),
  (
    'Fake immigration officer',
    'This is the Immigration Office. Your student visa will be cancelled unless you pay a USD 1,500 penalty within '
        '24 hours. Pay with bitcoin or gift cards.',
  ),
  (
    'Part-time job',
    'Easy job for students: receive 30,000 CNY from our client and forward it to our partner. Keep 10% for yourself.',
  ),
];

enum _Mode { paste, screenshot, camera }

/// Paste a message, or read one from a screenshot / photo, then check it. Nothing is paid here.
class ScamInputScreen extends StatefulWidget {
  const ScamInputScreen({super.key});
  @override
  State<ScamInputScreen> createState() => _ScamInputScreenState();
}

class _ScamInputScreenState extends State<ScamInputScreen> {
  final _text = TextEditingController();
  _Mode _mode = _Mode.paste;
  bool _reading = false;
  String? _note; // where the text came from, after reading an image

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Reads the text in a screenshot or photo on the phone itself (ML Kit); the image is never uploaded.
  Future<void> _readImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, maxWidth: 2000);
    if (picked == null) {
      setState(() => _mode = _Mode.paste);
      return;
    }
    setState(() => _reading = true);
    final recognizer = TextRecognizer(script: TextRecognitionScript.chinese); // reads Chinese and Latin text
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(picked.path));
      final text = result.blocks.map((b) => b.text.replaceAll('\n', ' ')).join('\n').trim();
      if (!mounted) return;
      if (text.isEmpty) {
        toast(context, 'No text found in that image', error: true);
      } else {
        HapticFeedback.selectionClick();
        _text.text = text;
        _note =
            'Read from your ${source == ImageSource.camera ? 'photo' : 'screenshot'}. Fix anything misread, then check it.';
      }
    } catch (_) {
      if (mounted) toast(context, 'Couldn\'t read that image', error: true);
    } finally {
      await recognizer.close();
      if (mounted) {
        setState(() {
          _reading = false;
          _mode = _Mode.paste;
        });
      }
    }
  }

  void _pick(_Mode m) {
    setState(() => _mode = m);
    if (m == _Mode.screenshot) _readImage(ImageSource.gallery);
    if (m == _Mode.camera) _readImage(ImageSource.camera);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text?.isNotEmpty ?? false) {
      _text.text = data!.text!;
      setState(() => _note = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final ready = _text.text.trim().length >= 12 && !_reading;

    final modes = [
      (_Mode.paste, LucideIcons.clipboardPaste, 'Paste text'),
      (_Mode.screenshot, LucideIcons.image, 'Screenshot'),
      (_Mode.camera, LucideIcons.camera, 'Camera'),
    ];

    final items = <Widget>[
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Got a message\nasking for money?',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: -0.5, height: 1.2),
          ),
          SizedBox(height: 6),
          Text('Nothing is paid. We only check it.', style: TextStyle(fontSize: 13, color: AppColors.muted)),
        ],
      ),
      Row(
        children: [
          for (final (i, (m, icon, label)) in modes.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Pressable(
                onTap: _reading ? null : () => _pick(m),
                child: AnimatedContainer(
                  duration: AppMotion.base,
                  curve: AppMotion.smooth,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: _mode == m ? AppColors.ink : Colors.white.withValues(alpha: .75),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Icon(icon, size: 20, color: _mode == m ? Colors.white : AppColors.ink),
                      const SizedBox(height: 8),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: _mode == m ? Colors.white : AppColors.ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      Glass(
        level: GlassLevel.heavy,
        radius: 26,
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Stack(
          children: [
            TextField(
              controller: _text,
              minLines: 6,
              maxLines: 12,
              onChanged: (_) => _note == null ? null : setState(() => _note = null),
              style: const TextStyle(fontSize: 14, height: 1.5),
              decoration: const InputDecoration(
                hintText: 'Paste the email, SMS, WeChat or WhatsApp message here',
                contentPadding: EdgeInsets.fromLTRB(0, 10, 36, 10),
              ),
            ),
            Positioned(
              right: 0,
              top: 4,
              child: AnimatedSwitcher(
                duration: AppMotion.fast,
                child: _text.text.isEmpty
                    ? IconButton(
                        key: const ValueKey('p'),
                        tooltip: 'Paste',
                        onPressed: _paste,
                        icon: const Icon(LucideIcons.clipboardPaste, size: 18, color: AppColors.muted),
                      )
                    : IconButton(
                        key: const ValueKey('c'),
                        tooltip: 'Clear',
                        onPressed: () => setState(() {
                          _text.clear();
                          _note = null;
                        }),
                        icon: const Icon(LucideIcons.x, size: 18, color: AppColors.muted),
                      ),
              ),
            ),
            if (_reading)
              Positioned.fill(
                child: Container(
                  alignment: Alignment.center,
                  color: Colors.white.withValues(alpha: .6),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink),
                      ),
                      SizedBox(height: 10),
                      Text('Reading the text on your phone…', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                    ],
                  ),
                ).animate().fadeIn(duration: AppMotion.fast),
              ),
          ],
        ),
      ),
      AnimatedSize(
        duration: AppMotion.base,
        curve: AppMotion.smooth,
        child: _note == null
            ? const SizedBox(width: double.infinity)
            : Row(
                children: [
                  const Icon(LucideIcons.scanText, size: 15, color: AppColors.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_note!, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                  ),
                ],
              ).animate().fadeIn(duration: AppMotion.base),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Try an example', style: TextStyle(fontSize: 12, color: AppColors.muted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (label, text) in _examples)
                Pressable(
                  onTap: () {
                    _text.text = text;
                    setState(() {
                      _mode = _Mode.paste;
                      _note = null;
                    });
                  },
                  child: Glass(
                    radius: AppRadius.pill,
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                    child: Text(label, style: const TextStyle(fontSize: 12)),
                  ),
                ),
            ],
          ),
        ],
      ),
    ];

    return Scaffold(
      body: DriftBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: TopFade(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(16, top + 68, 16, bottom + 100),
                  children: [
                    for (final (i, w) in items.indexed) ...[
                      if (i > 0) const SizedBox(height: 14),
                      w.enter(i, baseMs: 50),
                    ],
                  ],
                ),
              ),
            ),
            Positioned(
              top: top + 8,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  CircleGlassButton(
                    icon: LucideIcons.chevronLeft,
                    tooltip: 'Back',
                    onTap: () => context.canPop() ? context.pop() : context.go('/home'),
                  ),
                  const Expanded(
                    child: Text(
                      'Scam check',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: bottom + 20,
              child: AnimatedOpacity(
                duration: AppMotion.fast,
                opacity: ready ? 1 : .45,
                child: PrimaryButton(
                  label: 'Check message',
                  icon: LucideIcons.shieldCheck,
                  onTap: ready
                      ? () {
                          FocusScope.of(context).unfocus();
                          context.push('/scam/result', extra: _text.text.trim());
                        }
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
