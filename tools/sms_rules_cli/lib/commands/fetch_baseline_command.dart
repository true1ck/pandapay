import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:pandapay_domain/sms_v2.dart';

/// Downloads the latest published bundle through the admin API into
/// `app/assets/sms_rules/baseline_bundle.json`.
///
/// Auth: `SMS_ADMIN_TOKEN` (sent as a bearer token). Base URL: `--api-url` or
/// `SMS_API_URL`. The bundle is validated before the file is replaced.
class FetchBaselineCommand extends Command<int> {
  FetchBaselineCommand() {
    argParser
      ..addOption('api-url', help: 'API origin, e.g. https://api.example.com. Default: \$SMS_API_URL.')
      ..addOption('path', defaultsTo: '/admin/sms/v2/bundles/latest', help: 'Admin route that returns the latest published bundle.')
      ..addOption('out', abbr: 'o', defaultsTo: 'app/assets/sms_rules/baseline_bundle.json');
  }

  @override
  String get name => 'fetch-baseline';

  @override
  String get description =>
      'Download the latest published rule bundle (SMS_ADMIN_TOKEN) into the app baseline asset.';

  @override
  Future<int> run() async {
    final r = argResults!;
    final token = Platform.environment['SMS_ADMIN_TOKEN'];
    if (token == null || token.isEmpty) {
      stderr.writeln('SMS_ADMIN_TOKEN is not set.');
      return 2;
    }
    final base = (r['api-url'] as String?) ?? Platform.environment['SMS_API_URL'];
    if (base == null || base.isEmpty) {
      stderr.writeln('Pass --api-url or set SMS_API_URL.');
      return 2;
    }
    final uri = Uri.parse(base.replaceFirst(RegExp(r'/+$'), '') + (r['path'] as String));
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(uri);
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        stderr.writeln('fetch failed: HTTP ${res.statusCode} from ${uri.origin}${uri.path}');
        return 1;
      }
      var decoded = jsonDecode(body);
      if (decoded is Map<String, Object?> && decoded['bundle'] is Map<String, Object?>) {
        decoded = decoded['bundle'];
      }
      final RuleBundle bundle;
      try {
        bundle = RuleBundle.fromJson(decoded as Map<String, Object?>);
      } on ContractException catch (e) {
        stderr.writeln('the downloaded bundle breaks the contract: ${e.errors.take(5).join('; ')}');
        return 1;
      }
      final out = File(r['out'] as String);
      out.parent.createSync(recursive: true);
      out.writeAsStringSync('${canonicalJson(bundle.toJson())}\n');
      stdout.writeln('baseline bundle v${bundle.bundleVersion} (${bundle.rules.length} rules) -> ${out.path}');
      return 0;
    } on SocketException catch (e) {
      stderr.writeln('fetch failed: ${e.message}');
      return 1;
    } finally {
      client.close();
    }
  }
}
