import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/insights/monthly_savings_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  test('derived savings never renders a negative reward delta', () {
    expect(
      nonNegativeRewardValue(Money.fromRupees(-4088.67)),
      const Money.zero(),
    );
    expect(
      nonNegativeRewardValue(Money.fromRupees(12.34)),
      Money.fromRupees(12.34),
    );
  });
}
