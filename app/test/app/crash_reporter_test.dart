import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/crash_reporter.dart';
import 'package:pandapay/app/obfuscated_trace.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _dsn = 'https://0123456789abcdef0123456789abcdef@errors.example.test/7';

final _stack = StackTrace.fromString('''
#0      ImportModels.parseAmount (package:pandapay/data/import_models.dart:142:7)
#1      _SmsRowState.build (package:pandapay/features/sms_import/sms_row.dart:58:12)
#2      StatelessElement.build (package:flutter/src/widgets/framework.dart:5799:49)
#3      main (file:///Users/someone/private/path/main.dart:3:1)
#4      <asynchronous suspension>
''');

// The shape a release build made with `--obfuscate --split-debug-info`
// prints: a header, then one `abs`/`virt` line per frame. Synthetic values.
final _obfuscatedStack = StackTrace.fromString('''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 4242, tid: 4243, name 1.ui
os: android arch: arm64 comp: yes sim: no
build_id: '0f1e2d3c4b5a69788796a5b4c3d2e1f0'
isolate_dso_base: 7b3c400000, vm_dso_base: 7b3c400000
isolate_instructions: 7b3c410000, vm_instructions: 7b3c404000
    #00 abs 0000007b3c5a1234 virt 00000000001a1234 _kDartIsolateSnapshotInstructions+0x191234
    #01 abs 0000007b3c5a0f10 virt 00000000001a0f10 _kDartIsolateSnapshotInstructions+0x190f10
<asynchronous suspension>
    #02 abs 0000007b3c40a100 virt 000000000000a100 _kDartVmSnapshotInstructions+0x6100
    #03 abs 0000007b3c500000 virt 0000000000100000 /data/app/~~Zx9q==/com.pandapath.pandapay-Ab1/lib/arm64/libapp.so
    #04 abs 0000007b3c5b0000 _kDartIsolateSnapshotInstructions+0x1a0000
''');

CrashReporter _reporter(
  http.Client client, {
  String dsn = _dsn,
  DateTime Function()? clock,
}) => CrashReporter(
  dsn: dsn,
  environment: 'prod',
  client: client,
  release: () async => 'pandapay@1.0.16+105',
  clock: clock,
);

List<Map<String, dynamic>> _lines(String body) => [
  for (final l in body.trim().split('\n'))
    jsonDecode(l) as Map<String, dynamic>,
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('DSN must be https with a public key and a numeric project', () {
    final target = parseDsn(_dsn)!;
    expect(
      target.envelopeUri.toString(),
      'https://errors.example.test/api/7/envelope/',
    );
    expect(target.envelopeUri.userInfo, isEmpty);
    expect(
      target.authHeader,
      contains('sentry_key=0123456789abcdef0123456789abcdef'),
    );
    expect(parseDsn(''), isNull);
    expect(
      parseDsn('http://0123456789abcdef0123456789abcdef@errors.example.test/7'),
      isNull,
    );
    expect(
      parseDsn('http://0123456789abcdef0123456789abcdef@10.0.2.2:8000/7'),
      isNull,
    );
    expect(
      parseDsn(
        'http://0123456789abcdef0123456789abcdef@10.0.2.2:8000/7',
        allowInsecureLocalhost: true,
      ),
      isNotNull,
    );
    expect(parseDsn('https://short@errors.example.test/7'), isNull);
    expect(
      parseDsn(
        'https://0123456789abcdef0123456789abcdef@errors.example.test/abc',
      ),
      isNull,
    );
    expect(
      parseDsn(
        'https://0123456789abcdef0123456789abcdef@errors.example.test/7?x=1',
      ),
      isNull,
    );
  });

  test(
    'a report carries type and code location, never the message or private paths',
    () async {
      final requests = <http.Request>[];
      final reporter = _reporter(
        MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );
      final error = FormatException(
        'Rs 5,000 debited from A/c XX1234 at SWIGGY',
        'sender 9876543210',
      );

      reporter.report(error, _stack, source: 'flutter');
      await reporter.drain();

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(
        request.url.toString(),
        'https://errors.example.test/api/7/envelope/',
      );
      expect(request.headers['content-type'], 'application/x-sentry-envelope');
      for (final secret in [
        '9876543210',
        'debited',
        'XX1234',
        'SWIGGY',
        '5,000',
        '/Users/someone',
      ]) {
        expect(request.body.contains(secret), isFalse, reason: secret);
      }
      final lines = _lines(request.body);
      expect(lines[1], {'type': 'event'});
      final event = lines[2];
      expect(event['release'], 'pandapay@1.0.16+105');
      expect(event['environment'], 'prod');
      expect(event['platform'], 'dart');
      expect(event.containsKey('user'), isFalse);
      expect(event.containsKey('request'), isFalse);
      final exception = (event['exception'] as Map)['values'][0] as Map;
      expect(exception['type'], 'FormatException');
      expect(exception['value'], 'data/import_models.dart:142');
      final frames = ((exception['stacktrace'] as Map)['frames'] as List)
          .cast<Map>();
      expect(
        frames.first['filename'],
        'main.dart',
        reason: 'oldest first, private path cut',
      );
      expect(
        frames.last['filename'],
        'package:pandapay/data/import_models.dart',
      );
      expect(frames.where((f) => f['in_app'] == true), hasLength(2));
    },
  );

  test(
    'an obfuscated release trace sends the build id and frame offsets only',
    () async {
      final requests = <http.Request>[];
      final reporter = _reporter(
        MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );
      final error = FormatException(
        'Rs 5,000 debited from A/c XX1234 at SWIGGY',
        'sender 9876543210',
      );

      reporter.report(error, _obfuscatedStack, source: 'flutter');
      await reporter.drain();

      expect(requests, hasLength(1));
      final body = requests.single.body;
      for (final secret in [
        '9876543210',
        'debited',
        'XX1234',
        'SWIGGY',
        '5,000',
        '4242', // pid
        '4243', // tid
        '1.ui', // thread name
        '7b3c400000', // load base
        '7b3c410000', // instructions start
        '7b3c5a1234', // absolute address
        '/data/app',
        'com.pandapath',
        'libapp.so',
      ]) {
        expect(body.contains(secret), isFalse, reason: secret);
      }

      final event = _lines(body)[2];
      expect(
        (event['tags'] as Map)['build_id'],
        '0f1e2d3c4b5a69788796a5b4c3d2e1f0',
      );
      final exception = (event['exception'] as Map)['values'][0] as Map;
      expect(exception['type'], 'FormatException');
      expect(exception['value'], '_kDartIsolateSnapshotInstructions+0x191234');
      final frames = ((exception['stacktrace'] as Map)['frames'] as List)
          .cast<Map>();
      expect(frames, hasLength(5));
      expect(frames.last, {
        'function': '_kDartIsolateSnapshotInstructions+0x191234',
        'instruction_addr': '0x1a1234',
      }, reason: 'newest frame last, offsets only');
      expect(frames[1], {'instruction_addr': '0x100000'});
      expect(frames.first, {
        'function': '_kDartIsolateSnapshotInstructions+0x1a0000',
      });

      // Ready for `flutter symbolize -i`: header, os/arch, build id and the
      // relative offsets; absolute addresses are zeroed.
      expect((event['extra'] as Map)['obfuscated_trace'], '''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
os: android arch: arm64 comp: yes sim: no
build_id: '0f1e2d3c4b5a69788796a5b4c3d2e1f0'
    #00 abs 0000000000000000 virt 00000000001a1234 _kDartIsolateSnapshotInstructions+0x191234
    #01 abs 0000000000000000 virt 00000000001a0f10 _kDartIsolateSnapshotInstructions+0x190f10
    #02 abs 0000000000000000 virt 000000000000a100 _kDartVmSnapshotInstructions+0x6100
    #03 abs 0000000000000000 virt 0000000000100000 <unknown>
    #04 abs 0000000000000000 _kDartIsolateSnapshotInstructions+0x1a0000
''');
      expect(
        event['fingerprint'],
        contains('0f1e2d3c4b5a69788796a5b4c3d2e1f0'),
        reason: 'offsets only mean something within one build',
      );
    },
  );

  test('obfuscated frames keep only hex offsets and known symbols', () {
    final trace = ObfuscatedTrace.parse('''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 1, tid: 1, name io.flutter.1.ui
os: ios arch: arm64 comp: no sim: no
build_id: 'abcdef0123456789'
    #00 abs 0000000104c1a2b3 _kDartIsolateSnapshotInstructions+0x4c1a2b3 card 4111111111111111
    #01 abs 0000000104c1a2b3 virt zzzz _kDartIsolateSnapshotInstructions+0x10
    #02 abs 0000000104c1a2b3 SWIGGY+0x10
    #03 abs 0000000104c1a2b3 _kDartIsolateSnapshotInstructions+0x20
''')!;
    expect(trace.buildId, 'abcdef0123456789');
    expect(trace.os, 'ios');
    expect(trace.arch, 'arm64');
    expect(trace.frames, hasLength(1), reason: 'only the clean frame line');
    expect(
      trace.frames.single.location,
      '_kDartIsolateSnapshotInstructions+0x20',
    );
    expect(trace.toSymbolizeInput(), isNot(contains('4111')));
    expect(trace.toSymbolizeInput(), isNot(contains('SWIGGY')));
  });

  test('no header or frames means no obfuscated trace', () {
    expect(ObfuscatedTrace.parse(_stack.toString()), isNull);
    expect(ObfuscatedTrace.parse(''), isNull);
    expect(
      ObfuscatedTrace.parse(
        '    #00 abs 0000007b3c5a1234 _kDartIsolateSnapshotInstructions+0x1',
      ),
      isNull,
      reason: 'frames without the header are not trusted',
    );
    expect(
      CrashReporter.parseFrames(_stack).last['filename'],
      'package:pandapay/data/import_models.dart',
      reason: 'the unobfuscated format is unchanged',
    );
  });

  test('repeats are sent once per session and bursts are capped', () async {
    var posts = 0;
    final reporter = _reporter(
      MockClient((_) async {
        posts++;
        return http.Response('{}', 200);
      }),
    );
    for (var i = 0; i < 3; i++) {
      reporter.report(StateError('same'), _stack, source: 'flutter');
      await reporter.drain();
    }
    expect(posts, 1);

    for (var i = 0; i < 15; i++) {
      final stack = StackTrace.fromString(
        '#0      f$i (package:pandapay/x$i.dart:$i:1)',
      );
      reporter.report(StateError('burst'), stack, source: 'zone');
      await reporter.drain();
    }
    expect(
      posts,
      CrashReporter.maxPerMinute,
      reason: 'one per minute window cap',
    );
  });

  test(
    'offline reports are kept and sent on the next start; permanent refusals are dropped',
    () async {
      final offline = _reporter(
        MockClient((_) async => throw http.ClientException('offline')),
      );
      offline.report(ArgumentError('x'), _stack, source: 'platform_dispatcher');
      await offline.drain();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('crash_reporter.queue.v1'), hasLength(1));

      var delivered = 0;
      final online = _reporter(
        MockClient((_) async {
          delivered++;
          return http.Response('{}', 200);
        }),
      );
      online.start();
      await online.drain();
      expect(delivered, 1);
      expect(prefs.getStringList('crash_reporter.queue.v1'), isEmpty);

      final refused = _reporter(
        MockClient((_) async => http.Response('bad', 400)),
      );
      refused.report(RangeError('x'), _stack, source: 'zone');
      await refused.drain();
      expect(prefs.getStringList('crash_reporter.queue.v1'), isEmpty);

      final throttled = _reporter(
        MockClient((_) async => http.Response('slow down', 429)),
      );
      throttled.report(UnsupportedError('x'), _stack, source: 'zone');
      await throttled.drain();
      expect(
        prefs.getStringList('crash_reporter.queue.v1'),
        hasLength(1),
        reason: 'retried later',
      );
    },
  );

  test('old or repeatedly failing reports are discarded', () async {
    var now = DateTime.utc(2026, 11, 1);
    final failing = _reporter(
      MockClient((_) async => http.Response('down', 503)),
      clock: () => now,
    );
    failing.report(StateError('x'), _stack, source: 'zone');
    await failing.drain();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('crash_reporter.queue.v1'), hasLength(1));

    now = now.add(const Duration(days: 8));
    final later = _reporter(
      MockClient((_) async => http.Response('{}', 200)),
      clock: () => now,
    );
    later.start();
    await later.drain();
    expect(prefs.getStringList('crash_reporter.queue.v1'), isEmpty);
  });

  test('without a DSN nothing is stored or sent', () async {
    final reporter = _reporter(
      MockClient((_) async => fail('must not send')),
      dsn: '',
    );
    expect(reporter.enabled, isFalse);
    reporter.start();
    reporter.report(StateError('x'), _stack, source: 'zone');
    await reporter.drain();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('crash_reporter.queue.v1'), isNull);
  });
}
