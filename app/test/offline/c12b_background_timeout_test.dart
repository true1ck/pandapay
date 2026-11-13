import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/data/analytics.dart';
import 'package:pandapay/data/authenticated_http_client.dart';

class _Hang extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

void main() {
  Future<Object?> outcome(http.Client c, {required bool background}) async {
    final client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: _Hang(),
    );
    Future<Object?> go() async {
      try {
        await client.get(Uri.parse('https://api.example.test/cards'));
        return null;
      } catch (e) {
        return e;
      }
    }
    return background ? AuthenticatedHttpTimeoutPolicy.runBackground(go) : go();
  }

  test('background policy fails a hung read at 6 s; default waits 15 s', () {
    fakeAsync((fa) {
      Object? bg;
      Object? std;
      unawaited(outcome(http.Client(), background: true).then((v) => bg = v));
      unawaited(outcome(http.Client(), background: false).then((v) => std = v));
      fa.elapse(const Duration(seconds: 7));
      expect(bg, isA<TimeoutException>());
      expect(std, isNull);
      fa.elapse(const Duration(seconds: 10));
      expect(std, isA<TimeoutException>());
    });
  });

  test('analytics flush gives up after 8 s and keeps the events', () {
    fakeAsync((fa) {
      final a = Analytics(apiBaseUrl: 'https://api.example.test', tokenReader: () => null, client: _Hang());
      a.track(AnalyticsEvent.appOpened);
      var done = false;
      unawaited(a.flush().then((_) => done = true));
      fa.elapse(const Duration(seconds: 7));
      expect(done, isFalse);
      fa.elapse(const Duration(seconds: 2));
      expect(done, isTrue);
    });
  });
}
