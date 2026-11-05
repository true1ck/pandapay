import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/rules_source.dart' show parseUnsignedBundle;
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

  Directory copyGood(String name, String minEngine) {
    final dir = Directory('${tmp.path}/$name')..createSync(recursive: true);
    Directory('test/sample_rules/good').listSync(recursive: true).whereType<File>().forEach((f) {
      final rel = f.path.substring('test/sample_rules/good/'.length);
      File('${dir.path}/$rel')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(f.readAsStringSync());
    });
    File('${dir.path}/meta.json').writeAsStringSync(jsonEncode({'minEngineVersion': minEngine}));
    return dir;
  }

  test('build takes minEngineVersion from meta.json and refuses one this engine cannot read', () async {
    final ok = copyGood('meta_ok', smsEngineVersion);
    final out = '${tmp.path}/meta_ok.json';
    expect(await _run(['build', '--rules', ok.path, '--out', out]), 0);
    expect((jsonDecode(File(out).readAsStringSync()) as Map)['minEngineVersion'], smsEngineVersion);

    final tooNew = copyGood('meta_new', '99.0.0');
    final out2 = '${tmp.path}/meta_new.json';
    expect(await _run(['build', '--rules', tooNew.path, '--out', out2]), 1);
    expect(File(out2).existsSync(), isFalse);
    expect(await _run(['lint', '--rules', tooNew.path]), 1);
  });

  test('the shipped rules require 2.1.0: this engine reads them, an older one refuses them', () async {
    final out = '${tmp.path}/shipped.json';
    expect(await _run(['build', '--rules', '../../rules/sms/v2', '--out', out]), 0);
    final bundle = parseUnsignedBundle(jsonDecode(File(out).readAsStringSync()) as Map<String, Object?>);
    expect(compareSemver(bundle.minEngineVersion, '2.1.0'), greaterThanOrEqualTo(0));
    expect(compareSemver(bundle.minEngineVersion, smsEngineVersion), lessThanOrEqualTo(0));
    expect(() => CompiledBundle.compile(bundle), returnsNormally);
    expect(
      () => CompiledBundle.compile(bundle, engineVersion: '2.0.0'),
      throwsA(isA<BundleRefusedException>().having((e) => e.code, 'code', 'engine_too_old')),
    );
  });

  test('lint rejects an alias in rule and ignore-rule senders', () async {
    final dir = copyGood('alias', smsEngineVersion);
    // The sample registry maps HDFCCC to HDFCBK.
    expect(await _run(['lint', '--rules', dir.path]), 0);
    final ign = [
      {'id': 'IGN-ALIAS', 'senders': ['HDFCCC'], 'pattern': 'promo', 'flags': 'i', 'reason': 'promotion'},
    ];
    File('${dir.path}/ignore_rules.json').writeAsStringSync(jsonEncode(ign));
    expect(await _run(['lint', '--rules', dir.path]), 1);
    ign.single['senders'] = ['HDFCBK'];
    File('${dir.path}/ignore_rules.json').writeAsStringSync(jsonEncode(ign));
    expect(await _run(['lint', '--rules', dir.path]), 0);
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
