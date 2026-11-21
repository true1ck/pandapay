import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/router.dart';

/// What Activity opens on for a link. The old parameters read exactly as they
/// always did; the new ones are additive.
void main() {
  test('a link with only the old parameters reads as before', () {
    final screen = activityScreenForUri(
      Uri.parse(
        '/activity?tag=t1&category=c1&categoryLabel=Dining&from=2026-01-01'
        '&to=2026-01-31&spendOnly=true&q=cab&type=moneyIn',
      ),
    );
    expect(screen.initialTagIds, {'t1'});
    expect(screen.initialCategoryId, 'c1');
    expect(screen.initialCategoryLabel, 'Dining');
    expect(screen.initialFrom, DateTime(2026, 1, 1));
    expect(screen.initialTo, DateTime(2026, 1, 31));
    expect(screen.initialSpendOnly, isTrue);
    expect(screen.initialQuery, 'cab');
    expect(screen.initialType, 'moneyIn');
    // None of the new ones is on.
    expect(screen.initialMerchants, isEmpty);
    expect(screen.initialCardIds, isEmpty);
    expect(screen.initialUntagged, isFalse);
    expect(screen.initialMoneyInKinds, isEmpty);
    expect(screen.initialNetSpending, isFalse);
  });

  test('a plain link has nothing on', () {
    final screen = activityScreenForUri(Uri.parse('/activity'));
    expect(screen.initialTagIds, isEmpty);
    expect(screen.initialCategoryIds, isEmpty);
    expect(screen.initialType, isNull);
    expect(screen.initialFrom, isNull);
  });

  test('tags, categories, merchants and cards may repeat', () {
    final screen = activityScreenForUri(
      Uri.parse(
        '/activity?type=spending&net=true&untagged=true&tag=a&tag=b'
        '&category=c1&category=c2&categoryLabel=Dining&categoryLabel=Travel'
        '&merchant=Corner%20Shop&merchant=Cafe&card=uc1&card=uc2',
      ),
    );
    expect(screen.initialType, 'spending');
    expect(screen.initialNetSpending, isTrue);
    expect(screen.initialUntagged, isTrue);
    expect(screen.initialTagIds, {'a', 'b'});
    expect(screen.initialCategoryIds, {'c1', 'c2'});
    expect(screen.initialCategoryLabels, {'Dining', 'Travel'});
    expect(screen.initialMerchants, {'Corner Shop', 'Cafe'});
    expect(screen.initialCardIds, {'uc1', 'uc2'});
  });

  test('Money in kinds are comma separated; blanks are ignored', () {
    final screen = activityScreenForUri(
      Uri.parse('/activity?type=moneyIn&kinds=salary,,person,&tag='),
    );
    expect(screen.initialMoneyInKinds, {'salary', 'person'});
    expect(screen.initialTagIds, isEmpty);
  });
}
