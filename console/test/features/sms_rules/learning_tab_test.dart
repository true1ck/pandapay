import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_console/data/sms_v2_admin_api.dart';
import 'package:pandapay_console/features/sms_rules/learning_tab.dart';
import 'package:pandapay_console/features/sms_rules/providers.dart';
import 'package:pandapay_console/features/sms_rules/sms_rules_screen.dart';
import 'support.dart';

Future<void> pumpLearning(
  WidgetTester tester,
  FakeAdmin admin, {
  void Function(String, String)? onRule,
  void Function(String, String)? onName,
  VoidCallback? onCorrections,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SmsLearningTab(
          api: SmsV2AdminApi(admin),
          onCreateCategoryRule: onRule ?? (_, _) {},
          onCreateName: onName,
          onOpenCorrections: onCorrections,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('a draft id is a stable UUID for one shop', () {
    final id = learningDraftId('SWIGGY');
    expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(learningDraftId('SWIGGY'), id);
    expect(learningDraftId('ZOMATO'), isNot(id));
    expect(learnedCategoryRule('SWIGGY', 'dining'), {
      'merchantKey': 'SWIGGY',
      'match': 'token',
      'senders': ['*'],
      'context': <String>[],
      'category': 'dining',
      'priority': 100,
      'source': 'shared',
    });
  });

  test('the split sentence leads with the winning category', () {
    expect(
      splitSentence({'groceries': 2, 'dining': 12}, leader: 'dining'),
      '12 people chose Dining · 2 chose Groceries',
    );
    expect(splitSentence({'fuel': 1}, leader: 'fuel'), '1 person chose Fuel');
  });

  testWidgets('summary cards show opt-in, backlog, layouts, AI and coverage', (tester) async {
    await pumpLearning(tester, FakeAdmin());
    expect(find.byKey(const Key('summary-cards')), findsOneWidget);
    expect(find.text('People sharing'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.textContaining('40% of 30 active accounts'), findsOneWidget);
    expect(find.text('Waiting for you'), findsOneWidget);
    expect(find.text('Message layouts'), findsOneWidget);
    expect(find.text('AI calls'), findsOneWidget);
    expect(find.text('17'), findsOneWidget);
    expect(find.text('Read by rules'), findsOneWidget);
    expect(find.text('90%'), findsOneWidget);
    expect(find.text('Below the threshold'), findsOneWidget);
    expect(find.text('3'), findsWidgets);
    expect(find.byKey(const Key('trend')), findsOneWidget);
    expect(find.text('Shops and names appear only when at least 3 different people reported them.'), findsOneWidget);
  });

  testWidgets('a category row reads like a sentence with senders and a status chip', (tester) async {
    final admin = FakeAdmin()..learningCategories = [fixtureCategoryCandidate()];
    await pumpLearning(tester, admin);
    expect(find.text('SWIGGY'), findsOneWidget);
    expect(
      find.textContaining('12 people chose Dining · 2 chose Groceries · 86% agree · senders HDFCBK, ICICIB'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('status-New')), findsOneWidget);
    expect(find.textContaining('People disagree'), findsNothing);
  });

  testWidgets('Covered and Conflict chips, and the disagreement hint under 70%', (tester) async {
    final admin = FakeAdmin()
      ..learningCategories = [
        fixtureCategoryCandidate(status: 'covered'),
        {...fixtureCategoryCandidate(status: 'conflict', agreement: 0.5), 'merchantKey': 'AMAZON'},
      ];
    await pumpLearning(tester, admin);
    expect(find.byKey(const Key('status-Covered')), findsOneWidget);
    expect(find.byKey(const Key('status-Conflict')), findsOneWidget);
    expect(find.textContaining('People disagree: consider leaving this unruled'), findsOneWidget);
  });

  testWidgets('Create rule records a draft decision and opens the editor with the learned rule', (tester) async {
    final admin = FakeAdmin()..learningCategories = [fixtureCategoryCandidate()];
    final opened = <(String, String)>[];
    await pumpLearning(tester, admin, onRule: (key, category) => opened.add((key, category)));
    await tester.tap(find.byKey(const Key('create-SWIGGY')));
    await tester.pumpAndSettle();
    expect(opened, [('SWIGGY', 'dining')]);
    final post = admin.requests.firstWhere((r) => r.$2 == '/admin/sms/v2/learning/decisions');
    expect(post.$3, {
      'kind': 'category_choice',
      'merchantKey': 'SWIGGY',
      'value': 'dining',
      'decision': 'drafted',
      'reason': 'Opened the category draft',
    });
  });

  testWidgets('Dismiss needs a reason and records it', (tester) async {
    final admin = FakeAdmin()..learningCategories = [fixtureCategoryCandidate()];
    await pumpLearning(tester, admin);
    await tester.tap(find.byKey(const Key('dismiss-SWIGGY')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('reason-confirm'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('reason-text')), 'Too few people for now');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reason-confirm')));
    await tester.pumpAndSettle();
    final post = admin.requests.lastWhere((r) => r.$2 == '/admin/sms/v2/learning/decisions');
    expect(post.$3?['decision'], 'dismissed');
    expect(post.$3?['reason'], 'Too few people for now');
    expect(post.$3?['value'], 'dining');
  });

  testWidgets('shop names show alias and name, with Create name only when it can be opened', (tester) async {
    final admin = FakeAdmin()
      ..learningNames = [
        {'merchantKey': 'PAYU SWIGGY', 'name': 'SWIGGY', 'users': 5, 'keyUsers': 5, 'agreement': 1, 'split': {'SWIGGY': 5}, 'senders': ['HDFCBK'], 'status': 'new', 'decision': null},
      ];
    await pumpLearning(tester, admin);
    expect(find.text('PAYU SWIGGY → SWIGGY'), findsOneWidget);
    expect(find.text('5 people'), findsOneWidget);
    expect(find.text('Create name'), findsNothing);
    final named = <(String, String)>[];
    await pumpLearning(tester, admin, onName: (alias, name) => named.add((alias, name)));
    await tester.tap(find.byKey(const Key('create-name-PAYU SWIGGY')));
    await tester.pumpAndSettle();
    expect(named, [('PAYU SWIGGY', 'SWIGGY')]);
    final post = admin.requests.lastWhere((r) => r.$2 == '/admin/sms/v2/learning/decisions');
    expect(post.$3?['kind'], 'merchant_name');
    expect(post.$3?['value'], 'SWIGGY');
  });

  testWidgets('shops in Other offer Pick category and Dismiss', (tester) async {
    final admin = FakeAdmin()
      ..learningOther = [
        {'merchantKey': 'BLINKIT', 'users': 9, 'testerUsers': 1, 'senders': ['ICICIB'], 'status': 'new', 'decision': null},
      ];
    final opened = <(String, String)>[];
    await pumpLearning(tester, admin, onRule: (key, category) => opened.add((key, category)));
    expect(find.text('BLINKIT · 9 people'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pick-BLINKIT')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick-groceries')));
    await tester.pumpAndSettle();
    expect(opened, [('BLINKIT', 'groceries')]);
    final post = admin.requests.lastWhere((r) => r.$2 == '/admin/sms/v2/learning/decisions');
    expect(post.$3?['kind'], 'uncategorised');
    expect(post.$3?['value'], '');
  });

  testWidgets('fixes by layout list the counts and link to Corrections', (tester) async {
    var opened = 0;
    await pumpLearning(tester, FakeAdmin(), onCorrections: () => opened++);
    expect(find.text('wrong amount'), findsOneWidget);
    expect(find.text('5 reports · 3 people'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-corrections')));
    expect(opened, 1);
  });

  testWidgets('Learning is the first tab of the SMS rules screen', (tester) async {
    final admin = FakeAdmin()..learningCategories = [fixtureCategoryCandidate()];
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [smsV2AdminApiProvider.overrideWithValue(SmsV2AdminApi(admin))],
        child: const MaterialApp(home: SmsRulesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Learning'), findsWidgets);
    expect(find.byKey(const Key('summary-cards')), findsOneWidget);
    expect(find.byKey(const Key('category-SWIGGY')), findsOneWidget);
  });

  testWidgets('a ready AI suggestion is shown with its reason and opens the same draft', (tester) async {
    final admin = FakeAdmin()
      ..learningOther = [
        {
          'merchantKey': 'BLINKIT', 'users': 9, 'testerUsers': 1, 'senders': ['ICICIB'], 'status': 'new', 'decision': null,
          'suggestion': {'category': 'groceries', 'confidence': 0.9, 'why': 'brand_known'},
        },
        {'merchantKey': 'ZEPTO', 'users': 4, 'senders': ['HDFCBK'], 'status': 'new', 'decision': null, 'suggestion': null},
      ];
    final opened = <(String, String)>[];
    await pumpLearning(tester, admin, onRule: (key, category) => opened.add((key, category)));
    expect(find.textContaining('AI suggests Groceries (brand known)'), findsOneWidget);
    expect(find.byKey(const Key('use-ZEPTO')), findsNothing, reason: 'no suggestion, no button');
    await tester.tap(find.byKey(const Key('use-BLINKIT')));
    await tester.pumpAndSettle();
    expect(opened, [('BLINKIT', 'groceries')]);
    final post = admin.requests.lastWhere((r) => r.$2 == '/admin/sms/v2/learning/decisions');
    expect(post.$3?['decision'], 'drafted');
    expect(post.$3?['kind'], 'uncategorised');
    expect(suggestionLine({'suggestion': {'category': 'fuel', 'why': 'name_describes_goods'}}), 'AI suggests Fuel (name describes goods)');
    expect(suggestionLine({'suggestion': null}), isNull);
  });
}
