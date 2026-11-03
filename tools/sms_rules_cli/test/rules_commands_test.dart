import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import '../bin/sms_rules.dart' show commandRegistry;

Future<int> _run(List<String> args) async {
  final runner = CommandRunner<int>('sms_rules', 'test');
  for (final make in commandRegistry.values) {
    runner.addCommand(make());
  }
  return (await runner.run(args)) ?? 0;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('sms_rules_cli_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the four commands are registered', () {
    expect(commandRegistry.keys, containsAll(['build', 'lint', 'sign-dev', 'fetch-baseline']));
  });

  test('build merges the sample folder into a valid canonical bundle', () async {
    final out = '${tmp.path}/bundle.json';
    expect(await _run(['build', '--rules', 'test/sample_rules/good', '--out', out]), 0);
    final text = File(out).readAsStringSync().trim();
    final json = jsonDecode(text) as Map<String, Object?>;
    expect(json['signature'], isNull);
    expect((json['rules'] as List), hasLength(1));
    // canonical: keys sorted, no whitespace
    expect(text, canonicalJson(json));
    // deterministic
    final out2 = '${tmp.path}/bundle2.json';
    await _run(['build', '--rules', 'test/sample_rules/good', '--out', out2]);
    expect(File(out2).readAsStringSync(), File(out).readAsStringSync());
  });

  test('lint is clean on the good folder', () async {
    expect(await _run(['lint', '--rules', 'test/sample_rules/good']), 0);
  });

  test('lint reports the shadowing failure and build fails on it', () async {
    expect(await _run(['lint', '--rules', 'test/sample_rules/shadowed', '--json']), 1);
    expect(await _run(['build', '--rules', 'test/sample_rules/shadowed', '--out', '${tmp.path}/x.json']), 1);
    expect(File('${tmp.path}/x.json').existsSync(), isFalse);
  });

  test('lint finds regex dialect and sender problems', () async {
    final dir = Directory('${tmp.path}/rules')..createSync();
    Directory('${dir.path}/senders').createSync();
    File('${dir.path}/senders/s.json').writeAsStringSync(jsonEncode([
      {'brand': 'HDFCBK', 'issuerSlug': 'hdfc', 'issuerKind': 'bank', 'aliases': <String>[]},
    ]));
    final good = jsonDecode(File('test/sample_rules/good/banks/hdfc.json').readAsStringSync()) as List;
    final r = Map<String, Object?>.of(good.first as Map<String, Object?>);
    r['id'] = 'BAD-REGEX';
    r['senders'] = ['NOSUCH'];
    r['match'] = {
      'pattern': r'^(?<amt>(\d+)+) spent (?<mask>\d{4}) \1',
      'flags': 'i',
    };
    r['examples'] = [
      {'sender': 'VM-NOSUCH-S', 'body': '12 spent 1234 1', 'expectFactTypes': ['movement']},
      {'sender': 'VM-NOSUCH-S', 'body': 'zzz', 'expectFactTypes': <String>[]},
    ];
    File('${dir.path}/r.json').writeAsStringSync(jsonEncode([r]));
    File('${dir.path}/meta.json').writeAsStringSync(jsonEncode({'bundleVersion': 1, 'createdAt': '2026-11-20T00:00:00Z'}));
    expect(await _run(['lint', '--rules', dir.path]), 1);
  });

  test('sign-dev needs a key, then signs a verifiable signature', () async {
    final out = '${tmp.path}/b.json';
    await _run(['build', '--rules', 'test/sample_rules/good', '--out', out]);
    final algo = Ed25519();
    final seed = List<int>.generate(32, (i) => i + 1);
    final key = base64.encode(seed);
    // The command reads the key from the environment, so run it in a child.
    final res = await Process.run(
      'dart',
      ['run', 'bin/sms_rules.dart', 'sign-dev', '--in', out, '--out', '${tmp.path}/signed.json'],
      environment: {'SMS_RULES_DEV_KEY': key},
    );
    expect(res.exitCode, 0, reason: '${res.stderr}');
    final signed = RuleBundle.fromJson(
      jsonDecode(File('${tmp.path}/signed.json').readAsStringSync()) as Map<String, Object?>,
    );
    expect(signed.signature, isNotNull);
    final pub = await (await algo.newKeyPairFromSeed(seed)).extractPublicKey();
    final ok = await algo.verify(
      utf8.encode(signed.signedPayload),
      signature: Signature(base64.decode(signed.signature!.value), publicKey: pub),
    );
    expect(ok, isTrue);

    final noKey = await Process.run(
      'dart',
      ['run', 'bin/sms_rules.dart', 'sign-dev', '--in', out],
      environment: {'SMS_RULES_DEV_KEY': ''},
    );
    expect(noKey.exitCode, 2);
  });

  test('fetch-baseline refuses to run without a token', () async {
    final res = await Process.run(
      'dart',
      ['run', 'bin/sms_rules.dart', 'fetch-baseline', '--api-url', 'http://127.0.0.1:1'],
      environment: {'SMS_ADMIN_TOKEN': ''},
    );
    expect(res.exitCode, 2);
  });

  test('regex parity holds between Dart and Node', () async {
    final node = await Process.run('node', ['--version']);
    if (node.exitCode != 0) {
      markTestSkipped('node is not installed');
      return;
    }
    final res = await Process.run('node', ['test/regex_parity.mjs']);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
