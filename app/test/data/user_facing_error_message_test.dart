import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/api_exception.dart';

void main() {
  test('a validation message from the local edit path reaches the person', () {
    expect(
      userFacingErrorMessage(
        ArgumentError('Choose a confirmed account or card in Needs review'),
      ),
      'Choose a confirmed account or card in Needs review',
    );
  });

  test('an unknown failure still gets the generic copy', () {
    expect(
      userFacingErrorMessage(Exception('boom')),
      'Something went wrong. Try again.',
    );
  });
}
