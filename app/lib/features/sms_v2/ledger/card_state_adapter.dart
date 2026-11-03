import 'package:pandapay_domain/sms_v2.dart';
import '../../../data/user_cards_repository.dart';

/// The last successfully applied instrument is explicit input. Persist it in
/// the caller's local state; a process restart must not erase manual-edit guards.
class CardStateAdapter {
  const CardStateAdapter(this.repository);
  final UserCardsRepository repository;

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
    await repository.updateCard(
      current.id,
      creditLimitInr: limit,
      pointsBalance: points,
    );
    return true;
  }
}
