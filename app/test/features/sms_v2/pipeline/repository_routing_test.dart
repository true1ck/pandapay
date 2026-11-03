import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pandapay/data/user_cards_repository.dart';

void main() {
  test('both repository SMS entry points use v2 without legacy HTTP', () async {
    var imported = 0;
    final repository = UserCardsRepository(
      apiBaseUrl: 'https://api.invalid',
      accessToken: 'fixture',
      client: MockClient(
        (request) async =>
            throw StateError('Legacy request ${request.url.path}'),
      ),
      onSmsV2Import: (messages, backfill) async {
        imported += messages.length;
        return SmsBatchImportResult(
          imported: messages.length,
          duplicate: 0,
          unparsed: 0,
          invalid: 0,
          errored: 0,
        );
      },
    );
    expect(
      (await repository.logTransactionFromSms(
        sender: 'HDFCBK',
        body: 'synthetic',
      )).parsed,
      isTrue,
    );
    final result = await repository.logTransactionsFromSmsBatch(
      messages: [
        SmsBatchMessage(
          sender: 'HDFCBK',
          body: 'synthetic',
          occurredAt: DateTime.utc(2026, 11),
        ),
      ],
    );
    expect(result.imported, 1);
    expect(imported, 2);
  });
}
