import '../../data/user_cards_repository.dart';

/// The result of comparing requested catalogue products with products already
/// owned by the user. Card ownership is product-level in PandaPay: a camera
/// scan identifies a catalogue product, not a full PAN.
class CardAddPlan {
  final List<String> idsToAdd;
  final List<String> alreadyPresent;

  const CardAddPlan({required this.idsToAdd, required this.alreadyPresent});
}

CardAddPlan planCardAdds(
  Iterable<String> requestedIds,
  Iterable<UserCard> existingCards,
) {
  final ownedIds = existingCards.map((card) => card.cardProductId).toSet();
  final seen = <String>{};
  final idsToAdd = <String>[];
  final alreadyPresent = <String>[];

  for (final id in requestedIds) {
    if (!seen.add(id)) continue;
    if (ownedIds.contains(id)) {
      alreadyPresent.add(id);
    } else {
      idsToAdd.add(id);
    }
  }

  return CardAddPlan(
    idsToAdd: List.unmodifiable(idsToAdd),
    alreadyPresent: List.unmodifiable(alreadyPresent),
  );
}
