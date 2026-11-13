import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/local/sms_intake_repository.dart';

/// The original bill message, if this phone still holds it. Not cached when
/// missing: an import may save the message after the first look.
final billProofSmsProvider = FutureProvider.autoDispose
    .family<SmsIntakeEntry?, String>((ref, sourceKey) async {
      if (sourceKey.isEmpty) return null;
      final namespace = ref.read(cacheNamespaceProvider);
      if (namespace == 'signed-out') return null;
      final cache = await ref.read(responseCacheProvider.future);
      return SmsIntakeRepository(
        cache.financialStore.database,
      ).capturedById(namespace, sourceKey);
    });

String _maskLongDigits(String text) => text.replaceAllMapped(
  RegExp(r'\b\d{8,}\b'),
  (m) => '•••• ${m.group(0)!.substring(m.group(0)!.length - 4)}',
);

/// "Proof" for a bill: the SMS it was read from, and, once paid, the payment
/// transaction (where a receipt or file can be attached).
class BillProofSection extends ConsumerWidget {
  /// Message key of the bill SMS (null for manually added bills).
  final String? sourceKey;

  /// Transaction that paid the bill, when one was matched.
  final String? paymentTransactionId;
  final DateTime? paidOn;

  /// Called before navigating away, e.g. to close the sheet that hosts this.
  final VoidCallback? onBeforeNavigate;

  const BillProofSection({
    super.key,
    this.sourceKey,
    this.paymentTransactionId,
    this.paidOn,
    this.onBeforeNavigate,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = sourceKey;
    final sms = key == null || key.isEmpty
        ? null
        : ref.watch(billProofSmsProvider(key));
    final message = sms?.valueOrNull?.message;
    final loading = sms?.isLoading ?? false;
    final payId = paymentTransactionId;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.verified_outlined,
                size: 16,
                color: BambooInk.jade,
              ),
              const SizedBox(width: 6),
              Text(
                'Proof',
                style: BambooFonts.ui(
                  13,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          if (loading)
            Text(
              'Checking messages stored on this device…',
              style: BambooFonts.ui(12, color: BambooInk.ink500),
            )
          else if (message != null) ...[
            Text(
              'Bill SMS from ${message.sender} · '
              '${DateFormat('d MMM yyyy, h:mm a').format(message.receivedAt.toLocal())}',
              style: BambooFonts.ui(
                11.5,
                weight: FontWeight.w600,
                color: BambooInk.ink700,
              ),
            ),
            Material(
              color: Colors.transparent,
              child: Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  minTileHeight: 44,
                  title: Text(
                    'Show original SMS',
                    style: BambooFonts.ui(
                      12.5,
                      weight: FontWeight.w600,
                      color: BambooInk.jade,
                    ),
                  ),
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpace.sm),
                      decoration: BoxDecoration(
                        color: BambooInk.paperMuted,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: SelectableText(
                        _maskLongDigits(message.body),
                        style: BambooFonts.ui(12, color: BambooInk.ink900),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'The original SMS stays on this phone and is never sent to PandaPay.',
                      style: BambooFonts.ui(10.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
            ),
          ] else
            Text(
              key == null || key.isEmpty
                  ? 'Added by you, so there is no bill SMS to show.'
                  : 'The original bill SMS is not on this phone.',
              style: BambooFonts.ui(12, color: BambooInk.ink500),
            ),
          if (payId != null && payId.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            const Divider(height: 1, color: BambooInk.hairlineOnPaper),
            const SizedBox(height: AppSpace.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  final router = GoRouter.of(context);
                  onBeforeNavigate?.call();
                  router.push('/activity/${Uri.encodeComponent(payId)}');
                },
                icon: const Icon(Icons.receipt_long_outlined, size: 16),
                label: Text(
                  paidOn == null
                      ? 'View payment & receipt'
                      : 'View payment (${DateFormat('d MMM').format(paidOn!)}) & receipt',
                ),
                style: TextButton.styleFrom(
                  foregroundColor: BambooInk.jade,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  minimumSize: const Size(44, 44),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
