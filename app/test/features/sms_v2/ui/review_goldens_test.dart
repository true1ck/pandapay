import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:pandapay/features/sms_v2/ui/found_instruments_screen.dart';
import 'package:pandapay/features/sms_v2/ui/review_inbox_screen.dart';
import 'package:pandapay/features/sms_v2/ui/why_sheet.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay_domain/sms_v2.dart';

void main() {
  final instrument = Instrument(
    instrumentId: '11111111-1111-4111-8111-111111111111',
    kind: InstrumentKind.creditCard,
    issuerSlug: 'hdfc',
    maskDigits: '1234',
    displayName: 'HDFC credit card',
    status: InstrumentStatus.detected,
    firstSeenAt: DateTime.utc(2026, 11, 1),
    lastSeenAt: DateTime.utc(2026, 11, 2),
    evidenceCount: 2,
    creditLimitMinor: 10000000,
    availableMinor: 7500000,
  );
  final item = LocalReviewItem(
    id: 'synthetic-review',
    kind: 'template',
    payload: const {
      'sourceKey': 'synthetic-source',
      'templateHash': 'synthetic-template',
      'hasReading': true,
      'reading': '₹499 spent at SWIGGY',
    },
    message: SmsIntakeEntry(
      'synthetic-source',
      QueuedSms(
        sender: 'VM-HDFCBK-S',
        body: 'Rs.499 spent on HDFC card xx1234 at SWIGGY.',
        receivedAt: DateTime.utc(2026, 11, 1),
      ),
    ),
  );
  for (final dark in [false, true]) {
    final name = dark ? 'dark' : 'light';
    Widget frame(Widget child) => Theme(
      data: dark ? ThemeData.dark() : ThemeData.light(),
      child: SizedBox(width: 390, height: 650, child: Material(child: child)),
    );
    goldenTest(
      'SMS review surfaces $name',
      fileName: 'sms_review_$name',
      builder: () => GoldenTestGroup(
        columns: 3,
        children: [
          GoldenTestScenario(
            name: 'Accounts found',
            child: frame(
              FoundInstrumentsList(
                instruments: [instrument],
                onConfirm: (_) {},
                onReject: (_) {},
                onRename: (_) {},
                onOpen: (_) {},
              ),
            ),
          ),
          GoldenTestScenario(
            name: 'Format inbox',
            child: frame(ReviewInboxList(items: [item], onAction: (_, __) {})),
          ),
          GoldenTestScenario(
            name: 'Why this',
            child: frame(
              WhyContent(
                trace: const {
                  'ruleId': 'HDFC-CARD',
                  'ruleVersion': 4,
                  'category': {'source': 'user'},
                  'event': {'linkRuleId': 'LINK-CARD-BILL'},
                },
                onReport: () {},
              ),
            ),
          ),
        ],
      ),
    );
  }
}
