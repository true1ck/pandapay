import 'dart:convert';
import 'dart:io';

import 'package:pandapay/data/ios_import_prototype_fixtures.dart';

void main() {
  final target = File('test/fixtures/ios_shortcuts_history_100.json');
  target.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(iosPrototypeHistoryFixtures())}\n',
  );
  stdout.writeln('Wrote 100 synthetic messages to ${target.path}');
}
