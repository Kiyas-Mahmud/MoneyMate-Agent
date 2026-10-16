import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import 'glass.dart';
import 'pressable.dart';

/// Frame for bottom sheets opened with `sheetPage`: heavy glass, grab handle, optional title with a close
/// button, lifts above the keyboard, and can be dragged down to close.
class GlassSheet extends StatefulWidget {
  const GlassSheet({super.key, required this.child, this.title});
  final Widget child;
  final String? title;

  @override
  State<GlassSheet> createState() => _GlassSheetState();
}

class _GlassSheetState extends State<GlassSheet> with SingleTickerProviderStateMixin {
  double _drag = 0, _dragFrom = 0;
  late final AnimationController _snap = AnimationController(vsync: this, duration: AppMotion.fast)
    ..addListener(() => setState(() => _drag = _dragFrom * (1 - Curves.easeOut.transform(_snap.value))));

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  void _close() => context.canPop() ? context.pop() : context.go('/home');

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return AnimatedPadding(
      duration: AppMotion.fast,
      curve: AppMotion.smooth,
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: GestureDetector(
          onVerticalDragUpdate: (d) => setState(() => _drag = (_drag + d.delta.dy).clamp(0, 400)),
          onVerticalDragEnd: (d) {
            if (_drag > 120 || d.velocity.pixelsPerSecond.dy > 900) return _close();
            _dragFrom = _drag;
            _snap.forward(from: 0);
          },
          child: Transform.translate(
            offset: Offset(0, _drag),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: (mq.size.height - mq.viewInsets.bottom) * .94),
              child: Glass(
                level: GlassLevel.heavy,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
                padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + (mq.viewInsets.bottom > 0 ? 0 : mq.padding.bottom)),
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .18),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (widget.title != null) ...[
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.title!,
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                              ),
                            ),
                            Semantics(
                              button: true,
                              label: 'Close',
                              child: Pressable(
                                onTap: _close,
                                scale: .9,
                                child: Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: .9),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(LucideIcons.x, size: 18),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      Flexible(child: SingleChildScrollView(child: widget.child)),
                    ],
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
