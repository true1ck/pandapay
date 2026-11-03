import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/ui/why_sheet.dart';

void main() {
  test(
    'manual changes are explained as choices and preserve original rule attribution',
    () {
      final text = explainDecision({
        'ruleId': 'SYNTHETIC-RULE',
        'ruleVersion': 1,
        'userChoices': [
          'wrong_amount',
          'wrong_merchant',
          'wrong_date',
          'wrong_kind',
          'wrong_link',
        ],
        'instruments': [
          {'step': 'user_choice'},
        ],
        'event': {'linkRuleId': 'LINK-CARD-BILL'},
        'category': {'source': 'user'},
      }).join('\n');
      expect(text, contains('You corrected the amount'));
      expect(text, contains('You corrected the merchant'));
      expect(text, contains('You corrected the date'));
      expect(text, contains('You changed the type'));
      expect(text, contains('You chose which messages'));
      expect(text, contains('You chose the account or card'));
      expect(text, contains('Originally read with SYNTHETIC RULE'));
      expect(text, isNot(contains('masked digits')));
      expect(text, isNot(contains('Matched the bank payment')));
      expect(text, contains('Category: you chose'));
    },
  );
  test('excluded user readings do not repeat automatic link claims', () {
    for (final kind in ['not_financial', 'duplicate']) {
      final text = explainDecision({
        'userChoices': [kind],
        'event': {'linkRuleId': 'LINK-IPO'},
      }).join('\n');
      expect(text, contains('stays out of totals'));
      expect(text, isNot(contains('Grouped the IPO')));
    }
  });
}
