import 'package:pandapay_domain/sms_v2.dart';
import 'package:uuid/uuid.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/local_first/command_outbox.dart';
import '../../../data/local_first/pending_overlays.dart' show OverlayCommand;
import '../../../data/user_cards_repository.dart';

/// The last successfully applied instrument is explicit input. Persist it in
/// the caller's local state; a process restart must not erase manual-edit guards.
class CardStateAdapter {
  /// With [commands] and [store] the learned value is written to the phone's
  /// card first and sent by the command outbox (retried, visible in the sync
  /// status); without them it is a direct call (tests).
  const CardStateAdapter(
    this.repository, {
    this.commands,
    this.store,
    this.namespace,
  });
  final UserCardsRepository repository;
  final CommandOutbox? commands;
  final FinancialStore? store;
  final String? namespace;

  Future<bool> apply(
    Instrument instrument,
    UserCard current, {
    Instrument? lastApplied,
  }) async {
    if (instrument.kind != InstrumentKind.creditCard ||
        instrument.userCardId != current.id) {
      return false;
    }
    final previous = lastApplied?.userCardId == current.id ? lastApplied : null;
    double? limit, points;
    if (instrument.creditLimitSource == CreditLimitSource.sms &&
        instrument.creditLimitMinor != null &&
        (current.creditLimit == null ||
            previous?.creditLimitMinor == current.creditLimit?.paise) &&
        (previous?.creditLimitAt == null ||
            instrument.creditLimitAt != null &&
                !instrument.creditLimitAt!.isBefore(
                  previous!.creditLimitAt!,
                )) &&
        instrument.creditLimitMinor != current.creditLimit?.paise) {
      limit = instrument.creditLimitMinor! / 100;
    }
    if (instrument.pointsBalance != null &&
        (current.pointsBalance == null ||
            previous?.pointsBalance == current.pointsBalance) &&
        (previous?.pointsAt == null ||
            instrument.pointsAt != null &&
                !instrument.pointsAt!.isBefore(previous!.pointsAt!)) &&
        instrument.pointsBalance != current.pointsBalance) {
      points = instrument.pointsBalance!.toDouble();
    }
    if (limit == null && points == null) return false;
    final outbox = commands, local = store, ns = namespace;
    if (outbox != null && local != null && ns != null) {
      local.patchCard(ns, current.id, {
        'credit_limit_inr': ?limit,
        'points_balance': ?points,
      });
      if (limit != null) {
        outbox.enqueue(
          kind: 'card_fields_patch', // CardCommand.patchCardFields (UI file; not imported here)
          target: current.id,
          payload: {'cardId': current.id, 'creditLimitInr': limit},
        );
      }
      if (points != null) {
        outbox.enqueue(
          kind: OverlayCommand.pointsAdjust,
          target: current.id,
          payload: {
            'userCardId': current.id,
            'newBalance': points,
            'clientMutationId': const Uuid().v4(),
          },
        );
      }
      local.notifyExternalChanges(ns, const ['cards']);
      return true;
    }
    await repository.updateCard(
      current.id,
      creditLimitInr: limit,
      pointsBalance: points,
    );
    return true;
  }
}
