import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_learning_feedback.dart';
import 'package:pandapay/data/local/sms_rule_bundle.dart';
import 'package:pandapay/data/local/sms_rule_bundle_store.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Plan C5: the user's latest category correction must outrank downloaded
/// shared rules, built-in inference and the AI auto-resolution decision, and
/// its scope must be the corrected merchant text — never a blanket category
/// for every message from the same sender or merchant prefix.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late FinancialStore store;
  late SmsImportStore importStore;
  const ns = 'user:precedence';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    importStore = SmsImportStore(store);
  });

  tearDown(() {
    store.dispose();
    db.close();
  });

  /// Distinct amounts keep the derived source keys distinct between
  /// captures of the same merchant.
  String spendBody(String merchant, {int amount = 349}) =>
      'Rs $amount.00 spent on HDFC Bank Card ending 1234 at $merchant on '
      '20-Oct-26.';

  /// Seeds one shared (cross-user) category rule with a contract-valid
  /// bundle hash, exactly as a downloaded bundle would arrive.
  Future<void> seedSharedRule(String merchantKey, String slug) async {
    final rules = [
      SmsSharedCategoryRule(
        merchantKey: merchantKey,
        categorySlug: slug,
        supportCount: 25,
        agreementBp: 9800,
      ),
    ];
    final saved = await SmsRuleBundleStore(db).saveSharedCategoryRules({
      'categoryRulesVersion': 1,
      'categoryRulesMinClientVersion': '1.0.0',
      'categoryRulesSha256': SmsRuleBundleStore.computeSharedCategoryRulesSha256(
        version: 1,
        minClientVersion: '1.0.0',
        rules: rules,
      ),
      'categoryRules': rules.map((rule) => rule.toJson()).toList(),
    });
    expect(saved, isTrue, reason: 'shared rule bundle must seed cleanly');
  }

  void recordCorrection(String pattern, String slug) =>
      SmsLearningFeedback(
        db,
        namespace: ns,
      ).recordCategoryCorrection(merchantOrPattern: pattern, categorySlug: slug);

  LocalSmsObservation? parse(String merchant, {String sender = 'HDFCBK'}) =>
      LocalSmsParser.parse(
        namespace: ns,
        sender: sender,
        body: spendBody(merchant),
        receivedAt: DateTime(2026, 10, 20, 10),
        userCategoryRules: SmsLearningFeedback(
          db,
          namespace: ns,
        ).loadRulesSync(),
        sharedCategoryRules: SmsRuleBundleStore(
          db,
        ).loadSharedCategoryRulesSync(),
      );

  test('capture with a personal correction outranks a downloaded shared rule',
      () async {
    await seedSharedRule('BUNDL TECHNOLOGIES', 'bills');

    // Control: without a personal correction the shared rule categorises.
    importStore.capture(
      ns,
      QueuedSms(
        sender: 'HDFCBK',
        body: spendBody('BUNDL TECHNOLOGIES'),
        receivedAt: DateTime(2026, 10, 20, 9),
      ),
    );
    expect(
      store.entities(ns, 'transactions').single['category_id'],
      'bills',
    );

    recordCorrection('BUNDL TECHNOLOGIES', 'groceries');
    importStore.capture(
      ns,
      QueuedSms(
        sender: 'HDFCBK',
        body: spendBody('BUNDL TECHNOLOGIES', amount: 1299),
        receivedAt: DateTime(2026, 10, 20, 10),
      ),
    );
    expect(
      store.entities(ns, 'transactions').last['category_id'],
      'groceries',
      reason: 'the user correction must win over the shared rule',
    );
  });

  test('a later user edit replaces the earlier personal label', () {
    recordCorrection('BUNDL TECHNOLOGIES', 'groceries');
    expect(parse('BUNDL TECHNOLOGIES')?.transaction?.categoryId, 'groceries');

    recordCorrection('BUNDL TECHNOLOGIES', 'bills');
    expect(
      SmsLearningFeedback(db, namespace: ns).loadRulesSync(),
      {'BUNDL TECHNOLOGIES': 'bills'},
      reason: 'the upsert keeps one rule per pattern with the latest label',
    );
    expect(parse('BUNDL TECHNOLOGIES')?.transaction?.categoryId, 'bills');
  });

  test('a mixed-context merchant is not blanket-categorised by one correction',
      () {
    // The merchant sends both travel bookings and food orders; the user
    // corrects a booking. The rule scope is the corrected merchant text —
    // SMS whose extracted merchant text differs must not inherit it.
    recordCorrection('RAILBOOK INDIA SYSTEMS', 'travel');

    expect(
      parse('RAILBOOK INDIA SYSTEMS')?.transaction?.categoryId,
      'travel',
    );
    final food = parse('RAILBOOK FOODS')?.transaction;
    expect(food, isNotNull);
    expect(food!.merchantName, 'RAILBOOK FOODS');
    expect(
      food.categoryId,
      isNot('travel'),
      reason:
          'the correction is scoped to the corrected merchant text, not to '
          'every message from the same sender',
    );

    // Once the user teaches the other context too, longest-pattern matching
    // separates the two without one blanket category.
    recordCorrection('RAILBOOK FOODS', 'dining');
    expect(parse('RAILBOOK FOODS')?.transaction?.categoryId, 'dining');
    expect(parse('RAILBOOK INDIA SYSTEMS')?.transaction?.categoryId, 'travel');
  });

  test('AI auto-resolution applies the user correction before the AI category',
      () async {
    recordCorrection('Swiggy', 'groceries');
    const otherSourceKey =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final item = NeedsReviewItem(
      id: otherSourceKey,
      sender: 'HDFCBK',
      body:
          'Sent Rs.420.00 from HDFC Bank A/C **1797 to SWIGGY UPI on '
          '24-10-26. UPI Ref 429812398765. Avail Bal: Rs.45,120.50',
      reason: 'ambiguous_account_debit',
      receivedAt: DateTime(2026, 10, 24, 11),
    );
    db.db.execute(
      'INSERT OR REPLACE INTO local_needs_review VALUES (?,?,?)',
      [ns, item.id, jsonEncode(item.toJson())],
    );

    final result = importStore.resolveAiSuggestions(ns, item, [
      {
        'factIndex': 0,
        'factType': 'posted_movement',
        'payload': {
          'amountRole': 'posted',
          'entryKind': 'spend',
          'amountInr': 420.0,
          'occurredAt': '2026-10-24T00:00:00.000Z',
          'instrument': 'upi_bank',
          'accountLast4': '1797',
          'issuerName': 'HDFC Bank',
          'merchant': 'Swiggy',
          'category': 'dining',
          'isComplete': true,
          'confidence': 0.98,
        },
      },
    ]);

    expect(result.outcome, SmsAiResolutionOutcome.autoResolved);
    expect(
      store.entities(ns, 'transactions').single['category_id'],
      'groceries',
      reason: 'the user correction must outrank the AI decision origin',
    );
  });
}
