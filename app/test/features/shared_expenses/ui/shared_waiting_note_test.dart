import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_waiting_note.dart';

const _id = '44444444-4444-4444-8444-444444444444';
const _ctx = '33333333-3333-4333-8333-333333333333';

SharedWaitingChange _change(
  SharedWaitReason reason, {
  int? retryAt,
  SharedCommandState state = SharedCommandState.pending,
}) => SharedWaitingChange(
  SharedQueuedCommand(
    SharedCommand(
      operationId: _id,
      kind: 'expense.propose',
      payload: {'contextId': _ctx, 'title': 'Taxi'},
    ),
    state,
    0,
    null,
  ),
  reason,
  retryAt,
);

void main() {
  final now = DateTime(2026, 11, 18, 10);

  test('nothing waiting says nothing', () {
    expect(sharedWaitingNote(const [], 0), isNull);
    expect(sharedWaitingNote([_change(SharedWaitReason.due)], 0), isNull);
  });

  test('each reason is said in plain words, with the change named', () {
    String note(SharedWaitReason r, {int? retryAt}) =>
        sharedWaitingNote([_change(r, retryAt: retryAt)], 1, now: now)!;
    expect(
      note(SharedWaitReason.sending),
      'Add expense “Taxi”: Sending it now.',
    );
    expect(note(SharedWaitReason.due), contains('goes out in a moment'));
    expect(note(SharedWaitReason.signIn), contains('Sign in again'));
    expect(note(SharedWaitReason.earlierChange), contains('earlier change'));
    expect(note(SharedWaitReason.payment), contains('payment to be matched'));
    expect(
      note(SharedWaitReason.splitUnavailable),
      contains('not available on this phone'),
    );
  });

  test('a busy server says when it will try again', () {
    final soon = now.add(const Duration(seconds: 30)).millisecondsSinceEpoch;
    final later = now.add(const Duration(minutes: 4)).millisecondsSinceEpoch;
    expect(
      sharedWaitingNote(
        [_change(SharedWaitReason.retryLater, retryAt: soon)],
        1,
        now: now,
      ),
      contains('in a minute'),
    );
    expect(
      sharedWaitingNote(
        [_change(SharedWaitReason.retryLater, retryAt: later)],
        1,
        now: now,
      ),
      contains('about 4 minutes'),
    );
  });

  test('more waiting behind the first is counted', () {
    expect(
      sharedWaitingNote([_change(SharedWaitReason.due)], 3, now: now),
      endsWith('2 more after it.'),
    );
  });
}
