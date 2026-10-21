import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  const outputDirectory = 'build/referral-showcase';
  Directory(outputDirectory).createSync(recursive: true);
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      File('$outputDirectory/$name.png').writeAsBytesSync(bytes);
      return true;
    },
  );
}
