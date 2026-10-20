import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/commitments_repository.dart';

void main() {
  test(
    'confirming an old annual bill advances beyond the payment date',
    () async {
      SharedPreferences.setMockInitialValues({});
      final repository = CommitmentsRepository(namespace: 'rollover-test');
      await repository.save(
        Commitment(
          id: 'lic-1',
          title: 'LIC policy',
          category: CommitmentCategory.insurance,
          dueOn: DateTime(2025, 9, 21),
          cadence: CommitmentCadence.annual,
        ),
      );
      await repository.markAsPaid('lic-1', paidOn: DateTime(2026, 10, 20));
      final saved = (await repository.fetchAll()).single;
      expect(saved.dueOn, DateTime(2027, 9, 21));
      expect(saved.paidOn, DateTime(2026, 10, 20));
    },
  );
}
