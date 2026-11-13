import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/queue_retry_policy.dart';
import 'package:pandapay/data/local_first/command_outcomes.dart';

ApiException _json(int status, String code) =>
    ApiException('POST /x failed: $status {"error":"$code"}');

// A gateway / captive portal answer: right status, no server JSON.
ApiException _html(int status) =>
    ApiException('POST /x failed: $status <html>Not Found</html>');

void main() {
  group('account gates are not a refusal of the row (H1-1)', () {
    test('403 phone_required / membership_required do not count or park', () {
      expect(
        classifyQueueFailure(_json(403, 'phone_required')),
        QueueFailure.network,
      );
      expect(
        classifyQueueFailure(_json(403, 'membership_required')),
        QueueFailure.network,
      );
    });

    test('any other 403 is still permanent', () {
      expect(
        classifyQueueFailure(_json(403, 'forbidden')),
        QueueFailure.permanent,
      );
    });
  });

  group('a proxy 404 is not "already gone" (H1-3)', () {
    test('classified as a non-counting network failure', () {
      expect(classifyQueueFailure(_html(404)), QueueFailure.network);
      expect(
        classifyQueueFailure(_json(404, 'budget not found')),
        QueueFailure.permanent,
      );
    });

    test('goneIsDone keeps the command on an HTML 404', () async {
      await expectLater(
        goneIsDone(() async => throw _html(404)),
        throwsA(isA<ApiException>()),
      );
      await goneIsDone(() async => throw _json(404, 'budget not found'));
    });

    test('ignore/restore replays need the server JSON too', () async {
      await expectLater(
        ignoreAlreadyDoneIsDone(() async => throw _html(404), reason: 'x'),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        restoreAlreadyDoneIsDone(() async => throw _html(404)),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        ignoreAlreadyDoneIsDone(
          () async => throw ApiException(
            "POST /x failed: 409 <p>transaction is already 'ignored'</p>",
          ),
          reason: 'x',
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
