import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../../data/user_cards_repository.dart' show TxnInstrument, UserCard;
import 'follow_up/follow_up.dart';
import 'follow_up/refund_candidates.dart';
import 'voice_action_parser.dart';

/// Points a card can spend by voice: the card's own `totalPointsEarned`, the
/// same number the card screen shows. Bank-credited rows are not part of it, and
/// the server's points correction is measured against the same total, so a
/// redemption saved from here lands on what the user saw.
double voicePointsAvailable(UserCard card) => card.totalPointsEarned;

/// The editable state behind one entry in the review sheet. The parser's
/// draft is the first guess; everything here can be changed by the user or
/// by answering a follow-up question, and saving reads this, not the draft.
class VoiceDraftEditor {
  VoiceDraftEditor(this.draft)
    : type = draft.type,
      amountController = TextEditingController(
        text: draft.amount?.toStringAsFixed(2) ?? '',
      ),
      pointsController = TextEditingController(
        text: draft.points?.toString() ?? '',
      ),
      merchantController = TextEditingController(text: draft.merchant ?? ''),
      noteController = TextEditingController(text: draft.transcript),
      selectedCardId = draft.userCardId,
      selectedCategoryId = draft.categoryId,
      instrument = draft.instrument,
      selectedTagIds = Set<String>.of(draft.tagIds),
      occurredAt = draft.occurredAt;

  final VoiceActionDraft draft;

  /// One identity per entry for the life of the sheet, reused on every Save
  /// attempt so a retry can never make a second transaction (WP-C5).
  final String clientMutationId = const Uuid().v4();

  /// Set once this entry has been written (to the outbox or the command
  /// queue); a retry after a partial failure skips it.
  bool saved = false;
  VoiceActionType type;
  final TextEditingController amountController;
  final TextEditingController pointsController;
  final TextEditingController merchantController;
  final TextEditingController noteController;
  String? selectedCardId;
  String? selectedCategoryId;
  TxnInstrument instrument;
  Set<String> selectedTagIds;

  /// A past day at noon, or null for "now".
  DateTime? occurredAt;

  /// The user picked the day, which settles a future or vague date.
  bool dateConfirmed = false;

  /// The purchase a refund was linked to, if any.
  RefundCandidate? refundOf;
  String? moneyInType;
  bool moneyInHowChosen = false;
  final Set<FollowUpSlot> asked = {};

  /// The kind alternative still on offer; cleared once the user answers or
  /// changes the kind.
  VoiceActionType? kindAlternative;

  void initKindAlternative() {
    for (final a in draft.alternatives) {
      if (a.role == 'kind') kindAlternative = a.type;
    }
  }

  double? get amount =>
      double.tryParse(amountController.text.replaceAll(',', ''));
  int? get points => int.tryParse(pointsController.text.replaceAll(',', ''));

  bool get isMoneyIn => type == VoiceActionType.moneyIn;

  /// Credit-card entries and points redemptions must name a wallet card.
  bool get requiresWalletCard =>
      type == VoiceActionType.pointsRedemption ||
      (type != VoiceActionType.moneyIn &&
          instrument == TxnInstrument.creditCard);

  bool hasWalletCard(List<UserCard> cards) =>
      selectedCardId != null && cards.any((c) => c.id == selectedCardId);

  /// Everything that still stops this entry from being saved, worded for the
  /// user. Recomputed on every build so it follows their edits.
  List<String> currentIssues(List<UserCard> cards) {
    final out = <String>[];
    if (type == VoiceActionType.pointsRedemption) {
      final p = points;
      if (p == null || p <= 0) out.add('Enter the number of points.');
    } else {
      final a = amount;
      if (a == null || a <= 0) {
        out.add(
          draft.isForeign
              ? 'Enter the rupee amount that was charged.'
              : 'Enter an amount greater than ₹0.',
        );
      }
    }
    if (requiresWalletCard && !hasWalletCard(cards)) {
      out.add('Choose the wallet card for this entry.');
    }
    if (!dateConfirmed) {
      if (draft.dateIsFuture) {
        out.add('That date is in the future. Pick the day it happened.');
      }
      if (draft.dateIsVague) {
        out.add(
          'Pick the exact day; I heard “${draft.dateSource ?? 'a stretch of days'}”.',
        );
      }
    }
    return out;
  }

  FollowUpState followUpState({
    required List<UserCard> cards,
    required List<FollowUpChoice> refundChoices,
  }) => FollowUpState(
    type: type,
    amount: amount != null && amount! > 0 ? amount : null,
    foreignCurrency: draft.foreignCurrency,
    foreignAmount: draft.foreignAmount,
    cardNeeded: requiresWalletCard,
    hasCard: hasWalletCard(cards),
    kindAlternative: kindAlternative,
    refundCandidates: refundChoices,
    moneyInTypeChosen: moneyInType != null,
    moneyInHowChosen: moneyInHowChosen,
    cards: [
      for (final c in cards)
        FollowUpChoice(
          c.id,
          '${c.nickname?.isNotEmpty == true ? c.nickname : c.cardName}'
          '${c.last4 == null ? '' : ' ••${c.last4}'}',
        ),
    ],
    asked: asked,
  );

  void dispose() {
    amountController.dispose();
    pointsController.dispose();
    merchantController.dispose();
    noteController.dispose();
  }
}
