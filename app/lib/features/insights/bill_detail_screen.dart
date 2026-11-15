import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart' as v2;

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/commitments_repository.dart';
import '../../data/past_bill_receipts.dart';
import '../../data/premium_reminders.dart';
import '../cards/card_summary.dart';
import '../sms_v2/ledger/providers.dart';
import 'bill_kind_badge.dart';
import 'bill_proof_section.dart';

/// One bill, EMI, SIP or premium on its own page, laid out like a transaction:
/// the amount and name on top, the facts as rows, and the SMS it was detected
/// from underneath, with what was read out of it.
class BillDetailScreen extends ConsumerWidget {
  const BillDetailScreen({
    super.key,
    required this.commitment,
    this.monthOnly,
    this.canAct = true,
    this.kind,
  });

  /// A past bill or receipt, shown on the same page.
  factory BillDetailScreen.past(PastBillReceipt item) => BillDetailScreen(
    commitment: Commitment(
      id: item.id,
      title: item.merchant,
      category: _categoryOf(item),
      amount: item.amount,
      dueOn: item.dueDate ?? item.occurredAt,
      identifier: item.cardLast4 ?? item.accountLast4,
      cadence: CommitmentCadence.oneTime,
      status: switch (item.status) {
        PastBillReceiptStatus.paidLinked ||
        PastBillReceiptStatus.paidUnlinked => CommitmentStatus.paid,
        PastBillReceiptStatus.needsConfirmation =>
          CommitmentStatus.needsConfirmation,
        _ => CommitmentStatus.paymentNotDetected,
      },
      paidOn: item.occurredAt,
      linkedTransactionId: item.linkedTransactionId,
      sourceKey: item.sourceKey,
    ),
    monthOnly: item.dueMonthOnly && item.dueDate != null
        ? SmsMonthOnly(DateTime(item.dueDate!.year, item.dueDate!.month))
        : null,
    canAct: false,
    kind: BillKind.ofPast(item),
  );

  /// An insurance month-only notice that is still ahead.
  factory BillDetailScreen.premium(PremiumReminder r) => BillDetailScreen(
    commitment: Commitment(
      id: r.id,
      title: r.title,
      category: r.category,
      dueOn: r.premiumMonth,
      identifier: r.accountLast4,
      cadence: CommitmentCadence.oneTime,
      sourceKey: r.sourceKey,
    ),
    monthOnly: SmsMonthOnly(r.premiumMonth),
    canAct: false,
  );

  final Commitment commitment;

  /// The month a notice named, when it named no day.
  final SmsMonthOnly? monthOnly;

  /// Mark paid / dismiss, offered only for bills the app keeps.
  final bool canAct;

  /// The badge to show when the category alone cannot say it (a card bill).
  final BillKind? kind;

  static CommitmentCategory _categoryOf(PastBillReceipt item) {
    if (item.categoryName == 'sip') return CommitmentCategory.investment;
    for (final c in CommitmentCategory.values) {
      if (c.name == item.categoryName) return c;
    }
    return CommitmentCategory.other;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = commitment;
    final kind = this.kind ?? item2kind(c);
    final isPaid = c.status == CommitmentStatus.paid;
    final isInsurance = c.category == CommitmentCategory.insurance;
    final fact = _factOf(ref);
    final status = _statusLine(c, isPaid);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        elevation: 0,
        title: Text(
          isInsurance ? 'Premium details' : 'Bill details',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Center(
              child: Column(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: c.category.iconBg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      kind.icon,
                      color: c.category.iconColor,
                      size: 26,
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    c.amount?.format(hidePaise: true) ?? 'Amount not stated',
                    style: BambooFonts.money(26, color: BambooInk.ink900),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    c.title,
                    textAlign: TextAlign.center,
                    style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  BillKindBadge(kind),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            _Row(label: 'Type', value: c.category.label),
            _Row(
              label: isInsurance ? 'Premium due' : 'Due date',
              value: monthOnly != null
                  ? '${DateFormat('MMMM yyyy').format(monthOnly!.month)} · day not stated'
                  : DateFormat('EEEE, d MMMM yyyy').format(c.dueOn),
            ),
            _Row(label: 'Status', value: status),
            if (c.identifier != null && c.identifier!.isNotEmpty)
              _Row(
                label: isInsurance ? 'Policy' : 'Account',
                value: '•••• ${c.identifier}',
              ),
            if (monthOnly == null &&
                c.id.startsWith('v2:') &&
                c.cadence != CommitmentCadence.oneTime)
              _Row(label: 'Repeats', value: c.cadence.label),
            if (isPaid && c.paidOn != null)
              _Row(
                label: 'Paid on',
                value: DateFormat('d MMM yyyy').format(c.paidOn!.toLocal()),
              ),
            if (c.linkedTransactionId != null &&
                c.linkedTransactionId!.isNotEmpty) ...[
              const SizedBox(height: AppSpace.xs),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => context.push(
                    '/activity/${Uri.encodeComponent(c.linkedTransactionId!)}',
                  ),
                  icon: const Icon(Icons.receipt_long_outlined, size: 16),
                  label: const Text('View payment & receipt'),
                  style: TextButton.styleFrom(
                    foregroundColor: BambooInk.jade,
                    minimumSize: const Size(44, 44),
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpace.md),
            _SmsEvidence(commitment: c, fact: fact, monthOnly: monthOnly),
            if (canAct) ...[
              const SizedBox(height: AppSpace.lg),
              _Actions(commitment: c),
            ],
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                const Icon(Icons.security, size: 12, color: BambooInk.ink500),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'PandaPay never opens unverified SMS links. Always pay via your official provider app or website.',
                    style: BambooFonts.ui(10.5, color: BambooInk.ink500),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The fact the row was built from, when it came from one.
  v2.Fact? _factOf(WidgetRef ref) {
    if (!commitment.id.startsWith('v2:') ||
        commitment.id.startsWith('v2:sip:')) {
      return null;
    }
    final id = commitment.id.substring(3);
    final facts = ref.watch(smsV2LedgerReadModelProvider).valueOrNull?.facts;
    if (facts == null) return null;
    for (final f in facts) {
      if (f.factId == id) return f;
    }
    return null;
  }

  static BillKind item2kind(Commitment c) => BillKind.forCommitment(c);

  static String _statusLine(Commitment c, bool isPaid) {
    final insurance = c.category == CommitmentCategory.insurance;
    if (isPaid) return 'Paid';
    return switch (c.status) {
      CommitmentStatus.paymentNotDetected =>
        insurance
            ? 'Past premium · payment not detected'
            : 'Past bill · payment not detected',
      CommitmentStatus.needsConfirmation => 'Needs your confirmation',
      CommitmentStatus.dismissed => 'Dismissed',
      _ => 'Due date recorded · payment status unknown',
    };
  }
}

/// The month a "next premium" notice named.
class SmsMonthOnly {
  const SmsMonthOnly(this.month);
  final DateTime month;
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.md),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: BambooFonts.ui(13.5, color: BambooInk.ink900),
          ),
        ),
      ],
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 132,
          child: Text(
            label,
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: BambooFonts.ui(12.5, color: BambooInk.ink900),
          ),
        ),
      ],
    ),
  );
}

String _maskDigits(String text) => text.replaceAllMapped(
  RegExp(r'\b\d{8,}\b'),
  (m) => '•••• ${m.group(0)!.substring(m.group(0)!.length - 4)}',
);

/// What was read from the message, and the message itself: the same panel the
/// transaction page shows ("SMS evidence").
class _SmsEvidence extends ConsumerWidget {
  const _SmsEvidence({
    required this.commitment,
    required this.fact,
    required this.monthOnly,
  });

  final Commitment commitment;
  final v2.Fact? fact;
  final SmsMonthOnly? monthOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = commitment.sourceKey;
    final manual = key == null || key.isEmpty || key.startsWith('manual-');
    if (manual && commitment.source != CommitmentSource.sms) {
      return const SizedBox.shrink();
    }
    final captured = key == null || key.isEmpty
        ? null
        : ref.watch(billProofSmsProvider(key)).valueOrNull?.message;
    final f = fact;
    int? minor(v2.AmountRole r) =>
        f?.amounts.where((a) => a.role == r).firstOrNull?.minor;
    String money(int paise) => Money.fromPaise(paise).format();
    final received = captured?.receivedAt.toLocal() ?? f?.observedAt.toLocal();

    return CardSummaryPanel(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
          key: const Key('bill-sms-evidence'),
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpace.md,
            0,
            AppSpace.md,
            AppSpace.md,
          ),
          leading: const Icon(Icons.sms_outlined, color: BambooInk.ink500),
          title: Text(
            'SMS evidence',
            style: BambooFonts.ui(
              14,
              weight: FontWeight.w700,
              color: BambooInk.ink900,
            ),
          ),
          subtitle: Text(
            received == null
                ? 'Detected from the SMS'
                : 'Detected from the SMS · ${DateFormat('d MMM yyyy, h:mm a').format(received)}',
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
          children: [
            if (commitment.amount != null)
              _Line('Amount detected', commitment.amount!.format()),
            if (minor(v2.AmountRole.dueMinimum) != null)
              _Line('Minimum due', money(minor(v2.AmountRole.dueMinimum)!)),
            _Line(
              'Date detected',
              monthOnly != null
                  ? DateFormat('MMMM yyyy').format(monthOnly!.month)
                  : DateFormat('d MMM yyyy').format(commitment.dueOn),
            ),
            if (f is v2.BillDueFact && f.statementDate != null)
              _Line('Statement date', f.statementDate!),
            if (f is v2.BillDueFact && f.billerName != null)
              _Line('Biller detected', f.billerName!),
            if (f?.counterparty?.name != null)
              _Line('Name detected', f!.counterparty!.name!),
            if (commitment.identifier != null &&
                commitment.identifier!.isNotEmpty)
              _Line('Account detected', '•••• ${commitment.identifier}'),
            if (captured != null) ...[
              const SizedBox(height: AppSpace.sm),
              _Line('Sender', captured.sender),
              Text(
                'Original SMS captured on this device',
                style: BambooFonts.ui(
                  11.5,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
              const SizedBox(height: AppSpace.xs),
              SelectableText(
                _maskDigits(captured.body),
                style: BambooFonts.ui(12, color: BambooInk.ink900),
              ),
            ],
            const SizedBox(height: AppSpace.sm),
            Text(
              captured != null
                  ? 'The original SMS stays on this phone and is never sent to PandaPay.'
                  : "The original SMS isn't on this phone. The details above came from it when it was first read.",
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
          ],
        ),
      ),
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.commitment});
  final Commitment commitment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = commitment;
    final isPaid = c.status == CommitmentStatus.paid;
    return Column(
      children: [
        if (!isPaid)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () async {
                await ref
                    .read(commitmentsRepositoryProvider)
                    .markAsPaid(
                      c.id,
                      paidOn: DateTime.now(),
                      detectedCommitment: c,
                    );
                ref.invalidate(commitmentsProvider);
                if (context.mounted) {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Marked ${c.title} as paid')),
                  );
                }
              },
              icon: const Icon(Icons.check_circle_outline, size: 18),
              label: const Text('Mark as paid'),
              style: ElevatedButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        const SizedBox(height: AppSpace.sm),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: () async {
              final repository = ref.read(commitmentsRepositoryProvider);
              if (c.source == CommitmentSource.sms) {
                // A derived bill has no saved copy yet: save a dismissed one
                // with its full identity so the next refresh does not bring it
                // back.
                await repository.save(
                  c.copyWith(
                    status: CommitmentStatus.dismissed,
                    isUserConfirmed: true,
                  ),
                );
              } else {
                await repository.delete(c.id);
              }
              ref.invalidate(commitmentsProvider);
              if (context.mounted) Navigator.of(context).pop();
            },
            style: TextButton.styleFrom(foregroundColor: BambooInk.ink700),
            child: Text(
              c.source == CommitmentSource.sms
                  ? 'Dismiss detected bill'
                  : 'Delete commitment',
            ),
          ),
        ),
      ],
    );
  }
}
