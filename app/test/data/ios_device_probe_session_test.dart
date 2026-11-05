import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_device_probe_session.dart';
import 'package:pandapay/data/local/app_database.dart';

void main() {
  test(
    'distinct records preserve sender/body/date association and inference evidence',
    () {
      final session = IosDeviceProbeSession(openInMemoryForTesting());
      addTearDown(session.dispose);
      session.accept([
        {
          'id': 'one',
          'runId': 'run',
          'sender': 'VM-ICICIB',
          'body': 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.',
          'receivedAt': '2026-09-01T00:00:00Z',
        },
        {
          'id': 'two',
          'runId': 'run',
          'sender': '',
          'body': 'INR 450 spent on ICICI Bank Card XX7788 at UBER.',
          'receivedAt': '2026-09-02T00:00:00Z',
        },
        {
          'id': 'missing',
          'runId': 'run',
          'sender': '',
          'body':
              'INR 600 spent on ICICI Bank Card XX7788 at CAFE on 03-03-2026.',
        },
      ]);
      final sources = session.retainedInputs;
      expect(sources, hasLength(2));
      final uber = sources.singleWhere(
        (source) => source.body.contains('UBER'),
      );
      expect(uber.date, DateTime.utc(2026, 9, 2));
      expect(uber.senderInferred, isTrue);
      expect(session.missingDate, 1);
      expect(session.runs['run']!.missingDate, 1);
    },
  );
}
