import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/pipeline/failure_words.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('each failure kind gets its own fixed word', () {
    expect(failureKind(StateError('x')), 'StateError');
    expect(failureKind(RangeError('x')), 'RangeError');
    expect(failureKind(ArgumentError('x')), 'ArgumentError');
    expect(failureKind(const FormatException('x')), 'FormatException');
    expect(failureKind(UnsupportedError('x')), 'UnsupportedError');
    expect(failureKind(Object()), 'Error');
  });

  test('a state error keeps its own message, with long numbers blanked', () {
    expect(
      describeFailure(StateError('Shared intake has not committed a decision')),
      'StateError: Shared intake has not committed a decision',
    );
    expect(
      describeFailure(StateError('Event 1234567890123 unknown')),
      'StateError: Event # unknown',
    );
  });

  test('a database error says its message and code', () {
    final db = sqlite3.openInMemory();
    try {
      db.execute('SELECT * FROM no_such_table');
      fail('should have thrown');
    } on SqliteException catch (error) {
      expect(describeFailure(error), startsWith('SqliteException: '));
      expect(describeFailure(error), contains('(1)'));
    } finally {
      db.dispose();
    }
  });

  test('a long message is cut and a kind with no message is just the kind', () {
    final long = describeFailure(StateError('a' * 400));
    expect(long.length, lessThan(140));
    expect(describeFailure(const FormatException('secret body text')), 'FormatException');
    expect(describeFailure(Object()), 'Error');
  });

  test('a scrambled stack is cut to offsets and a readable one to file and line', () {
    final scrambled = StackTrace.fromString(
      '#00 abs 0000000102a3b1c7 virt 00000000016a21c7 _kDartIsolateSnapshotInstructions+0x1a2b\n'
      '#01 abs 0000000102a3b2c7 virt 00000000016a22c7 _kDartVmSnapshotInstructions+0xff\n',
    );
    expect(compactStack(scrambled), 'I+0x1a2b V+0xff');
    final readable = StackTrace.fromString(
      '#0      applyCipherKey (package:pandapay/data/local/database_key.dart:32:5)\n'
      '#1      AppDatabase.openFile (package:pandapay/data/local/app_database.dart:592:7)\n',
    );
    expect(compactStack(readable), 'database_key.dart:32 app_database.dart:592');
    expect(compactStack(scrambled, frames: 1), 'I+0x1a2b');
  });
}
