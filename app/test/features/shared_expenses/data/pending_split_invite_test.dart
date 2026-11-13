import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/shared_expenses/data/pending_split_invite.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final token = List.filled(43, 'b').join();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('keeps a valid invite until it is cleared', () async {
    final store = PendingSplitInviteStore();
    expect(await store.read(), isNull);
    await store.capture(token);
    expect(await store.read(), token);
    await store.clear();
    expect(await store.read(), isNull);
  });

  test('ignores malformed tokens and never stores them', () async {
    final store = PendingSplitInviteStore();
    await store.capture('nope');
    await store.capture(null);
    await store.capture('<script>${'a' * 40}');
    expect(await store.read(), isNull);
  });

  test('an invite older than the server lifetime is dropped', () async {
    final store = PendingSplitInviteStore();
    final start = DateTime(2026, 11, 1);
    await store.capture(token, now: start);
    expect(await store.read(now: start.add(const Duration(days: 6))), token);
    expect(await store.read(now: start.add(const Duration(days: 8))), isNull);
    expect(await store.read(now: start), isNull); // already cleared
  });

  test('a newer link replaces the older one', () async {
    final store = PendingSplitInviteStore();
    final other = List.filled(43, 'c').join();
    await store.capture(token);
    await store.capture(other);
    expect(await store.read(), other);
  });

  test('an install-referrer invite is taken once, not at every launch', () async {
    final store = PendingSplitInviteStore();
    await store.captureFromReferrer(token);
    expect(await store.read(), token);
    // Joined: cleared. The referrer still answers the same on the next launch.
    await store.clear();
    await store.captureFromReferrer(token);
    expect(await store.read(), isNull);
    // A different referrer value (reinstall from another invite) still works.
    final other = List.filled(43, 'c').join();
    await store.captureFromReferrer(other);
    expect(await store.read(), other);
  });
}
