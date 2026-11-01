import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/self_transfer.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/self_transfer_rules.dart';
import 'package:pandapay/data/local/sms_rule_bundle.dart';
import 'package:pandapay/features/activity/activity_projection.dart';

const body =
    'Sent Rs.10000.00\nFrom HDFC Bank A/C *1797\nTo slice small finance bank\nOn 01/11/26\nRef 123456789075';

void main() {
  test(
    'confirmed self-transfer stays visible without inflating incoming or outgoing',
    () {
      final key = selfTransferKey('JX-HDFCBK-T', body)!;
      final rules = {
        key: const SelfTransferDestination(
          accountLast4: '5799',
          bank: 'slcbnk',
        ),
      };
      final entries = [
        for (var i = 0; i < 2; i++)
          LocalSmsParser.parse(
            namespace: 'user:a',
            sender: 'VM-HDFCBK-S',
            body: body.replaceAll('9075', '907$i'),
            receivedAt: DateTime(2026, 11, 1, 11, 8 + i * 2),
            selfTransferRules: rules,
          )!.transaction!,
      ];
      expect(
        entries.every((e) => e.entryKind == TxnEntryKind.transfer),
        isTrue,
      );
      expect(entries.first.merchantName, 'Self-transfer to Slice •5799');
      final projection = ActivityProjection.build(entries);
      expect(projection.totalOutgoing.paise, 0);
      expect(projection.totalIncoming.paise, 0);
      expect(projection.activeCount, 2);
      expect(entries.map((e) => e.id).toSet(), hasLength(2));
      final otherSource = LocalSmsParser.parse(
        namespace: 'user:a',
        sender: 'VM-HDFCBK-S',
        body: body.replaceAll('1797', '2226'),
        receivedAt: DateTime(2026, 11, 1),
        selfTransferRules: rules,
      );
      expect(otherSource!.transaction!.entryKind, TxnEntryKind.spend);
    },
  );

  test(
    'private confirmations survive reopening the repository and never cross profiles',
    () {
      final db = openInMemoryForTesting();
      addTearDown(db.close);
      final repo = SelfTransferRules(db, namespace: 'user:a');
      repo.remember(
        sender: 'JX-HDFCBK-T',
        body: body,
        destination: const SelfTransferDestination(
          accountLast4: '5799',
          bank: 'slcbnk',
        ),
      );
      expect(SelfTransferRules(db, namespace: 'user:a').load(), hasLength(1));
      expect(SelfTransferRules(db, namespace: 'user:b').load(), isEmpty);
      expect(
        selfTransferKey('VM-HDFCBK-S', body),
        selfTransferKey('JX-HDFCBK-T', body),
      );
      expect(
        selfTransferKey('VM-CANBNK-S', body),
        isNot(selfTransferKey('JX-HDFCBK-T', body)),
      );
    },
  );

  test('remote rule snapshots replace only the signed-in profile cache', () {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final repo = SelfTransferRules(db, namespace: 'user:a');
    repo.replaceRemote([
      {
        'sourceSender': 'hdfc',
        'sourceAccountLast4': '1797',
        'party': 'slice small finance bank',
        'bank': 'slcbnk',
        'accountLast4': '5799',
      },
    ]);
    expect(repo.load(), hasLength(1));
    expect(SelfTransferRules(db, namespace: 'user:b').load(), isEmpty);
    repo.replaceRemote(const []);
    expect(repo.load(), isEmpty);
  });

  test('conflicting remote destinations stay pending review', () {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final repo = SelfTransferRules(db, namespace: 'user:a');
    repo.replaceRemote([
      {
        'sourceSender': 'hdfc',
        'sourceAccountLast4': '1797',
        'party': 'slice small finance bank',
        'bank': 'slcbnk',
        'accountLast4': '5799',
      },
      {
        'sourceSender': 'hdfc',
        'sourceAccountLast4': '1797',
        'party': 'slice small finance bank',
        'bank': 'hdfc',
        'accountLast4': '1798',
      },
    ]);
    expect(repo.load(), isEmpty);
  });

  test(
    'downloaded movement rules cannot override a confirmed self-transfer',
    () {
      final downloaded = SmsRuleBundle(
        bundleVersion: 1,
        sha256: '',
        publishedAt: DateTime(2026),
        minClientVersion: '1.0.0',
        rules: [
          RestrictedSmsRule.fromJson({
            'id': 'bank-rule',
            'family': 'posted_movement',
            'senderPattern': 'HDFCBK',
            'regex': r'Paid Rs\.?([0-9]+)\.00\s+From HDFC Bank A/C \*(\d{4})',
            'fieldMap': {'amount': 1, 'accountLast4': 2},
          })!,
        ],
      );
      final confirmed = {
        selfTransferKey('JX-HDFCBK-T', body)!: const SelfTransferDestination(
          accountLast4: '5799',
          bank: 'slcbnk',
        ),
      };
      final result = LocalSmsParser.parse(
        namespace: 'user:a',
        sender: 'JX-HDFCBK-T',
        body: body.replaceFirst('Sent', 'Paid'),
        receivedAt: DateTime(2026, 11, 1),
        downloadedRules: downloaded,
        selfTransferRules: confirmed,
      );
      expect(result?.transaction?.entryKind, TxnEntryKind.transfer);
      expect(result?.reasonCodes, contains('downloaded_rule_match'));
    },
  );
}
