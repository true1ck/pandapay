import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/cards/card_detail_screen.dart';

void main() {
  test('returns true when the launcher opens the link', () async {
    Uri? opened;
    final ok = await tryOpenExternalUrl(
      'https://www.example.com/',
      launcher: (uri) async {
        opened = uri;
        return true;
      },
    );
    expect(ok, isTrue);
    expect(opened, Uri.parse('https://www.example.com/'));
  });

  test('returns false when nothing can handle the link', () async {
    expect(
      await tryOpenExternalUrl('https://www.example.com/', launcher: (_) async => false),
      isFalse,
    );
  });

  test('swallows a platform failure instead of throwing', () async {
    expect(
      await tryOpenExternalUrl(
        'https://www.example.com/',
        launcher: (_) async => throw PlatformException(code: 'ACTIVITY_NOT_FOUND'),
      ),
      isFalse,
    );
  });

  test('swallows a malformed url', () async {
    expect(
      await tryOpenExternalUrl('http://[bad', launcher: (_) async => true),
      isFalse,
    );
  });
}
