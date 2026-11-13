import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay/features/voice/voice_save.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  test('retrying a Save with the same mutation id keeps one outbox row', () async {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final outbox = TransactionOutboxRepository(db, namespace: 'user:synthetic');
    for (var i = 0; i < 2; i++) {
      await outbox.enqueue(
        amount: Money.fromRupees(40),
        clientMutationId: 'voice-1',
      );
    }
    expect(await outbox.all(), hasLength(1));
  });

  test('partial failure does not duplicate earlier entries and retry only does the rest', () async {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final outbox = TransactionOutboxRepository(db, namespace: 'user:synthetic');
    final ids = ['a', 'b', 'c'];
    final saved = <String>{};
    var failB = true;
    Future<List<int>> run() => saveVoiceEntries<String>(
      ids,
      isSaved: saved.contains,
      markSaved: saved.add,
      save: (id) async {
        if (id == 'b' && failB) throw StateError('disk');
        await outbox.enqueue(amount: Money.fromRupees(1), clientMutationId: id);
      },
    );

    expect(await run(), [1]);
    expect((await outbox.all()).map((e) => e.clientMutationId).toSet(), {'a', 'c'});
    failB = false;
    expect(await run(), isEmpty);
    expect(await outbox.all(), hasLength(3));
  });
}
