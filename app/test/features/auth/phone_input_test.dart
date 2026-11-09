import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/auth/phone_input.dart';

void main() {
  test('every way of typing an Indian mobile number gives the same ten digits', () {
    for (final typed in [
      '9876543210',
      '98765 43210',
      '98765-43210',
      '(98765) 43210',
      '09876543210',
      '919876543210',
      '+919876543210',
      '+91 98765 43210',
      '+91-98765-43210',
      '0091 98765 43210',
      '  9876543210  ',
    ]) {
      expect(indianMobileDigits(typed), '9876543210', reason: typed);
    }
  });

  test('numbers that cannot be an Indian mobile are refused', () {
    for (final typed in [
      '',
      '   ',
      '12345',
      '5876543210',
      '1234567890',
      '987654321',
      '98765432100',
      '9999999999',
      '6666666666',
      'abcdefghij',
      '98765abcde',
      '+44 7911 123456',
      '+1 415 555 2671',
      '9876543210; DROP',
    ]) {
      expect(indianMobileDigits(typed), isNull, reason: typed);
    }
  });

  test('the message asks for a number when empty and explains when wrong', () {
    expect(indianMobileError(''), 'Enter your mobile number.');
    expect(
      indianMobileError('12345'),
      'Enter a valid 10-digit Indian mobile number.',
    );
    expect(indianMobileError('98765 43210'), isNull);
  });
}
