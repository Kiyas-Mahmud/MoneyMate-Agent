import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import 'pressable.dart';
import 'ui.dart';

/// Opens a blockchain explorer page in the browser.
Future<void> openExplorer(BuildContext context, String? url) async {
  if (url == null) return;
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) toast(context, 'Couldn\'t open the explorer', error: true);
}

/// "Secured on blockchain" line for a receipt or payment history report.
/// `anchor` is the backend's status: {state: anchored | pending | none, ...}.
class AnchorLine extends StatelessWidget {
  const AnchorLine({super.key, required this.anchor});
  final Map<String, dynamic>? anchor;

  @override
  Widget build(BuildContext context) {
    final a = anchor;
    final state = a?['state'];
    if (a == null || state == 'none') return const SizedBox.shrink();
    final anchored = state == 'anchored';
    final block = a['block_number'];
    final line = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: .8), borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Icon(
            anchored ? LucideIcons.link : LucideIcons.clock,
            size: 16,
            color: anchored ? AppColors.success : AppColors.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  anchored ? 'Secured on blockchain' : 'Blockchain anchor pending',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                Text(
                  anchored
                      ? '${a['chain']}${block != null ? ' · block $block' : ''} · tap to view'
                      : 'Added to ${a['chain'] ?? 'the blockchain'} in the next daily anchor',
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ],
            ),
          ),
          if (anchored) const Icon(LucideIcons.externalLink, size: 15, color: AppColors.muted),
        ],
      ),
    );
    // Only an anchored line is a link; a pending one stays fully visible instead of looking disabled.
    return anchored
        ? Pressable(onTap: () => openExplorer(context, a['explorer_url'] as String?), scale: .98, child: line)
        : line;
  }
}
