import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dartFiles(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  test('SMS v2 is unconditional', () {
    final offenders = _dartFiles('lib')
        .where((f) {
          final text = f.readAsStringSync();
          return text.contains('kSmsPipelineV2') ||
              text.contains('smsPipelineV2EnabledProvider');
        })
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty);
    expect(File('lib/features/sms_v2/flag.dart').existsSync(), isFalse);
  });

  test('no client code can upload raw SMS text', () {
    const banned = [
      '/transactions/from-sms',
      '/transactions/reconcile-sms',
      '/transactions/sms-import-state',
      "'/sms/facts'",
      'logTransactionFromSms',
      'logTransactionsFromSmsBatch',
    ];
    final offenders = <String>[];
    for (final f in _dartFiles('lib')) {
      final text = f.readAsStringSync();
      for (final b in banned) {
        if (text.contains(b)) offenders.add('${f.path}: $b');
      }
    }
    expect(offenders, isEmpty);
  });
}
