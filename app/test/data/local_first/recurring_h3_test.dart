import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart' show commandHandlersFor;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/data/local_first/pending_overlays.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// H3-5a/b: legacy manual subscription add + clocked edits (WP-S4 contract).
void main() {
  late List<http.Request> seen;
  SpendReportsRepository repo(http.Response Function(http.Request) answer) =>
      SpendReportsRepository(
        apiBaseUrl: 'http://t',
        accessToken: 'tok',
        client: MockClient((r) async {
          seen.add(r);
          return answer(r);
        }),
      );
  setUp(() => seen = []);

  test('create sends id + UTC clock and adopts the server series id', () async {
    final r = repo(
      (_) => http.Response(
        jsonEncode({'id': 'srv-1', 'series': {'id': 'srv-1'}}),
        201,
      ),
    );
    final adopted = await r.createRecurring(
      displayName: 'Streamco',
      amountInr: 199,
      cadenceDays: 30,
      nextExpectedOn: DateTime(2026, 12, 1),
      id: 'local-1',
      clientEditedAt: DateTime.utc(2026, 11, 14, 10),
    );
    expect(adopted, 'srv-1');
    final body = jsonDecode(seen.single.body) as Map;
    expect(body['id'], 'local-1');
    expect(body['clientEditedAt'], '2026-11-14T10:00:00.000Z');
  });

  test('an old server (201 {id}) and a replay (200) are both success', () async {
    var r = repo((_) => http.Response(jsonEncode({'id': 'x'}), 201));
    expect(
      await r.createRecurring(
        displayName: 'A',
        amountInr: 1,
        cadenceDays: 30,
        nextExpectedOn: DateTime(2026, 12, 1),
      ),
      'x',
    );
    r = repo(
      (_) => http.Response(
        jsonEncode({'replayed': true, 'series': {'id': 'local-1'}}),
        200,
      ),
    );
    expect(
      await r.createRecurring(
        displayName: 'A',
        amountInr: 1,
        cadenceDays: 30,
        nextExpectedOn: DateTime(2026, 12, 1),
        id: 'local-1',
      ),
      'local-1',
    );
  });

  test('update and dismiss send the clock; superseded 200 is success', () async {
    final r = repo((_) => http.Response(jsonEncode({'superseded': true}), 200));
    final at = DateTime.utc(2026, 11, 14, 10);
    await r.updateRecurring(
      'id1',
      displayName: 'A',
      amountInr: 1,
      cadenceDays: 30,
      nextExpectedOn: DateTime(2026, 12, 1),
      autopayStatus: 'unknown',
      clientEditedAt: at,
    );
    await r.dismissRecurring('id1', clientEditedAt: at);
    expect((jsonDecode(seen[0].body) as Map)['clientEditedAt'], '2026-11-14T10:00:00.000Z');
    expect((jsonDecode(seen[1].body) as Map)['clientEditedAt'], '2026-11-14T10:00:00.000Z');
  });

  test('a queued create shows on the list until the server has it', () {
    final base = RecurringReport(series: const [], totalAnnual: Money.fromPaise(0));
    final pending = [
      const PendingCommand(
        kind: OverlayCommand.recurringCreate,
        target: 'local-1',
        payload: {
          'id': 'local-1',
          'displayName': 'Streamco',
          'amountInr': 100,
          'cadenceDays': 30,
          'nextExpectedOn': '2026-12-01',
          'autopayStatus': 'unknown',
        },
      ),
    ];
    final shown = overlayRecurring(base, pending);
    expect(shown.series.single.displayName, 'Streamco');
    expect(shown.totalAnnual.paise, greaterThan(0));
    // Once the server list has the same id the row is not doubled.
    final again = overlayRecurring(shown, pending);
    expect(again.series, hasLength(1));
  });

  test('the outbox replays a queued create with its id and clock', () async {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final outbox = CommandOutbox(db, namespace: 'a');
    outbox.enqueue(
      kind: OverlayCommand.recurringCreate,
      target: 'local-1',
      payload: {
        'id': 'local-1',
        'displayName': 'Streamco',
        'amountInr': 100,
        'cadenceDays': 30,
        'nextExpectedOn': '2026-12-01',
        'autopayStatus': 'unknown',
        'clientEditedAt': '2026-11-14T10:00:00.000Z',
      },
    );
    final spend = repo((_) => http.Response(jsonEncode({'id': 'local-1'}), 201));
    final handlers = commandHandlersFor(
      UserCardsRepository(apiBaseUrl: 'http://t', accessToken: 'tok'),
      spend: spend,
    );
    expect(await outbox.flush(handlers), 1);
    final body = jsonDecode(seen.single.body) as Map;
    expect(body['id'], 'local-1');
    expect(body['clientEditedAt'], '2026-11-14T10:00:00.000Z');
  });
}
