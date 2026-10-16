import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/config.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/anchor_line.dart';
import '../../widgets/background.dart';
import '../../widgets/glass.dart';
import '../../widgets/ui.dart';

final _receiptProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int>(
  (ref, id) async => Map<String, dynamic>.from(await ref.watch(apiProvider).get('/transactions/$id/receipt')),
  retry: (_, _) => null,
);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "10 Oct 2026 · 08:24 UTC": receipts state UTC so they read the same in every country.
String _stamp(String iso) {
  final d = parseUtc(iso).toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.day} ${_months[d.month - 1]} ${d.year} · ${two(d.hour)}:${two(d.minute)} UTC';
}

/// Signed proof of a completed payment, checkable by anyone with the reference and code.
class ReceiptScreen extends ConsumerStatefulWidget {
  const ReceiptScreen({super.key, required this.txId});
  final int txId;

  @override
  ConsumerState<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends ConsumerState<ReceiptScreen> {
  bool _sharingPdf = false;

  String _verifyLink(Map<String, dynamic> r) => '$publicBase${r['verify_url']}';

  Future<void> _sharePdf(Map<String, dynamic> r) async {
    setState(() => _sharingPdf = true);
    try {
      final bytes = await ref.read(apiProvider).bytes('/transactions/${widget.txId}/receipt.pdf');
      final name = '${r['reference']}.pdf';
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(Uint8List.fromList(bytes), mimeType: 'application/pdf', name: name)],
          fileNameOverrides: [name],
          subject: 'MoneyMate receipt ${r['reference']}',
        ),
      );
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _sharingPdf = false);
    }
  }

  void _shareText(Map<String, dynamic> r) => SharePlus.instance.share(
    ShareParams(
      subject: 'MoneyMate receipt ${r['reference']}',
      text:
          '${r['type']}: ${money(r['amount'] as num, r['currency'] as String)} to ${r['counterparty']}\n'
          'Reference ${r['reference']} · code ${r['verification_code']}\n'
          'Check it is genuine: ${_verifyLink(r)}',
    ),
  );

  void _copyCode(Map<String, dynamic> r) {
    Clipboard.setData(ClipboardData(text: '${r['reference']} ${r['verification_code']}'));
    HapticFeedback.selectionClick();
    toast(context, 'Reference and code copied');
  }

  void _back() => context.canPop() ? context.pop() : context.go('/home');

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_receiptProvider(widget.txId));
    final r = async.value;
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      body: DriftBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator(color: AppColors.ink, strokeWidth: 2)),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Glass(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(LucideIcons.fileX, size: 28),
                          const SizedBox(height: 10),
                          Text(
                            '$e',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13, color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                data: (r) => TopFade(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(16, top + 68, 16, bottom + 100),
                    children: [_ReceiptCard(r: r, link: _verifyLink(r), onCopy: () => _copyCode(r))],
                  ),
                ),
              ),
            ),
            Positioned(
              top: top + 8,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  CircleGlassButton(icon: LucideIcons.chevronLeft, tooltip: 'Back', onTap: _back),
                  const Expanded(
                    child: Text(
                      'Receipt',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: r == null ? 0 : 1,
                    duration: AppMotion.fast,
                    child: CircleGlassButton(
                      icon: LucideIcons.share2,
                      tooltip: 'Share receipt',
                      onTap: r == null ? null : () => _shareText(r),
                    ),
                  ),
                ],
              ),
            ),
            if (r != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: bottom + 20,
                child:
                    Row(
                          children: [
                            Expanded(
                              child: PrimaryButton(
                                label: 'Share PDF',
                                icon: LucideIcons.fileDown,
                                loading: _sharingPdf,
                                onTap: () => _sharePdf(r),
                              ),
                            ),
                            const SizedBox(width: 10),
                            GlassButton(label: 'Copy code', height: 54, onTap: () => _copyCode(r)),
                          ],
                        )
                        .animate()
                        .fadeIn(delay: 250.ms, duration: AppMotion.base)
                        .slideY(begin: .4, delay: 250.ms, curve: AppMotion.smooth),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReceiptCard extends StatelessWidget {
  const _ReceiptCard({required this.r, required this.link, required this.onCopy});
  final Map<String, dynamic> r;
  final String link;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final incoming = r['direction'] == 'IN';
    final amount = r['amount'] as num;
    final currency = r['currency'] as String;
    final account = r['counterparty_account'] as String?;
    final rows = <(String, String)>[
      ('Reference', r['reference'] as String),
      (incoming ? 'From' : 'Paid to', (r['counterparty'] as String? ?? '').replaceAll(RegExp(r'\s*\(.*\)$'), '')),
      if (account != null)
        ('Account', r['payee_verified_institution'] == true ? '$account · verified institution' : account),
      ('Issued to', [r['issued_to'], r['student_id']].whereType<String>().join(' · ')),
      if (r['provider'] != null) ('Via', r['provider'] as String),
      if ((r['fee'] as num? ?? 0) > 0) ('Fee', money(r['fee'] as num, currency, decimals: true)),
      if (r['memo'] != null) ('Note', r['memo'] as String),
      ('Approval', r['approval'] as String? ?? ''),
    ];

    return Glass(
      level: GlassLevel.heavy,
      radius: 30,
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
            child: const Icon(
              LucideIcons.check,
              color: Colors.white,
              size: 26,
            ).animate().scaleXY(begin: 0, delay: 250.ms, duration: 450.ms, curve: Curves.elasticOut),
          ).animate().scaleXY(begin: .6, duration: 500.ms, curve: Curves.elasticOut),
          const SizedBox(height: 12),
          Text(r['type'] as String? ?? 'Payment', style: const TextStyle(fontSize: 13, color: AppColors.muted)),
          const SizedBox(height: 2),
          Text(
            money(amount, currency, signed: incoming),
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600, letterSpacing: -1),
          ),
          const SizedBox(height: 4),
          Text(_stamp(r['executed_at'] as String), style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .8),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                for (final (i, (label, value)) in rows.indexed)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      border: i == rows.length - 1
                          ? null
                          : Border(bottom: BorderSide(color: Colors.black.withValues(alpha: .06))),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            value,
                            textAlign: TextAlign.right,
                            style: TextStyle(fontSize: 12, fontWeight: i == 0 ? FontWeight.w500 : FontWeight.w400),
                          ),
                        ),
                      ],
                    ),
                  ).animate().fadeIn(delay: (150 + i * 50).ms, duration: AppMotion.base),
              ],
            ),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onLongPress: onCopy,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .8),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                        child: QrImageView(
                          data: link,
                          size: 92,
                          padding: const EdgeInsets.all(6),
                          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: AppColors.ink),
                          dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: AppColors.ink,
                          ),
                        ),
                      )
                      .animate()
                      .fadeIn(delay: 450.ms, duration: AppMotion.base)
                      .scaleXY(begin: .85, delay: 450.ms, curve: AppMotion.spring),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Verification code', style: TextStyle(fontSize: 11, color: AppColors.muted)),
                        const SizedBox(height: 2),
                        Text(
                          r['verification_code'] as String? ?? '',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            letterSpacing: .4,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Landlords, universities and visa offices can scan to check it\'s genuine. Any change makes the code fail.',
                          style: TextStyle(fontSize: 11, color: AppColors.muted, height: 1.45),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (r['anchor'] != null) ...[
            const SizedBox(height: 10),
            AnchorLine(anchor: Map<String, dynamic>.from(r['anchor'] as Map)),
          ],
        ],
      ),
    ).enter(0);
  }
}
