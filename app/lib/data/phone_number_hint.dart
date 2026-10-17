import 'package:flutter/services.dart';

/// Opens Android's system phone-number chooser when Google Play services can
/// provide one. The API is best-effort: unsupported platforms, devices
/// without Google Play services, and cancellations all return null.
class PhoneNumberHint {
  static const _channel = MethodChannel('app.pandapay/phone_number_hint');

  static Future<String?> request() async {
    try {
      return await _channel.invokeMethod<String>('request');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
