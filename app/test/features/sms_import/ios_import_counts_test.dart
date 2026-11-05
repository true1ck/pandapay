import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/ios_sms_intake_controller.dart';

void main() {
  const job = {'id': 'job-1', 'kind': 'history', 'state': 'active'};
  const window = {
    'id': 'w',
    'job_id': 'job-1',
    'state': 'running',
    'enumerated': 3,
    'processed': 1,
    'needs_review': 0,
  };

  test('import-wide counts do not drop when a range is read again', () {
    const state = IosSmsIntakeState(
      snapshot: {
        'jobs': [job],
        'windows': [window],
        'active_counts': {
          'job': 'job-1',
          'saved': 420,
          'processed': 400,
          'review': 2,
        },
      },
    );
    expect(state.importCounts, (saved: 420, processed: 400, review: 2));
  });

  test('older native builds fall back to the range counts', () {
    const state = IosSmsIntakeState(
      snapshot: {
        'jobs': [job],
        'windows': [window],
      },
    );
    expect(state.importCounts, (saved: 3, processed: 1, review: 0));
  });
}
