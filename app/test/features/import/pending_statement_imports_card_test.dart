import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/app/env.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/data/local/statement_import_outbox.dart';
import 'package:pandapay/data/secure_storage/statement_import_batch_cipher.dart';
import 'package:pandapay/data/statement_import_continuation.dart';
import 'package:pandapay/features/import/pending_statement_imports_card.dart';
import 'package:pandapay/features/import/statement_import_continuation_provider.dart';

class _FixtureCipher implements StatementImportBatchCipher {
  @override
  Future<Uint8List> encrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List plaintext,
  }) async => Uint8List.fromList(plaintext);
  @override
  Future<Uint8List> decrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List ciphertext,
  }) async => Uint8List.fromList(ciphertext);
}

const session = '11111111-2222-4333-8444-555555555555';
const namespace = 'user:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
Map<String, dynamic> payload() => {
  'importKey': 'a' * 64,
  'transactions': [
    {'amountInr': 12.5, 'merchantName': 'Private merchant'},
  ],
};
void main() {
  if (!Env.statementImportContinuationEnabled) {
    testWidgets('disabled card never constructs a queue or sends a request', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            statementImportContinuationProvider.overrideWith(
              (ref) => throw StateError('disabled provider must not be read'),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: PendingStatementImportsCard()),
          ),
        ),
      );
      expect(find.text('Saved file imports'), findsNothing);
    });
    return;
  }
  testWidgets(
    'opening saved imports is read-only; resume sends only on an explicit tap',
    (tester) async {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      var sends = 0;
      final outbox = StatementImportOutbox(
        db,
        namespace: namespace,
        cipher: _FixtureCipher(),
      );
      await outbox.prepare(sessionId: session, payloads: [payload()]);
      final continuation = StatementImportContinuation(
        outbox: outbox,
        checkAccountUnchanged: () {},
        sendPrepared: (body) async {
          sends++;
          expect(jsonEncode(body), contains('Private merchant'));
          return StatementImport(
            id: 'server',
            userCardId: null,
            addedCount: 1,
            statementFrom: DateTime(2026, 10, 1),
            statementTo: DateTime(2026, 10, 1),
            txnCount: 1,
            reconciledCount: 1,
            importedAt: DateTime(2026, 10, 1),
          );
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            statementImportContinuationProvider.overrideWith(
              (ref) async => continuation,
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: PendingStatementImportsCard()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sends, 0);
      expect(outbox.pendingCount, 1);
      expect(find.text('Private merchant'), findsNothing);
      await tester.tap(find.text('Resume saved imports'));
      await tester.pumpAndSettle();
      expect(sends, 1);
      expect(outbox.pendingCount, 0);
      expect(find.textContaining('1 batches confirmed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('discard requires confirmation and never calls the server', (
    tester,
  ) async {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    final outbox = StatementImportOutbox(
      db,
      namespace: namespace,
      cipher: _FixtureCipher(),
    );
    await outbox.prepare(sessionId: session, payloads: [payload()]);
    final continuation = StatementImportContinuation(
      outbox: outbox,
      checkAccountUnchanged: () {},
      sendPrepared: (_) async => throw StateError('discard cannot send'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          statementImportContinuationProvider.overrideWith(
            (ref) async => continuation,
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PendingStatementImportsCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(outbox.pendingCount, 1);
    await tester.tap(find.text('Keep import'));
    await tester.pumpAndSettle();
    expect(outbox.pendingCount, 1);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard remaining'));
    await tester.pumpAndSettle();
    expect(outbox.pendingCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'expired work requires a retained-import action without a failed send first',
    (tester) async {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      var clock = DateTime.utc(2026, 10, 1);
      var sends = 0;
      final outbox = StatementImportOutbox(
        db,
        namespace: namespace,
        cipher: _FixtureCipher(),
        now: () => clock,
      );
      await outbox.prepare(sessionId: session, payloads: [payload()]);
      clock = clock.add(const Duration(days: 15));
      final continuation = StatementImportContinuation(
        outbox: outbox,
        checkAccountUnchanged: () {},
        sendPrepared: (_) async {
          sends++;
          return StatementImport(
            id: 'server',
            userCardId: null,
            addedCount: 1,
            statementFrom: clock,
            statementTo: clock,
            txnCount: 1,
            reconciledCount: 1,
            importedAt: clock,
          );
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            statementImportContinuationProvider.overrideWith(
              (ref) async => continuation,
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: PendingStatementImportsCard()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sends, 0);
      expect(find.text('Resume saved imports'), findsNothing);
      expect(find.text('Continue retained import'), findsOneWidget);
      expect(
        db
            .select('SELECT state FROM statement_import_sessions')
            .single['state'],
        'pending',
        reason: 'Listing is read-only',
      );
      await tester.tap(find.text('Continue retained import'));
      await tester.pumpAndSettle();
      expect(sends, 1);
      expect(outbox.pendingCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
