import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../rules_source.dart';

/// Signs a bundle with a local development key. For tests only: production
/// signing happens server-side (WP-09), and the private key never leaves the
/// server's secret store.
///
/// `SMS_RULES_DEV_KEY` is a base64 32-byte Ed25519 seed.
class SignDevCommand extends Command<int> {
  SignDevCommand() {
    argParser
      ..addOption('in', abbr: 'i', help: 'Bundle JSON to sign.')
      ..addOption('out', abbr: 'o', help: 'Signed bundle path. Default: overwrite --in.')
      ..addOption('key-id', defaultsTo: 'sms-rules-dev', help: 'keyId written into the signature.')
      ..addFlag('generate-key', negatable: false, help: 'Print a new random development seed and its public key, then exit.');
  }

  @override
  String get name => 'sign-dev';

  @override
  String get description =>
      'Sign a bundle with the local development key in SMS_RULES_DEV_KEY (tests only).';

  @override
  Future<int> run() async {
    final r = argResults!;
    final algo = Ed25519();
    if (r['generate-key'] as bool) {
      final kp = await algo.newKeyPair();
      final seed = await kp.extractPrivateKeyBytes();
      final pub = (await kp.extractPublicKey()).bytes;
      stdout.writeln('SMS_RULES_DEV_KEY=${base64.encode(seed)}');
      stdout.writeln('public key (base64): ${base64.encode(pub)}');
      return 0;
    }
    final input = r['in'] as String? ?? (r.rest.isNotEmpty ? r.rest.first : null);
    if (input == null) usageException('--in is required.');
    final keyText = Platform.environment['SMS_RULES_DEV_KEY'];
    if (keyText == null || keyText.isEmpty) {
      stderr.writeln('SMS_RULES_DEV_KEY is not set. Use --generate-key to make a development key.');
      return 2;
    }
    final List<int> seed;
    try {
      seed = base64.decode(keyText.trim());
    } on FormatException {
      stderr.writeln('SMS_RULES_DEV_KEY is not base64.');
      return 2;
    }
    if (seed.length != 32) {
      stderr.writeln('SMS_RULES_DEV_KEY must decode to a 32-byte Ed25519 seed (got ${seed.length}).');
      return 2;
    }

    final json = jsonDecode(File(input).readAsStringSync()) as Map<String, Object?>;
    json.remove('signature');
    final RuleBundle bundle;
    try {
      bundle = parseUnsignedBundle({...json, 'signature': null});
    } on ContractException catch (e) {
      stderr.writeln('bundle breaks the contract: ${e.errors.take(5).join('; ')}');
      return 1;
    }
    final payload = utf8.encode(bundle.signedPayload);
    final kp = await algo.newKeyPairFromSeed(seed);
    final sig = await algo.sign(payload, keyPair: kp);
    final signed = {
      ...bundle.toJson(),
      'signature': BundleSignature(keyId: r['key-id'] as String, value: base64.encode(sig.bytes)).toJson(),
    };
    final out = File(r['out'] as String? ?? input);
    out.writeAsStringSync('${canonicalJson(signed)}\n');
    stdout.writeln('signed ${out.path} (keyId ${r['key-id']})');
    return 0;
  }
}
