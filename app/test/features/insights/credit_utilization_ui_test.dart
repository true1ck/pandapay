import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/insights/credit_utilization_ui.dart';

void main() {
  test('uses readable utilization bands at the requested thresholds', () {
    expect(CreditUtilizationUi.label(0.30), 'Healthy headroom');
    expect(CreditUtilizationUi.label(0.31), 'Watch utilization');
    expect(CreditUtilizationUi.label(0.50), 'Watch utilization');
    expect(CreditUtilizationUi.label(0.51), 'High utilization');
    expect(CreditUtilizationUi.label(0.75), 'High utilization');
    expect(CreditUtilizationUi.label(0.76), 'Very high utilization');
    expect(CreditUtilizationUi.label(1.01), 'Over the limit');
  });
}
