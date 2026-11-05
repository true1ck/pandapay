import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_console/data/sms_v2_admin_api.dart';
import 'package:pandapay_console/features/sms_rules/category_editor.dart';
import 'package:pandapay_console/features/sms_rules/golden_runner.dart';
import 'package:pandapay_console/features/sms_rules/learning_tab.dart';
import 'package:pandapay_domain/sms_v2_evaluation.dart';
import 'support.dart';

Map<String, dynamic> alias() => learnedAlias('PAYU SWIGGY', 'SWIGGY');

class AliasAdmin extends FakeAdmin {
  Map<String, dynamic> savedAlias = alias();
  @override
  Future<Map<String, dynamic>> smsV2Request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (path.contains('/merchant-aliases/')) {
      requests.add((method, path, body));
      if (method == 'PUT') {
        savedAlias = body!;
        return {'id': caseId, 'revision': 1, 'status': 'draft'};
      }
      if (path.contains('/candidate?')) {
        final bundle = {
          ...editorBundle({...rule(), 'status': 'active'}),
          'senders': catalog,
          'merchantAliases': [savedAlias],
        };
        return {
          'candidates': [
            for (final cohort in ['testers', 'pct5', 'pct25', 'all'])
              {
                'cohort': cohort,
                'bundle': bundle,
                'contentSha256': evaluationContentHash(bundle),
              },
          ],
        };
      }
      return {'id': caseId, 'revision': 1, 'status': 'published'};
    }
    return super.smsV2Request(method, path, body: body);
  }
}

Future<void> reveal(WidgetTester tester, Finder target) async {
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
    scroll.jumpTo((scroll.pixels + 300).clamp(0, scroll.maxScrollExtent));
    await tester.pump();
  }
  await tester.ensureVisible(target);
}

void main() {
  test('the shop-name editor checks the shape before anything is sent', () {
    expect(aliasEditorIssues(jsonEncode(alias())), isEmpty);
    expect(aliasEditorIssues(jsonEncode({...alias(), 'kind': 'catalogue'})), isNotEmpty);
    expect(aliasEditorIssues(jsonEncode({...alias(), 'extra': 1})), isNotEmpty);
    expect(aliasEditorIssues(jsonEncode({...alias(), 'merchantKey': 'payu swiggy'})), isNotEmpty);
    expect(aliasEditorIssues(jsonEncode({...alias(), 'alias': 'PAYTMQR2810050501'})), isNotEmpty);
    expect(aliasEditorIssues('{'), isNotEmpty);
  });

  testWidgets('a shop name is saved, golden-checked in all four cohorts and then published', (tester) async {
    final admin = AliasAdmin();
    await tester.pumpWidget(
      MaterialApp(
        home: SmsCategoryEditor(
          api: SmsV2AdminApi(admin),
          part: SharedPart.alias,
          id: caseId,
          initialRule: alias(),
          runner: () async => tinyRunner(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Review shop name'), findsOneWidget);
    expect(find.text('Save shop name draft'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('save-category')));
    await tester.tap(find.byKey(const Key('save-category')));
    await tester.pumpAndSettle();
    expect(admin.requests.last.$2, '/admin/sms/v2/merchant-aliases/$caseId/draft');
    expect(admin.requests.last.$3, alias());
    expect(find.textContaining('Shop name draft revision 1 saved.'), findsOneWidget);

    await reveal(tester, find.byKey(const Key('run-category-golden')));
    await tester.tap(find.byKey(const Key('run-category-golden')));
    await tester.pumpAndSettle();
    expect(find.textContaining('All four cohort golden checks passed.'), findsOneWidget);
    expect(admin.requests.any((r) => r.$2.endsWith('/candidate?revision=1')), isTrue);

    await reveal(tester, find.byKey(const Key('category-reason')));
    await tester.enterText(find.byKey(const Key('category-reason')), 'Three people renamed it');
    await tester.pump();
    await reveal(tester, find.byKey(const Key('publish-category')));
    await tester.tap(find.byKey(const Key('publish-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    final publish = admin.requests.lastWhere((r) => r.$2.endsWith('/publish'));
    expect(publish.$2, '/admin/sms/v2/merchant-aliases/$caseId/publish');
    expect(publish.$3?['reason'], 'Three people renamed it');
    expect((publish.$3?['goldenReports'] as Map).keys.toSet(), {'testers', 'pct5', 'pct25', 'all'});
    expect(find.textContaining('Shop name published to every cohort.'), findsOneWidget);
  });
}
