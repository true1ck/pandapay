import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_console/data/sms_v2_admin_api.dart';
import 'package:pandapay_console/features/sms_rules/category_editor.dart';
import 'package:pandapay_console/features/sms_rules/golden_runner.dart';
import 'package:pandapay_console/features/sms_rules/providers.dart';
import 'package:pandapay_console/features/sms_rules/sms_rules_screen.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:pandapay_domain/sms_v2_evaluation.dart';
import 'support.dart';

Map<String, dynamic> category() => {
  'merchantKey': 'SYNTHETIC SHOP',
  'match': 'exact',
  'senders': ['TESTBK'],
  'context': <String>[],
  'category': 'dining',
  'priority': 100,
  'source': 'shared',
};

class CategoryAdmin extends FakeAdmin {
  Map<String, dynamic> savedRule = category();
  bool wrongCohort = false;
  @override
  Future<Map<String, dynamic>> smsV2Request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (path.contains('/category-rules/') && method == 'PUT') {
      requests.add((method, path, body));
      savedRule = body!;
      return {'id': caseId, 'revision': 1, 'status': 'draft'};
    }
    if (path.contains('/category-rules/') && path.contains('/candidate?')) {
      requests.add((method, path, body));
      final bundle = {
        ...editorBundle({...rule(), 'status': 'active'}),
        'senders': catalog,
        'categoryRules': [savedRule],
      };
      return {
        'candidates': [
          for (final cohort in ['testers', 'pct5', 'pct25', 'all'])
            {
              'cohort': wrongCohort && cohort == 'all' ? 'unknown' : cohort,
              'bundle': bundle,
              'contentSha256': evaluationContentHash(bundle),
            },
        ],
      };
    }
    if (path.contains('/category-rules/') && method == 'POST') {
      requests.add((method, path, body));
      return {'id': caseId, 'revision': 1, 'status': 'published'};
    }
    if (path.endsWith('/decision') && body?['decision'] == 'data_fix') {
      requests.add((method, path, body));
      return {
        'categoryDraft': {
          'category': 'dining',
          'priority': 100,
          'counterpartyKeys': ['SYNTHETIC SHOP'],
        },
      };
    }
    final result = await super.smsV2Request(method, path, body: body);
    if (path.contains('/corrections?')) {
      final row = result['groups'][0]['cases'][0];
      row['stage'] = 'category';
      row['sender_brand'] = 'TESTBK';
      row['correction_kind'] = 'wrong_category';
    }
    return result;
  }
}

Future<void> reveal(WidgetTester tester, Finder target, double step) async {
  final scroll = tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const Key('category-editor-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;
  for (var i = 0; target.evaluate().isEmpty && i < 40; i++) {
    scroll.jumpTo((scroll.pixels + step).clamp(0, scroll.maxScrollExtent));
    await tester.pump();
  }
  await tester.ensureVisible(target);
}

void main() {
  test('category editor checks frozen shape, shared source and taxonomy', () {
    expect(categoryEditorIssues(jsonEncode(category())), isEmpty);
    expect(
      categoryEditorIssues(jsonEncode({...category(), 'id': 'fake-rule-id'})),
      isNotEmpty,
    );
    expect(
      categoryEditorIssues(jsonEncode({...category(), 'category': 'made_up'})),
      isNotEmpty,
    );
    expect(
      categoryEditorIssues(jsonEncode({...category(), 'source': 'ai'})),
      isNotEmpty,
    );
  });
  test(
    'a narrowed published exact scope no longer categorizes a broader merchant',
    () {
      final resolver = DefaultCategoryResolver();
      CategoryDecision resolve(String merchant, String match) =>
          resolver.resolve(
            CategoryInput(
              counterparty: Counterparty(name: merchant),
              senderBrand: 'TESTBK',
              bundleRules: [
                CategoryRule.fromJson({...category(), 'match': match}),
              ],
            ),
          );
      expect(resolve('SYNTHETIC SHOP EXTRA', 'contains').slug, 'dining');
      expect(resolve('SYNTHETIC SHOP EXTRA', 'exact').slug, 'other');
      expect(resolve('SYNTHETIC SHOP', 'exact').slug, 'dining');
    },
  );
  testWidgets(
    'category publish stays disabled if a required cohort is missing',
    (tester) async {
      final admin = CategoryAdmin()..wrongCohort = true;
      await tester.pumpWidget(
        MaterialApp(
          home: SmsCategoryEditor(
            api: SmsV2AdminApi(admin),
            id: caseId,
            initialRule: category(),
            revision: 1,
            runner: () async => tinyRunner(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const Key('run-category-golden')), 300);
      await tester.tap(find.byKey(const Key('run-category-golden')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('All four cohort candidates are required.'),
        findsOneWidget,
      );
      await reveal(tester, find.byKey(const Key('publish-category')), 300);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('publish-category')))
            .onPressed,
        isNull,
      );
      expect(
        admin.requests.any((request) => request.$2.endsWith('/publish')),
        isFalse,
      );
    },
  );
  testWidgets(
    'a category correction saves CategoryRule and publishes only after all cohort reports',
    (tester) async {
      final admin = CategoryAdmin();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            smsV2AdminApiProvider.overrideWithValue(SmsV2AdminApi(admin)),
          ],
          child: MaterialApp(
            home: SmsRulesScreen(runner: () async => tinyRunner()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Corrections'));
      await tester.tap(find.text('Corrections'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('template-a · 1 cases'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Data fix'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('correction-reason')),
        'Reviewed synthetic category',
      );
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Review category rule'), findsOneWidget);
      final publish = find.byKey(const Key('publish-category'));
      await reveal(tester, publish, 300);
      expect(tester.widget<FilledButton>(publish).onPressed, isNull);
      await reveal(tester, find.byKey(const Key('save-category')), -300);
      await tester.tap(find.byKey(const Key('save-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('run-category-golden')));
      await tester.pumpAndSettle();
      expect(
        find.text('All four cohort golden checks passed.'),
        findsOneWidget,
      );
      await reveal(tester, find.byKey(const Key('category-reason')), 300);
      await tester.enterText(
        find.byKey(const Key('category-reason')),
        'Reviewed category correction with golden proof',
      );
      await tester.pump();
      await reveal(tester, publish, 300);
      await tester.tap(publish);
      await tester.pumpAndSettle();
      expect(
        find.text('Publish this category rule to every cohort?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      final request = admin.requests.singleWhere(
        (row) =>
            row.$2.contains('/category-rules/') && row.$2.endsWith('/publish'),
      );
      expect(
        (request.$3!['goldenReports'] as Map).keys,
        unorderedEquals(['testers', 'pct5', 'pct25', 'all']),
      );
      expect(
        admin.requests.any(
          (row) => row.$2.contains('/rules/') && row.$1 != 'GET',
        ),
        isFalse,
      );
      final decision = DefaultCategoryResolver().resolve(
        CategoryInput(
          counterparty: const Counterparty(name: 'SYNTHETIC SHOP'),
          senderBrand: 'TESTBK',
          bundleRules: [CategoryRule.fromJson(admin.savedRule)],
        ),
      );
      expect(decision.slug, 'dining');
      expect(decision.source, CategorySource.shared);
      expect(tester.takeException(), isNull);
    },
  );
}
