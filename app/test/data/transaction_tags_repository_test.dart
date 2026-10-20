import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/transaction_tags_repository.dart';

void main() {
  test('a pending merge stays merged over an older server snapshot', () async {
    final db = openInMemoryForTesting();
    const source = TransactionTag(id: 'source', name: 'Office');
    const target = TransactionTag(id: 'target', name: 'Work');
    final client = MockClient(
      (request) async => request.method == 'POST'
          ? http.Response('{"error":"try again"}', 409)
          : http.Response(
              jsonEncode({
                'tags': [source.toJson(), target.toJson()],
                'assignments': [
                  {'transactionId': 'txn', 'tagId': 'source'},
                ],
              }),
              200,
            ),
    );
    final repo = TransactionTagsRepository(
      database: db,
      namespace: 'user:one',
      apiBaseUrl: 'http://localhost',
      accessToken: 't',
      client: client,
    );
    await repo.sync();
    await repo.merge(source.id, target.id);
    await repo.sync();
    expect(repo.tagsForTransaction('txn').map((tag) => tag.id), ['target']);
    expect(
      repo.allTags.firstWhere((tag) => tag.id == 'source').isArchived,
      isTrue,
    );
    expect(repo.pendingCount, 1);
    repo.dispose();
    db.close();
  });
  test(
    'offline tags survive repository restart, retain removals and isolate accounts',
    () async {
      final db = openInMemoryForTesting();
      final client = MockClient(
        (_) async => throw http.ClientException('offline'),
      );
      TransactionTagsRepository make(String ns) => TransactionTagsRepository(
        database: db,
        namespace: ns,
        apiBaseUrl: 'http://localhost',
        accessToken: 'test',
        client: client,
      );
      var repo = make('user:one');
      final trip = await repo.create('Thailand trip');
      final office = await repo.create('Office');
      await repo.assign(['txn'], [trip.id, office.id]);
      await repo.unassign(['txn'], [office.id]);
      await repo.sync();
      final pending = repo.pendingCount;
      repo.dispose();
      repo = make('user:one');
      expect(repo.tagsForTransaction('txn').map((t) => t.name), [
        'Thailand trip',
      ]);
      expect(repo.pendingCount, pending);
      final another = make('user:two');
      expect(another.allTags, isEmpty);
      expect(another.tagsForTransaction('txn'), isEmpty);
      another.dispose();
      repo.dispose();
      db.close();
    },
  );
  test(
    'sync is idempotent and an explicit removal overrides stale embedded metadata',
    () async {
      final db = openInMemoryForTesting();
      final serverTags = <String, Map<String, dynamic>>{};
      final links = <String, Map<String, dynamic>>{};
      final mutations = <String>{};
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (mutations.add(body['mutationId'] as String)) {
            if (body['operation'] == 'upsert_tag')
              serverTags[(body['tag'] as Map)['id'] as String] =
                  Map<String, dynamic>.from(body['tag'] as Map);
            if (body['operation'] == 'assign')
              links['${body['transactionId']}:${body['tagId']}'] = {
                'transactionId': body['transactionId'],
                'tagId': body['tagId'],
              };
            if (body['operation'] == 'unassign')
              links.remove('${body['transactionId']}:${body['tagId']}');
          }
          return http.Response('{"ok":true}', 200);
        }
        return http.Response(
          jsonEncode({
            'tags': serverTags.values.toList(),
            'assignments': links.values.toList(),
          }),
          200,
        );
      });
      final repo = TransactionTagsRepository(
        database: db,
        namespace: 'user:one',
        apiBaseUrl: 'http://localhost',
        accessToken: 'test',
        client: client,
      );
      final tag = await repo.create('Office');
      await repo.assign(['txn'], [tag.id]);
      await repo.sync();
      expect(repo.pendingCount, 0);
      expect(repo.tagsForTransaction('txn').single.id, tag.id);
      await repo.replace('txn', {});
      await repo.sync();
      expect(repo.tagsForTransaction('txn', fallback: [tag]), isEmpty);
      await repo.assign(['local-outbox:one'], [tag.id]);
      repo.remapTransaction('local-outbox:one', 'canonical');
      expect(repo.tagsForTransaction('canonical').single.id, tag.id);
      await repo.sync();
      repo.dispose();
      db.close();
    },
  );
  test(
    'archive retains history; case duplicates rejected; merge counts unique assignments',
    () async {
      final db = openInMemoryForTesting();
      final client = MockClient(
        (_) async => throw http.ClientException('offline'),
      );
      final repo = TransactionTagsRepository(
        database: db,
        namespace: 'user:one',
        apiBaseUrl: 'http://localhost',
        accessToken: 't',
        client: client,
      );
      final first = await repo.create('Office');
      final second = await repo.create('Work');
      await expectLater(repo.create(' office '), throwsArgumentError);
      await repo.assign(['one'], [first.id, second.id]);
      await repo.assign(['two'], [first.id]);
      await repo.merge(first.id, second.id);
      await repo.sync();
      expect(repo.usageCount(second.id), 2);
      expect(repo.tagsForTransaction('one').map((t) => t.id), [second.id]);
      await repo.archive(second.id);
      await repo.sync();
      expect(repo.tags, isEmpty);
      expect(repo.tagsForTransaction('two').single.isArchived, isTrue);
      repo.dispose();
      db.close();
    },
  );
}
