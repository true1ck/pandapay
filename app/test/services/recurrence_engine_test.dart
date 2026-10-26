import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/services/recurrence_engine.dart';
import 'package:pandapay/data/specialized_domain_classifiers.dart';

void main() {
  group('RecurrenceEngine', () {
    test('detects fixed-amount monthly SaaS subscription (e.g. Netflix)', () {
      final txns = [
        RecurrenceTransactionInput(
          id: '1',
          merchantName: 'NETFLIX.COM MUMBAI',
          amount: Money.fromRupees(649),
          occurredAt: DateTime(2026, 7, 1),
        ),
        RecurrenceTransactionInput(
          id: '2',
          merchantName: 'NETFLIX.COM MUMBAI',
          amount: Money.fromRupees(649),
          occurredAt: DateTime(2026, 8, 1),
        ),
        RecurrenceTransactionInput(
          id: '3',
          merchantName: 'NETFLIX.COM MUMBAI',
          amount: Money.fromRupees(649),
          occurredAt: DateTime(2026, 9, 1),
        ),
        RecurrenceTransactionInput(
          id: '4',
          merchantName: 'NETFLIX.COM MUMBAI',
          amount: Money.fromRupees(649),
          occurredAt: DateTime(2026, 10, 1),
        ),
      ];

      final recurrences = RecurrenceEngine.detectRecurrences(txns);
      expect(recurrences.length, equals(1));

      final sub = recurrences.first;
      expect(sub.displayName, equals('Netflix'));
      expect(sub.cadence, equals(RecurrenceCadence.monthly));
      expect(sub.amountType, equals(RecurrenceAmountType.fixed));
      expect(sub.typicalAmount.rupees, equals(649));
      expect(sub.confidenceScore, greaterThanOrEqualTo(0.85));
    });

    test('detects variable-amount monthly metered utility (e.g. Electricity)', () {
      final txns = [
        RecurrenceTransactionInput(
          id: '1',
          merchantName: 'TATA POWER MUMBAI',
          amount: Money.fromRupees(2150),
          occurredAt: DateTime(2026, 7, 10),
          categoryHint: 'bills',
        ),
        RecurrenceTransactionInput(
          id: '2',
          merchantName: 'TATA POWER MUMBAI',
          amount: Money.fromRupees(1890),
          occurredAt: DateTime(2026, 8, 10),
          categoryHint: 'bills',
        ),
        RecurrenceTransactionInput(
          id: '3',
          merchantName: 'TATA POWER MUMBAI',
          amount: Money.fromRupees(2450),
          occurredAt: DateTime(2026, 9, 10),
          categoryHint: 'bills',
        ),
        RecurrenceTransactionInput(
          id: '4',
          merchantName: 'TATA POWER MUMBAI',
          amount: Money.fromRupees(2100),
          occurredAt: DateTime(2026, 10, 10),
          categoryHint: 'bills',
        ),
      ];

      final recurrences = RecurrenceEngine.detectRecurrences(txns);
      expect(recurrences.length, equals(1));

      final bill = recurrences.first;
      expect(bill.displayName, equals('Tata Power'));
      expect(bill.cadence, equals(RecurrenceCadence.monthly));
      expect(bill.amountType, equals(RecurrenceAmountType.variableMetered));
      expect(bill.occurrenceCount, equals(4));
    });

    test('detects Indian prepaid telecom 28-day cycle (e.g. Jio)', () {
      final txns = [
        RecurrenceTransactionInput(
          id: '1',
          merchantName: 'JIO PREPAID MUMBAI',
          amount: Money.fromRupees(299),
          occurredAt: DateTime(2026, 7, 1),
        ),
        RecurrenceTransactionInput(
          id: '2',
          merchantName: 'JIO PREPAID MUMBAI',
          amount: Money.fromRupees(299),
          occurredAt: DateTime(2026, 7, 29),
        ),
        RecurrenceTransactionInput(
          id: '3',
          merchantName: 'JIO PREPAID MUMBAI',
          amount: Money.fromRupees(299),
          occurredAt: DateTime(2026, 8, 26),
        ),
        RecurrenceTransactionInput(
          id: '4',
          merchantName: 'JIO PREPAID MUMBAI',
          amount: Money.fromRupees(299),
          occurredAt: DateTime(2026, 9, 23),
        ),
      ];

      final recurrences = RecurrenceEngine.detectRecurrences(txns);
      expect(recurrences.length, equals(1));
      expect(recurrences.first.cadence, equals(RecurrenceCadence.telecom28Day));
      expect(recurrences.first.cadenceDays, equals(28));
    });

    test('detects Indian prepaid telecom 56-day and 84-day cycles', () {
      final txns56 = [
        RecurrenceTransactionInput(
          id: '1',
          merchantName: 'AIRTEL PREPAID',
          amount: Money.fromRupees(579),
          occurredAt: DateTime(2026, 1, 1),
        ),
        RecurrenceTransactionInput(
          id: '2',
          merchantName: 'AIRTEL PREPAID',
          amount: Money.fromRupees(579),
          occurredAt: DateTime(2026, 2, 26),
        ),
        RecurrenceTransactionInput(
          id: '3',
          merchantName: 'AIRTEL PREPAID',
          amount: Money.fromRupees(579),
          occurredAt: DateTime(2026, 4, 23),
        ),
      ];
      final rec56 = RecurrenceEngine.detectRecurrences(txns56);
      expect(rec56.length, equals(1));
      expect(rec56.first.cadence, equals(RecurrenceCadence.telecom56Day));

      final txns84 = [
        RecurrenceTransactionInput(
          id: '1',
          merchantName: 'VI PREPAID',
          amount: Money.fromRupees(859),
          occurredAt: DateTime(2026, 1, 1),
        ),
        RecurrenceTransactionInput(
          id: '2',
          merchantName: 'VI PREPAID',
          amount: Money.fromRupees(859),
          occurredAt: DateTime(2026, 3, 26),
        ),
        RecurrenceTransactionInput(
          id: '3',
          merchantName: 'VI PREPAID',
          amount: Money.fromRupees(859),
          occurredAt: DateTime(2026, 6, 18),
        ),
      ];
      final rec84 = RecurrenceEngine.detectRecurrences(txns84);
      expect(rec84.length, equals(1));
      expect(rec84.first.cadence, equals(RecurrenceCadence.telecom84Day));
    });

    test('rejects irregular random visits without consistent cadence', () {
      final txns = [
        RecurrenceTransactionInput(
          id: '1',
          merchantName: 'RANDOM STORE',
          amount: Money.fromRupees(500),
          occurredAt: DateTime(2026, 7, 1),
        ),
        RecurrenceTransactionInput(
          id: '2',
          merchantName: 'RANDOM STORE',
          amount: Money.fromRupees(500),
          occurredAt: DateTime(2026, 7, 4), // 3 days
        ),
        RecurrenceTransactionInput(
          id: '3',
          merchantName: 'RANDOM STORE',
          amount: Money.fromRupees(500),
          occurredAt: DateTime(2026, 8, 20), // 47 days
        ),
      ];

      final recurrences = RecurrenceEngine.detectRecurrences(txns);
      expect(recurrences, isEmpty);
    });
  });

  group('SpecializedDomainClassifiers', () {
    test('Broker message classifications', () {
      // 1. Broker funding
      final funding = SpecializedDomainClassifiers.classifyBrokerMessage(
        'HDFCBK',
        'Rs 10,000 debited from A/c XX1234 and transferred to Zerodha trading a/c',
      );
      expect(funding.eventType, equals(BrokerEventType.brokerFunding));
      expect(funding.suggestedKind, equals(TxnEntryKind.investment));

      // 2. Broker settlement payout
      final settlement = SpecializedDomainClassifiers.classifyBrokerMessage(
        'GROWW',
        'Quarterly settlement payout of INR 14,500 credited to your bank account',
      );
      expect(settlement.eventType, equals(BrokerEventType.brokerSettlement));
      expect(settlement.suggestedKind, equals(TxnEntryKind.income));

      // 3. Dividend income
      final dividend = SpecializedDomainClassifiers.classifyBrokerMessage(
        'AXISBK',
        'A/c XX1234 credited with INR 450.00 as dividend from TCS',
      );
      expect(dividend.eventType, equals(BrokerEventType.dividendIncome));
      expect(dividend.suggestedKind, equals(TxnEntryKind.income));

      // 4. Demat share movement (non-cash)
      final demat = SpecializedDomainClassifiers.classifyBrokerMessage(
        'CDSL',
        'CDSL: Debit in A/c **1234 for 10 units of NIFTYBEES',
      );
      expect(demat.eventType, equals(BrokerEventType.depositoryCustodyAlert));
      expect(demat.suggestedKind, isNull);

      // 5. ASBA / IPO Application Lien Block
      final asba = SpecializedDomainClassifiers.classifyBrokerMessage(
        'Kotak Bank',
        'Dear Customer, your request for ASBA application no. 1789027578CB90FY for RENTOMOJO LIMITED of Rs. 2,09,272.00 has been accepted successfully on 10/09/2026. - Kotak Bank',
      );
      expect(asba.eventType, equals(BrokerEventType.ipoLienOrAsbaBlock));
      expect(asba.suggestedKind, equals(TxnEntryKind.investment));
      expect(asba.entityName, equals('RENTOMOJO'));
    });

    test('Loan & EMI lifecycle classifications', () {
      // 1. EMI Debit
      final emi = SpecializedDomainClassifiers.classifyLoanMessage(
        'HDFCBK',
        'Rs. 18,500 debited from A/c XX1234 for Home Loan EMI',
      );
      expect(emi.eventType, equals(LoanEventType.emiDebit));
      expect(emi.suggestedKind, equals(TxnEntryKind.spend));
      expect(emi.isMoneyMovement, isTrue);

      // 2. Loan Disbursement
      final disbursal = SpecializedDomainClassifiers.classifyLoanMessage(
        'ICICIB',
        'Loan amount of INR 5,00,000 disbursed and credited to your A/c XX5678',
      );
      expect(disbursal.eventType, equals(LoanEventType.disbursement));
      expect(disbursal.suggestedKind, equals(TxnEntryKind.transfer));
      expect(disbursal.isMoneyMovement, isTrue);

      // 3. Pre-approved promo (not a money movement)
      final promo = SpecializedDomainClassifiers.classifyLoanMessage(
        'AXISBK',
        'Congratulations! You are pre-approved for personal loan up to 5 Lakhs. Apply now.',
      );
      expect(promo.eventType, equals(LoanEventType.sanctionOrApproval));
      expect(promo.isMoneyMovement, isFalse);
    });

    test('Insurance lifecycle classifications', () {
      // 1. Premium Due
      final due = SpecializedDomainClassifiers.classifyInsuranceMessage(
        'LIC-INDIA',
        'Your LIC policy premium of Rs. 4,500 is due on 15-Nov-2026. Pay before due date.',
      );
      expect(due.eventType, equals(InsuranceEventType.premiumDue));
      expect(due.isBillCommitment, isTrue);

      // 2. Premium Paid
      final paid = SpecializedDomainClassifiers.classifyInsuranceMessage(
        'STARHEALTH',
        'Premium of INR 12,500 received for policy renewal. Thank you for choosing Star Health.',
      );
      expect(paid.eventType, equals(InsuranceEventType.premiumPaid));
      expect(paid.suggestedKind, equals(TxnEntryKind.spend));

      // 3. Claim Settlement Payout
      final claim = SpecializedDomainClassifiers.classifyInsuranceMessage(
        'HDFC-ERGO',
        'Health insurance claim settlement of Rs. 45,000 credited to your account XX1234',
      );
      expect(claim.eventType, equals(InsuranceEventType.claimPayout));
      expect(claim.suggestedKind, equals(TxnEntryKind.income));
    });
  });
}
