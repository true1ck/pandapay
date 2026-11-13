import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../data/user_cards_repository.dart';

/// The label a transaction carries so it is never mistaken for plain spending or
/// money in: Refund, Reversal, Self transfer, Family transfer, Card bill,
/// Wallet top-up.
///
/// One place decides which label a transaction has, and every screen that shows
/// a transaction asks it, so the same payment reads the same everywhere. The
/// decision comes from fields the transaction already carries (its note and
/// `transferType`), not from the wording of the merchant.
enum TxnBadgeKind {
  refund('Refund'),
  reversal('Reversal'),
  selfTransfer('Self transfer'),
  familyTransfer('Family transfer'),
  cardBill('Card bill'),
  walletTopup('Wallet top-up');

  const TxnBadgeKind(this.label);
  final String label;

  /// The badges for money that moved between people or accounts and is left out
  /// of spending and money in (as opposed to a refund or a reversal).
  bool get isTransfer => switch (this) {
    refund || reversal => false,
    _ => true,
  };
}

/// The badge [entry] carries, or null for an ordinary payment.
TxnBadgeKind? txnBadgeKind(TransactionEntry entry) {
  final note = entry.note;
  if (note != null && note.contains('[ignored: refund]')) {
    return TxnBadgeKind.refund;
  }
  if (note != null && note.contains('[ignored: reversal]')) {
    return TxnBadgeKind.reversal;
  }
  if (entry.entryKind != TxnEntryKind.transfer) return null;
  if (entry.isFamilyTransfer) return TxnBadgeKind.familyTransfer;
  if (entry.isSelfTransfer) return TxnBadgeKind.selfTransfer;
  return switch (entry.transferType) {
    'card_bill' => TxnBadgeKind.cardBill,
    'wallet' => TxnBadgeKind.walletTopup,
    _ => null,
  };
}

/// The badge as plain text, for places that cannot draw a pill (exports,
/// reports, spoken answers). Null for an ordinary payment.
String? txnBadgeLabel(TransactionEntry entry) => txnBadgeKind(entry)?.label;

/// The small pill beside a transaction's title.
class TransactionBadge extends StatelessWidget {
  const TransactionBadge({super.key, required this.entry, this.kind});

  final TransactionEntry entry;

  /// When the caller already worked the kind out.
  final TxnBadgeKind? kind;

  @override
  Widget build(BuildContext context) {
    final k = kind ?? txnBadgeKind(entry);
    if (k == null) return const SizedBox.shrink();
    return TransactionBadgePill(kind: k);
  }
}

/// The pill itself, for a caller that has a kind and no entry.
class TransactionBadgePill extends StatelessWidget {
  const TransactionBadgePill({super.key, required this.kind, this.margin})
    : _plain = null;

  /// A neutral pill with its own wording ("Transfer", "Payment"): the cue a
  /// payee-first title gives when no specific badge applies.
  const TransactionBadgePill.plain(String label, {super.key, this.margin})
    : kind = null,
      _plain = label;

  final TxnBadgeKind? kind;
  final String? _plain;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    // Jade and amber stay reserved for the Refund and Reversal money moves; the
    // transfer badges are neutral.
    final label = _plain ?? kind!.label;
    final (tint, fill, border, text) = switch (kind) {
      TxnBadgeKind.refund => (BambooInk.jade, 0.12, 0.3, BambooInk.jade),
      TxnBadgeKind.reversal => (BambooInk.amber, 0.15, 0.35, BambooInk.amber),
      _ => (BambooInk.ink900, 0.07, 0.14, BambooInk.ink700),
    };
    return Semantics(
      label: label,
      child: Container(
        margin: margin ?? const EdgeInsets.only(top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: fill),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: tint.withValues(alpha: border), width: 0.8),
        ),
        child: Text(
          label,
          style: BambooFonts.ui(10.5, weight: FontWeight.w700, color: text),
        ),
      ),
    );
  }
}
