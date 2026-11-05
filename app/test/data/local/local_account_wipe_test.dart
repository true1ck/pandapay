import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/local_account_wipe.dart';

void main() {
  test('runs files, keys, widgets in that order', () async {
    final order = <String>[];
    await LocalAccountWipe(
      deleteFiles: () async => order.add('files'),
      destroyKeys: () async => order.add('keys'),
      clearWidgets: () async => order.add('widgets'),
    ).run();
    expect(order, ['files', 'keys', 'widgets']);
  });

  test('a failing step does not stop the others and is reported', () async {
    final order = <String>[];
    await expectLater(
      LocalAccountWipe(
        deleteFiles: () async => throw StateError('disk'),
        destroyKeys: () async => order.add('keys'),
        clearWidgets: () async => throw StateError('widget'),
      ).run(),
      throwsA(
        isA<LocalWipeIncomplete>().having((e) => e.failedSteps, 'failedSteps', [
          'files',
          'widgets',
        ]),
      ),
    );
    expect(order, ['keys']);
  });
}
