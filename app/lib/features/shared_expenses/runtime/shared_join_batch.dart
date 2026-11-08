import 'package:uuid/uuid.dart';
import '../data/shared_directory.dart';
import '../data/shared_transport.dart';

/// Most requests approved or declined in one go.
const sharedJoinBatchMax = 25;

/// What happened to a run of approvals or declines. Nothing here holds a phone
/// number; names are only what the owner already sees on the page.
final class SharedBatchOutcome {
  /// Done: the server accepted it, or the person was already in the group.
  final Set<String> done = {};

  /// Subset of [done] that were already members (a retry after a success).
  final Set<String> alreadyIn = {};

  /// The request lapsed or was withdrawn: gone for good.
  final Set<String> expired = {};

  /// Could not be done: id -> plain-language reason. These stay on the page.
  final Map<String, String> failed = {};

  /// Not attempted because the connection dropped.
  final List<String> notRun = [];
  bool stoppedOffline = false;
  int get succeeded => done.length;
  bool get allDone => failed.isEmpty && notRun.isEmpty && expired.isEmpty;
}

/// Codes that mean "this person is already in": a retry after the first call
/// worked on the server but the reply was lost.
bool sharedJoinAlreadyDone(SharedTransportException error) =>
    error.code == 'invitation_conflict' ||
    error.code == 'invitation_already_member';

/// One stable operation id per request, kept in [operationIds] across retries
/// so the server replays an earlier success instead of answering 409.
Future<SharedBatchOutcome> sharedRunJoinBatch({
  required List<SharedJoinRequest> items,
  required Map<String, String> operationIds,
  required Future<String> Function(String invitationId, String operationId)
  respond,
  void Function(int finished, int total)? onProgress,
}) async {
  final outcome = SharedBatchOutcome();
  var finished = 0;
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    onProgress?.call(finished, items.length);
    final opId = operationIds.putIfAbsent(
      item.invitationId,
      () => const Uuid().v4(),
    );
    try {
      await respond(item.invitationId, opId);
      outcome.done.add(item.invitationId);
    } on SharedTransportException catch (error) {
      if (sharedJoinAlreadyDone(error)) {
        outcome.done.add(item.invitationId);
        outcome.alreadyIn.add(item.invitationId);
      } else if (error.code == 'invitation_unavailable') {
        outcome.expired.add(item.invitationId);
      } else if (error.code == 'network_unavailable' ||
          error.code == 'account_changed') {
        outcome.stoppedOffline = true;
        outcome.notRun.addAll([
          for (final rest in items.skip(index)) rest.invitationId,
        ]);
        return outcome;
      } else {
        outcome.failed[item.invitationId] = sharedInviteIssueMessage(error);
      }
    } catch (_) {
      outcome.failed[item.invitationId] =
          'Something went wrong. Please try again.';
    }
    finished++;
  }
  onProgress?.call(finished, items.length);
  return outcome;
}

/// Who "Select all" may tick: the person shared a number, it is not a
/// look-alike, the number still belongs to the same account and is available.
bool sharedJoinSelectAllEligible(SharedJoinRequest r) {
  final p = r.claimantPhone;
  return p != null &&
      p.consent == 'shared' &&
      !p.lookalike &&
      p.numberStatus != 'moved' &&
      p.available;
}

/// Look-alikes must each be approved on their own.
bool sharedJoinBulkAllowed(SharedJoinRequest r) =>
    r.claimantPhone?.lookalike != true;

/// A reason to warn before a bulk approval, or null when nothing stands out.
String? sharedJoinBulkConcern(SharedJoinRequest r) {
  final p = r.claimantPhone;
  if (p == null) return 'details not available';
  if (p.numberStatus == 'moved') return 'has a different number now';
  if (p.consent == 'declined') return 'did not share a number';
  if (p.consent == 'none') return 'number not verified';
  if (p.consent != 'shared' || !p.available) return 'details not available';
  return null;
}
