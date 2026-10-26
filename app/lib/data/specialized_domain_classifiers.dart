import 'indian_narration_sanitizer.dart';
import 'user_cards_repository.dart';

/// Classification of investment and brokerage messages.
enum BrokerEventType {
  brokerFunding,
  brokerSettlement,
  dividendIncome,
  depositoryCustodyAlert,
  brokerageFee,
  ipoLienOrAsbaBlock,
  none,
}

class BrokerClassificationResult {
  final BrokerEventType eventType;
  final TxnEntryKind? suggestedKind;
  final String? entityName;
  final String reason;

  const BrokerClassificationResult({
    required this.eventType,
    this.suggestedKind,
    this.entityName,
    required this.reason,
  });
}

/// Classification of loan and EMI lifecycle events.
enum LoanEventType {
  sanctionOrApproval,
  disbursement,
  emiDebit,
  foreclosureOrPrepayment,
  emiReminder,
  none,
}

class LoanClassificationResult {
  final LoanEventType eventType;
  final TxnEntryKind? suggestedKind;
  final bool isMoneyMovement;
  final String reason;

  const LoanClassificationResult({
    required this.eventType,
    this.suggestedKind,
    required this.isMoneyMovement,
    required this.reason,
  });
}

/// Classification of insurance lifecycle events.
enum InsuranceEventType {
  quoteOrSolicitation,
  premiumDue,
  premiumPaid,
  claimPayout,
  none,
}

class InsuranceClassificationResult {
  final InsuranceEventType eventType;
  final TxnEntryKind? suggestedKind;
  final bool isBillCommitment;
  final String reason;

  const InsuranceClassificationResult({
    required this.eventType,
    this.suggestedKind,
    required this.isBillCommitment,
    required this.reason,
  });
}

/// High-precision specialized domain classifiers for Indian financial SMS and statements.
class SpecializedDomainClassifiers {
  static final _brokerNamesRe = RegExp(
    r'\b(?:zerodha|groww|upstox|angel\s+one|angel\s+broking|dhan|paytm\s+money|indmoney|5paisa|motilal\s+oswal|icici\s+direct|hdfc\s+securities|kotak\s+securities|kotak\s+neo|lemonn|shoonya|finvasia|blinkx|geojit|axis\s+direct|m\.?stock|mirae|sbi\s+securities|iifl|sharekhan)\b',
    caseSensitive: false,
  );

  static final _depositoryRe = RegExp(
    r'\b(?:cdsl|nsdl)\s*:\s*(?:debit|credit)\s+in\s+a/?c\b[\s\S]{0,40}\b(?:etf|bees|shares?|units?|mf)\b',
    caseSensitive: false,
  );

  static final _dividendRe = RegExp(
    r'\b(?:dividend|div\.)\b[\s\S]{0,40}\b(?:credited|received|paid)\b|\b(?:credited|received)\b[\s\S]{0,30}\b(?:towards|for|as)\s+dividend\b',
    caseSensitive: false,
  );

  static final _brokerSettlementRe = RegExp(
    r'\b(?:running\s+account\s+settlement|quarterly\s+settlement|account\s+settlement|settlement\s+(?:payout|credit|dated)|payout|pay-?out|funds?\s+released)\b',
    caseSensitive: false,
  );

  static final _brokerFeeRe = RegExp(
    r'\b(?:amc|annual\s+maintenance|dp\s+charges?|brokerage\s+fee|demat\s+charges?)\b',
    caseSensitive: false,
  );

  static final _asbaOrIpoRe = RegExp(
    r'\b(?:asba\s+application|asba\s+(?:req(?:uest)?|bid|block|lien)|towards\s+asba|for\s+asba|asba\b[\s\S]{0,50}\b(?:accepted|blocked|lien|created)|(?:blocked|lien\s+marked)\b[\s\S]{0,50}\b(?:for|towards)?\s*(?:ipo|asba|rights\s+issue)|(?:ipo\s+(?:application|bid|mandate|block|lien)))\b',
    caseSensitive: false,
  );

  /// Classifies investment, broker, dividend, and demat depository alerts.
  static BrokerClassificationResult classifyBrokerMessage(String sender, String text) {
    final lower = text.toLowerCase();

    // 1. ASBA / IPO Application Lien Block
    if (_asbaOrIpoRe.hasMatch(lower)) {
      final ipoCompanyMatch = RegExp(
        r'\b(?:asba|ipo)\b[\s\S]{0,60}?\bfor\s+([A-Za-z0-9 ._&@*\x27/-]{2,60}?)(?=\s+(?:of\s+(?:₹|rs\.?|inr)|application|has\s+been|is\s+accepted)|[.,;]|$)',
        caseSensitive: false,
      ).firstMatch(text) ??
      RegExp(
        r'\bfor\s+([A-Za-z0-9 ._&@*\x27/-]{2,60}?)\s+of\s+(?:₹|rs\.?|inr)',
        caseSensitive: false,
      ).firstMatch(text);
      final rawEntity = ipoCompanyMatch?.group(1)?.trim();
      final entity = rawEntity != null ? IndianNarrationSanitizer.sanitize(rawEntity) : null;
      return BrokerClassificationResult(
        eventType: BrokerEventType.ipoLienOrAsbaBlock,
        suggestedKind: TxnEntryKind.investment,
        entityName: entity?.isNotEmpty == true ? entity : 'IPO Application',
        reason: 'ASBA / IPO application investment lien block',
      );
    }

    // 2. Depository non-cash share alerts (CDSL / NSDL)
    if (_depositoryRe.hasMatch(lower) || RegExp(r'\b(?:cdsl|nsdl)\b').hasMatch(sender.toLowerCase())) {
      if (RegExp(r'\b(?:shares?|units?|etf|bees)\b').hasMatch(lower)) {
        return const BrokerClassificationResult(
          eventType: BrokerEventType.depositoryCustodyAlert,
          suggestedKind: null,
          reason: 'Depository share custody movement (non-cash ledger change)',
        );
      }
    }

    // 3. Dividend Inflow
    if (_dividendRe.hasMatch(lower)) {
      return const BrokerClassificationResult(
        eventType: BrokerEventType.dividendIncome,
        suggestedKind: TxnEntryKind.income,
        reason: 'Dividend income from equity holdings',
      );
    }

    final brokerMatch = _brokerNamesRe.firstMatch(lower) ?? _brokerNamesRe.firstMatch(sender.toLowerCase());
    if (brokerMatch == null) {
      return const BrokerClassificationResult(
        eventType: BrokerEventType.none,
        reason: 'Not an investment or broker notification',
      );
    }

    final brokerName = brokerMatch.group(0)!;

    // 3. Broker AMC or Maintenance Fees
    if (_brokerFeeRe.hasMatch(lower)) {
      return BrokerClassificationResult(
        eventType: BrokerEventType.brokerageFee,
        suggestedKind: TxnEntryKind.spend,
        entityName: brokerName,
        reason: 'Brokerage maintenance or DP fee',
      );
    }

    // 4. Broker Settlement Payout to Bank
    if (_brokerSettlementRe.hasMatch(lower) &&
        RegExp(r'\b(?:credited|received|payout|transferred\s+to\s+your\s+bank)\b').hasMatch(lower)) {
      return BrokerClassificationResult(
        eventType: BrokerEventType.brokerSettlement,
        suggestedKind: TxnEntryKind.income,
        entityName: brokerName,
        reason: 'Broker settlement payout returned to bank account',
      );
    }

    // 5. Broker Funding / Account Top-up
    if (RegExp(r'\b(?:added|transferred|funded|deposited|debited)\b').hasMatch(lower)) {
      return BrokerClassificationResult(
        eventType: BrokerEventType.brokerFunding,
        suggestedKind: TxnEntryKind.investment,
        entityName: brokerName,
        reason: 'Transfer of funds to trading broker account',
      );
    }

    return BrokerClassificationResult(
      eventType: BrokerEventType.none,
      entityName: brokerName,
      reason: 'General broker notice without financial movement',
    );
  }

  /// Classifies loan, EMI, disbursement, and foreclosure lifecycle events.
  static LoanClassificationResult classifyLoanMessage(String sender, String text) {
    final lower = text.toLowerCase();

    // 1. Loan approval / pre-approved promo (No movement)
    if (RegExp(r'\b(?:pre-approved|eligible\s+for|apply\s+now|congratulations\b[\s\S]{0,30}\bloan)\b').hasMatch(lower) &&
        !RegExp(r'\b(?:debited|credited|disbursed)\b').hasMatch(lower)) {
      return const LoanClassificationResult(
        eventType: LoanEventType.sanctionOrApproval,
        suggestedKind: null,
        isMoneyMovement: false,
        reason: 'Loan solicitation or sanction notice without fund transfer',
      );
    }

    // 2. Loan Disbursement (Inflow to bank)
    if (RegExp(r'\b(?:loan\s+amount|disbursed|disbursement)\b[\s\S]{0,40}\b(?:credited|deposited)\b|\b(?:credited|deposited)\b[\s\S]{0,40}\b(?:towards\s+loan\s+disbursement|loan\s+ac(?:count)?)\b').hasMatch(lower)) {
      return const LoanClassificationResult(
        eventType: LoanEventType.disbursement,
        suggestedKind: TxnEntryKind.transfer,
        isMoneyMovement: true,
        reason: 'Loan principal disbursement credited to account',
      );
    }

    // 3. EMI Debit / Scheduled Repayment
    if (RegExp(r'\b(?:emi|loan\s+(?:installment|repayment))\b[\s\S]{0,40}\b(?:debited|paid|deducted)\b|\b(?:debited|paid|deducted)\b[\s\S]{0,40}\b(?:for|towards)?\s*(?:loan|emi)\b').hasMatch(lower)) {
      return const LoanClassificationResult(
        eventType: LoanEventType.emiDebit,
        suggestedKind: TxnEntryKind.spend,
        isMoneyMovement: true,
        reason: 'Scheduled EMI installment payment',
      );
    }

    // 4. Foreclosure or Prepayment
    if (RegExp(r'\b(?:foreclosure|pre-?payment|preclosure|part-?payment)\b[\s\S]{0,40}\b(?:received|successful|completed|paid)\b').hasMatch(lower)) {
      return const LoanClassificationResult(
        eventType: LoanEventType.foreclosureOrPrepayment,
        suggestedKind: TxnEntryKind.transfer,
        isMoneyMovement: true,
        reason: 'Loan foreclosure or principal prepayment',
      );
    }

    // 5. EMI Due Reminder
    if (RegExp(r'\b(?:emi\s+due|upcoming\s+emi|keep\s+sufficient\s+balance\s+for\s+emi)\b').hasMatch(lower)) {
      return const LoanClassificationResult(
        eventType: LoanEventType.emiReminder,
        suggestedKind: null,
        isMoneyMovement: false,
        reason: 'Upcoming loan EMI due date reminder',
      );
    }

    return const LoanClassificationResult(
      eventType: LoanEventType.none,
      suggestedKind: null,
      isMoneyMovement: false,
      reason: 'Not a loan lifecycle message',
    );
  }

  /// Classifies insurance premium dues, receipts, and claim settlements.
  static InsuranceClassificationResult classifyInsuranceMessage(String sender, String text) {
    final lower = text.toLowerCase();
    final isInsuranceProvider = RegExp(r'\b(?:lic\b|policybazaar|hdfc\s+ergo|icici\s+lombard|star\s+health|bajaj\s+allianz|care\s+insurance|max\s+life|tata\s+aia)\b').hasMatch(lower) ||
        RegExp(r'\b(?:lic|ergo|lombard|star)\b').hasMatch(sender.toLowerCase());

    if (!isInsuranceProvider && !RegExp(r'\b(?:insurance|policy\s+no|premium)\b').hasMatch(lower)) {
      return const InsuranceClassificationResult(
        eventType: InsuranceEventType.none,
        isBillCommitment: false,
        reason: 'Not an insurance notification',
      );
    }

    // 1. Claim settlement payout credited to bank
    if (RegExp(r'\b(?:claim\s+(?:settlement|approved|payout)|claim\s+amount)\b[\s\S]{0,40}\b(?:credited|deposited|transferred)\b|\b(?:credited|deposited)\b[\s\S]{0,40}\b(?:for|towards)?\s*insurance\s+claim\b').hasMatch(lower)) {
      return const InsuranceClassificationResult(
        eventType: InsuranceEventType.claimPayout,
        suggestedKind: TxnEntryKind.income,
        isBillCommitment: false,
        reason: 'Insurance claim settlement payout credited to account',
      );
    }

    // 2. Premium Paid confirmation
    if (RegExp(r'\b(?:premium|policy\s+renewal)\b[\s\S]{0,40}\b(?:paid|received|debited|successful)\b|\b(?:debited|paid)\b[\s\S]{0,40}\b(?:for|towards)?\s*(?:lic|insurance|premium)\b').hasMatch(lower)) {
      return const InsuranceClassificationResult(
        eventType: InsuranceEventType.premiumPaid,
        suggestedKind: TxnEntryKind.spend,
        isBillCommitment: false,
        reason: 'Insurance premium payment receipt',
      );
    }

    // 3. Premium Due alert (Commitment)
    if (RegExp(r'\b(?:premium\s+due|renewal\s+due|due\s+date|pay\s+before|payable\s+by)\b').hasMatch(lower)) {
      return const InsuranceClassificationResult(
        eventType: InsuranceEventType.premiumDue,
        suggestedKind: null,
        isBillCommitment: true,
        reason: 'Insurance renewal premium due notice',
      );
    }

    // 4. Quote or solicitation
    if (RegExp(r'\b(?:get\s+quote|plans?\s+starting|compare\s+plans|special\s+discount)\b').hasMatch(lower)) {
      return const InsuranceClassificationResult(
        eventType: InsuranceEventType.quoteOrSolicitation,
        suggestedKind: null,
        isBillCommitment: false,
        reason: 'Insurance quote or solicitation',
      );
    }

    return const InsuranceClassificationResult(
      eventType: InsuranceEventType.none,
      isBillCommitment: false,
      reason: 'General insurance notice',
    );
  }
}
