import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/connectivity/reachability.dart';

void main() {
  late DateTime now;
  late int probes;
  late bool radio;
  Future<bool> Function() probeBody = () async => true;

  ServerReachability build({
    Duration timeout = const Duration(milliseconds: 50),
  }) => ServerReachability(
    probe: () {
      probes++;
      return probeBody();
    },
    radioUp: () => radio,
    now: () => now,
    timeout: timeout,
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 13, 10);
    probes = 0;
    radio = true;
    probeBody = () async => true;
  });

  test('unknown until probed; never blocks or probes by itself', () {
    final r = build();
    expect(r.serverReachable, isNull);
    expect(r.shouldSkipBackgroundReads, isFalse);
    expect(probes, 0);
  });

  test(
    'a successful probe is cached for ~20 s then expires to unknown',
    () async {
      final r = build();
      expect(await r.check(), isTrue);
      expect(r.serverReachable, isTrue);
      expect(await r.check(), isTrue);
      expect(probes, 1);

      now = now.add(const Duration(seconds: 19));
      expect(r.serverReachable, isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(r.serverReachable, isNull);
      expect(await r.check(), isTrue);
      expect(probes, 2);
    },
  );

  test('force bypasses the cache; invalidate drops it', () async {
    final r = build();
    await r.check();
    await r.check(force: true);
    expect(probes, 2);
    r.invalidate();
    expect(r.serverReachable, isNull);
    await r.check();
    expect(probes, 3);
  });

  test(
    'a failed probe is false, skips background reads, expires sooner',
    () async {
      probeBody = () async => false;
      final r = build();
      expect(await r.check(), isFalse);
      expect(r.serverReachable, isFalse);
      expect(r.shouldSkipBackgroundReads, isTrue);

      now = now.add(const Duration(seconds: 9));
      expect(r.serverReachable, isNull);
      expect(r.shouldSkipBackgroundReads, isFalse);
    },
  );

  test(
    'never throws: a throwing or hanging probe is just "unreachable"',
    () async {
      probeBody = () async => throw StateError('boom');
      final r = build();
      expect(await r.check(), isFalse);

      probeBody = () => Completer<bool>().future;
      expect(await r.check(force: true), isFalse);
    },
  );

  test('does not probe while the radio is down', () async {
    radio = false;
    final r = build();
    expect(await r.check(), isFalse);
    expect(probes, 0);
    expect(r.serverReachable, isFalse);
    expect(r.shouldSkipBackgroundReads, isTrue);

    radio = true;
    expect(r.serverReachable, isNull);
    expect(await r.check(), isTrue);
    expect(probes, 1);
  });

  test('concurrent callers share one probe', () async {
    final gate = Completer<bool>();
    probeBody = () => gate.future;
    final r = build(timeout: const Duration(seconds: 5));
    final a = r.check();
    final b = r.check(force: true);
    expect(probes, 1);
    gate.complete(true);
    expect(await a, isTrue);
    expect(await b, isTrue);
  });

  test('a result that lands after invalidate() is not cached', () async {
    final gate = Completer<bool>();
    probeBody = () => gate.future;
    final r = build(timeout: const Duration(seconds: 5));
    final pending = r.check();
    r.invalidate(); // e.g. the network changed while the probe was in flight
    gate.complete(true);
    expect(await pending, isTrue);
    expect(r.serverReachable, isNull);
  });

  test('changes emits only when the value flips', () async {
    final r = build();
    final seen = <bool>[];
    final sub = r.changes.listen(seen.add);
    await r.check();
    await r.check(force: true);
    probeBody = () async => false;
    await r.check(force: true);
    await Future<void>.delayed(Duration.zero);
    expect(seen, [true, false]);
    await sub.cancel();
  });

  group('httpServerProbe', () {
    test('200 with a JSON object is reachable', () async {
      final client = MockClient((req) async {
        expect(req.url.toString(), 'https://api.example.test/app-status');
        expect(req.headers.containsKey('authorization'), isFalse);
        return http.Response(jsonEncode({'maintenance': false}), 200);
      });
      expect(await httpServerProbe(client, 'https://api.example.test'), isTrue);
    });

    test(
      'captive-portal HTML, 5xx and transport errors are not reachable',
      () async {
        expect(
          await httpServerProbe(
            MockClient((_) async => http.Response('<html>login</html>', 200)),
            'https://api.example.test',
          ),
          isFalse,
        );
        expect(
          await httpServerProbe(
            MockClient((_) async => http.Response('{}', 503)),
            'https://api.example.test',
          ),
          isFalse,
        );
        expect(
          await httpServerProbe(
            MockClient((_) async => throw http.ClientException('no route')),
            'https://api.example.test',
          ),
          isFalse,
        );
      },
    );
  });
}
