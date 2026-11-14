import 'package:flutter/widgets.dart';

import '../../app/design/merchant_brand.dart';
import '../../app/design/merchant_brand_tile.dart';
import '../../app/design/party_avatar.dart';
import '../../data/merchant_identity.dart';
import '../../data/user_cards_repository.dart'
    show TransactionEntry, TxnEntryKind;
import 'transaction_badge.dart';

/// What a transaction's leading tile stands for when it has no brand logo:
///
///  * a person, for a P2P transfer ("Transfer to <name>") or family money;
///  * a shop, for a merchant or company with no logo of its own;
///  * a card, a wallet or the way the money moved, for transfers;
///  * the status, for a refund, a reversal or an ignored row.
///
/// The list row and the detail header both ask here, so they never disagree.
AvatarKind transactionAvatarKind(TransactionEntry entry) {
  final isInvestmentReturn = entry.entryKind == TxnEntryKind.investmentReturn;
  final isIncome = entry.entryKind == TxnEntryKind.income || isInvestmentReturn;
  final isInvestmentCategory =
      entry.categoryId == 'investments' ||
      entry.categoryName?.toLowerCase() == 'investments';
  if (entry.note?.contains('[ignored: refund]') == true) {
    return AvatarKind.refund;
  }
  if (entry.note?.contains('[ignored: reversal]') == true) {
    return AvatarKind.reversal;
  }
  if (entry.status == 'ignored') return AvatarKind.ignored;
  if (isInvestmentCategory ||
      isInvestmentReturn ||
      entry.entryKind == TxnEntryKind.investment) {
    return AvatarKind.investment;
  }
  if (_transferPayee(entry, incoming: isIncome) != null) {
    return AvatarKind.person;
  }
  return switch (txnBadgeKind(entry)) {
    TxnBadgeKind.familyTransfer => AvatarKind.person,
    TxnBadgeKind.cardBill => AvatarKind.card,
    TxnBadgeKind.walletTopup => AvatarKind.wallet,
    TxnBadgeKind.selfTransfer => AvatarKind.transfer,
    _ =>
      entry.entryKind == TxnEntryKind.transfer
          ? AvatarKind.transfer
          : isIncome
          ? AvatarKind.moneyIn
          : AvatarKind.business,
  };
}

/// The brand logo for a transaction, or null: only an ordinary payment to a
/// known merchant gets one. A person, an investment, a refund and the like keep
/// their own avatar even if a name happens to match a brand.
MerchantBrand? transactionBrand(TransactionEntry entry) {
  if (entry.entryKind != TxnEntryKind.spend) return null;
  return transactionAvatarKind(entry) == AvatarKind.business
      ? MerchantBrand.forName(entry.merchantName)
      : null;
}

/// The leading tile for a transaction: its brand logo, else its avatar.
Widget transactionLeading(TransactionEntry entry, {double size = 34}) =>
    MerchantBrandTile(
      brand: transactionBrand(entry),
      size: size,
      fallback: PartyAvatar(transactionAvatarKind(entry), size: size),
    );

String? _transferPayee(TransactionEntry entry, {required bool incoming}) =>
    MerchantIdentity.transferPayee(
      MerchantIdentity.displayName(entry.merchantName, incoming: incoming),
    );
