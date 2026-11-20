import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/ios_sms_intake_controller.dart';
import 'package:pandapay/features/sms_import/live_alert_status.dart';

IosSmsIntakeState _state({
  List<Map<String, Object?>> jobs = const [],
  List<Map<String, Object?>> windows = const [],
  int pending = 0,
  bool processing = false,
  Map<String, Object?> extra = const {},
}) => IosSmsIntakeState(
  snapshot: {
    'enabled': true,
    'pending': pending,
    'jobs': jobs,
    'windows': windows,
    ...extra,
  },
  processing: processing,
);

const _plan = {'id': 'c', 'kind': 'catchup', 'state': 'active'};
Map<String, Object?> _window(
  String state, {
  int received = 0,
  String job = 'c',
}) => {
  'id': 'w-$state',
  'job_id': job,
  'state': state,
  'enumerated': received,
  'ordinal': 0,
  'start': '2026-11-19T18:30:00Z',
  'end': '2026-11-20T18:30:00Z',
};

void main() {
  group('an idle catch-up plan is not an import', () {
    test(
      'nothing in the card or the strip while no range ever received a message',
      () {
        final s = _state(jobs: [_plan], windows: [_window('waiting')]);
        expect(s.catchUpIdle, isTrue);
        expect(s.showsImportCard, isFalse);
        expect(s.visible, isFalse);
        expect(s.label, 'Recent messages checked');
      },
    );

    test('saved messages waiting for the app say so', () {
      final s = _state(jobs: [_plan], windows: [_window('queued')], pending: 2);
      expect(s.visible, isTrue);
      expect(s.label, '2 messages waiting to be added');
      expect(_state(pending: 1).label, '1 message waiting to be added');
    });

    test('processing alone still shows the strip', () {
      final s = _state(
        jobs: [_plan],
        windows: [_window('waiting')],
        processing: true,
      );
      expect(s.visible, isTrue);
      expect(s.label, 'Updating recent activity…');
    });

    test(
      'a catch-up whose range received messages is shown, and named for what it is',
      () {
        final s = _state(
          jobs: [_plan],
          windows: [_window('running', received: 3)],
        );
        expect(s.catchUpIdle, isFalse);
        expect(s.showsImportCard, isTrue);
        expect(s.visible, isTrue);
        expect(s.label, startsWith('Checking for missed messages'));
      },
    );

    test('a stopped catch-up range needs the person, so it stays visible', () {
      final s = _state(jobs: [_plan], windows: [_window('partial')]);
      expect(s.showsImportCard, isTrue);
    });

    test('a paused plan stays visible', () {
      final s = _state(
        jobs: [
          {'id': 'c', 'kind': 'catchup', 'state': 'paused'},
        ],
        windows: [_window('waiting')],
      );
      expect(s.showsImportCard, isTrue);
    });

    test('a history import is always shown, whatever its ranges are doing', () {
      final s = _state(
        jobs: [
          {'id': 'h', 'kind': 'history', 'state': 'active'},
        ],
        windows: [_window('waiting', job: 'h')],
      );
      expect(s.catchUpIdle, isFalse);
      expect(s.showsImportCard, isTrue);
      expect(s.visible, isTrue);
      expect(s.label, startsWith('Importing history'));
    });

    test('an error keeps the strip', () {
      final s = IosSmsIntakeState(
        snapshot: {
          'enabled': true,
          'jobs': [_plan],
          'windows': [_window('waiting')],
        },
        error: 'Shortcuts stopped.',
      );
      expect(s.visible, isTrue);
    });
  });

  group('live counters from the phone', () {
    test('are read from the snapshot', () {
      final s = _state(
        extra: {
          'live_total': 44,
          'live_today': 8,
          'enabledAt': '2026-11-13T17:01:26.216Z',
          'last_live_intake': 'saved_for_processing',
          'last_live_state': 'committed',
          'last_live_processed': 'captured',
        },
      );
      expect(s.liveTotal, 44);
      expect(s.liveToday, 8);
      expect(s.enabledAt, DateTime.utc(2026, 11, 13, 17, 1, 26, 216).toLocal());
      expect(s.lastLiveIntake, 'saved_for_processing');
      expect(s.lastLiveProcessed, 'captured');
      expect(_state().liveTotal, 0);
    });
  });

  group('Live alerts card text', () {
    final now = DateTime(2026, 11, 20, 20, 5);
    LiveAlertStatus of({
      int total = 0,
      int today = 0,
      int waiting = 0,
      DateTime? since,
      String? intake,
      String? lastState,
      String? processed,
      DateTime? last,
    }) => LiveAlertStatus.of(
      enabled: true,
      lastLiveAt: last ?? DateTime(2026, 11, 20, 19, 51),
      now: now,
      total: total,
      today: today,
      waiting: waiting,
      since: since,
      intake: intake,
      lastState: lastState,
      processed: processed,
    );

    test('counts what was captured, since when, and today', () {
      expect(
        of(total: 44, today: 8, since: DateTime(2026, 11, 13, 22, 31)).counts,
        '44 messages captured since 13 Nov · 8 today',
      );
      expect(
        of(total: 1, since: DateTime(2026, 11, 13)).counts,
        '1 message captured since 13 Nov',
      );
      expect(of(total: 5).counts, '5 messages captured');
      expect(of().counts, isNull);
    });

    test('says what became of the last message', () {
      expect(
        of(
          intake: 'saved_for_processing',
          lastState: 'committed',
          processed: 'captured',
        ).lastResult,
        'Saved',
      );
      expect(
        of(
          intake: 'saved_for_processing',
          lastState: 'committed',
          processed: 'review',
        ).lastResult,
        'Needs your review',
      );
      expect(
        of(
          intake: 'saved_for_processing',
          lastState: 'committed',
          processed: 'ignored',
        ).lastResult,
        'Not a bank message, skipped',
      );
      expect(
        of(
          intake: 'saved_for_processing',
          lastState: 'committed',
          processed: 'existing',
        ).lastResult,
        'Already saved',
      );
      expect(
        of(intake: 'saved_for_processing', lastState: 'pending').lastResult,
        'Saved, waiting to be added',
      );
      expect(
        of(intake: 'excluded_security').lastResult,
        'Security code, ignored and never saved',
      );
      expect(of(intake: 'invalid_body').lastResult, 'Empty message, skipped');
      expect(of().lastResult, isNull);
    });

    test('waiting messages are counted', () {
      expect(of(waiting: 2).waitingNote, '2 waiting to be added');
      expect(of().waitingNote, isNull);
    });

    test('the quiet and off states keep their words', () {
      expect(
        LiveAlertStatus.of(enabled: false, lastLiveAt: null, now: now).counts,
        isNull,
      );
    });
  });
}
