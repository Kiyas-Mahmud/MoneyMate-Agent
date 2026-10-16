import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../core/theme.dart';
import 'glass.dart';

/// Glass pill text field with a label above and an animated error below.
class GlassField extends StatefulWidget {
  const GlassField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.error,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.autofillHints,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final String? error;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final Iterable<String>? autofillHints;

  @override
  State<GlassField> createState() => _GlassFieldState();
}

class _GlassFieldState extends State<GlassField> {
  late bool _hidden = widget.obscure;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(widget.label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
        ),
        AnimatedScale(
          scale: focused ? 1.015 : 1,
          duration: AppMotion.fast,
          curve: AppMotion.smooth,
          child: Glass(
            radius: AppRadius.pill,
            level: focused ? GlassLevel.heavy : GlassLevel.regular,
            child: SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: 20),
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      focusNode: _focus,
                      obscureText: _hidden,
                      keyboardType: widget.keyboardType,
                      textInputAction: widget.textInputAction,
                      onSubmitted: widget.onSubmitted,
                      onChanged: widget.onChanged,
                      autofillHints: widget.autofillHints,
                      style: const TextStyle(fontSize: 15),
                      decoration: InputDecoration(hintText: widget.hint, isCollapsed: true),
                    ),
                  ),
                  if (widget.obscure)
                    IconButton(
                      tooltip: _hidden ? 'Show password' : 'Hide password',
                      onPressed: () => setState(() => _hidden = !_hidden),
                      icon: AnimatedSwitcher(
                        duration: AppMotion.fast,
                        child: Icon(
                          _hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                          key: ValueKey(_hidden),
                          size: 20,
                          color: AppColors.muted,
                        ),
                      ),
                    )
                  else
                    const SizedBox(width: 16),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: AppMotion.fast,
          curve: AppMotion.smooth,
          child: widget.error == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(left: 6, top: 6),
                  child: Text(
                    widget.error!,
                    style: const TextStyle(color: AppColors.danger, fontSize: 12),
                  ).animate().fadeIn(duration: 200.ms).shakeX(hz: 4, amount: 3, duration: 300.ms),
                ),
        ),
      ],
    );
  }
}

/// Selectable chip that morphs between glass and solid ink.
class ChoiceChip2 extends StatelessWidget {
  const ChoiceChip2({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: AppMotion.smooth,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : Colors.white.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: selected ? AppColors.ink : Colors.white),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 280),
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: selected ? Colors.white : AppColors.ink),
          child: Text(label),
        ),
      ),
    ),
  );
}
