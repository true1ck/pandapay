import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/sms_learning_privacy.dart';

void main() {
  test('omits credential-bearing messages instead of preserving short codes', () {
    for (final message in [
      'Your OTP is 123456 for the transaction.',
      'Verification code: 4821',
      'Enter your PIN 7392 to continue.',
      'Your one-time password is 654321.',
      'CVV 123 was used for verification.',
    ]) {
      expect(redactSmsLearningText(message), isNull, reason: message);
    }
  });

  test('keeps useful non-credential evidence while masking long identifiers', () {
    expect(
      redactSmsLearningText(
        'Rs. 500 spent at Market on card account 12345678.',
      ),
      'Rs. 500 spent at Market on card account XXXX5678.',
    );
  });
}
