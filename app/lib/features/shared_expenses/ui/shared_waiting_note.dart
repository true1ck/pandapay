import '../storage/shared_store.dart';
import 'shared_change_title.dart';

/// The line under "Syncing your latest changes": which saved change is waiting
/// and why, in plain words, so the banner is never a mystery. Null when nothing
/// is waiting. [total] is how many are waiting in all; [waiting] the oldest.
String? sharedWaitingNote(
  List<SharedWaitingChange> waiting,
  int total, {
  DateTime? now,
}) {
  if (waiting.isEmpty || total <= 0) return null;
  final first = waiting.first;
  final why = switch (first.reason) {
    SharedWaitReason.sending => 'Sending it now.',
    SharedWaitReason.due => 'It goes out in a moment.',
    SharedWaitReason.retryLater => _retry(first.retryAt, now ?? DateTime.now()),
    SharedWaitReason.signIn => 'Sign in again to send it.',
    SharedWaitReason.earlierChange =>
      'It is waiting for an earlier change to go first.',
    SharedWaitReason.payment => 'It is waiting for a payment to be matched.',
    SharedWaitReason.splitUnavailable =>
      'The split it belongs to is not available on this phone.',
  };
  final more = total > 1 ? ' ${total - 1} more after it.' : '';
  return '${sharedAttentionTitle(first.queued)}: $why$more';
}

String _retry(int? at, DateTime now) {
  if (at == null) return 'The server did not answer. Trying again shortly.';
  final seconds = ((at - now.millisecondsSinceEpoch) / 1000).ceil();
  if (seconds <= 60) {
    return 'The server did not answer. Trying again in a minute.';
  }
  return 'The server did not answer. Trying again in about '
      '${(seconds / 60).ceil()} minutes.';
}
