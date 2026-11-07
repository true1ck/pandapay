import '../contract/event.dart';
import '../contract/interfaces.dart';

/// A [LinkContext] with the inputs the frozen interface has no field for.
///
/// WP-05 asks for `instrumentIdByFactId` in the context; the frozen
/// [LinkContext] (WP-01) only has facts, open events and instruments, so the
/// extra inputs live here. The linker accepts a plain [LinkContext] too, with
/// the limits described on [knownEvents].
class RuleLinkContext extends LinkContext {
  const RuleLinkContext({
    required super.recentFacts,
    required super.openEvents,
    required super.instrumentsById,
    this.instrumentIdByFactId = const {},
    this.knownEvents = const [],
    this.ownerNames = const [],
  });

  /// The account owner's own names (the profile name). A payment to or from a
  /// person with one of these names is the owner moving their own money. A
  /// one-word name is ignored, because a first name alone is not enough.
  final List<String> ownerNames;

  /// The instrument each fact resolved to (WP-04's resolver). A fact missing
  /// here is matched by its mention against `instrumentsById`.
  final Map<String, String> instrumentIdByFactId;

  /// Every stored event that has a leg among `recentFacts`, in any status.
  ///
  /// With these the linker knows which recent facts are already joined, so it
  /// can extend a one-leg event when the other leg arrives later (a transfer
  /// credit seen before its debit, a card "payment received" before the bank
  /// debit). With a plain [LinkContext] a recent fact that is not a leg of an
  /// open event is never joined, except receipts, mandates and refund
  /// originals, which do not make money events of their own.
  final List<Event> knownEvents;
}
