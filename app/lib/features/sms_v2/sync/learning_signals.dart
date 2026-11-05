import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../data/local/sms_intake_repository.dart';
import '../../../data/sms_fact_contract.dart' show smsSpendCategories;
import '../../../data/user_cards_repository.dart' show TransactionEntry;
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';
import '../storage/sync_state_store.dart';

final _key = RegExp(r"^[A-Z][A-Z0-9 &'.-]{1,59}$");
final _name = RegExp(r"^[A-Z][A-Z &'.-]{1,39}$");
final _digits = RegExp(r'\d{4,}');

/// Six digits anywhere, even split by spaces (a phone or account number).
final _manyDigits = RegExp(r'^(?:\D*\d){6}');

/// One anonymised shop signal: which category a person picked for a shop
/// (`category_choice`), what a shop is really called (`merchant_name`), or a
/// shop the rules left in "Other" (`uncategorised`). Nothing here is an amount,
/// a date, an account or a person.
class LearningSignal {
  const LearningSignal({
    required this.kind,
    required this.senderBrand,
    required this.merchantKey,
    this.value = '',
  });

  final String kind, senderBrand, merchantKey, value;

  /// Repeats of the same signal collapse into one queued record.
  String get id => '$kind:$merchantKey:$value';

  Map<String, Object?> toJson() => {
    'kind': kind,
    'senderBrand': senderBrand,
    'merchantKey': merchantKey,
    'value': value,
  };
}

/// The anonymised learning signal for one spend, or null when it must not be
/// shared: not a purchase, a person or own account, or a key that could
/// identify someone.
LearningSignal? learningSignalFor({
  required String kind,
  required EventType eventType,
  required Counterparty? counterparty,
  required String sender,
  String value = '',
}) {
  if (eventType != EventType.purchase || counterparty == null) return null;
  if (counterparty.kind == CounterpartyKind.person ||
      counterparty.kind == CounterpartyKind.own) {
    return null;
  }
  // Check the printed name too: normalising turns "@" into a space.
  final raw = counterparty.name ?? '';
  final key = normalizeMerchantText(raw);
  if (raw.contains('@') ||
      !_key.hasMatch(key) ||
      _digits.hasMatch(key) ||
      _manyDigits.hasMatch(key)) {
    return null;
  }
  final brand = smsTemplateBrand(sender);
  if (!RegExp(r'^[A-Z0-9]{1,32}$').hasMatch(brand)) return null;
  final cleanValue = switch (kind) {
    'category_choice' => smsSpendCategories.contains(value) ? value : null,
    'merchant_name' => () {
      final name = normalizeMerchantText(value);
      return _name.hasMatch(name) && name != key ? name : null;
    }(),
    'uncategorised' => '',
    _ => null,
  };
  if (cleanValue == null) return null;
  return LearningSignal(
    kind: kind,
    senderBrand: brand,
    merchantKey: key,
    value: cleanValue,
  );
}

/// Queues a signal. Callers check the sharing opt-in first; the upload checks
/// it again before anything leaves the phone.
void enqueueLearningSignal(OutboxStore queue, LearningSignal signal) =>
    queue.enqueue('signal', signal.id, signal.toJson());

/// The event behind a display row: its type, the money fact's counterparty and
/// the sender of the message that produced it. Null when any of it is missing
/// (the original SMS was forgotten, or the event has no money fact).
({EventType type, Counterparty? counterparty, String sender})? _shopOfEvent(
  Database db,
  SmsIntakeRepository intake,
  String namespace,
  String eventId,
) {
  final events = EventStore(db, namespace: namespace);
  final facts = FactStore(db, namespace: namespace);
  final event = events.get(eventId);
  if (event == null) return null;
  final byId = <String, Fact>{
    for (final leg in event.legs) leg.factId: ?facts.get(leg.factId),
  };
  final money = moneyFactForEvent(event, byId);
  if (money == null) return null;
  final anchor = byId[event.eventId] ?? money;
  final sender = intake.capturedById(namespace, anchor.sourceKey)?.message.sender;
  if (sender == null) return null;
  return (type: event.type, counterparty: money.counterparty, sender: sender);
}

/// One `category_choice` per distinct shop among the selected rows of a bulk
/// category change. Rows that are not SMS v2 readings, or are already in the
/// chosen category, teach nothing.
List<LearningSignal> categoryChoiceSignalsForEntries({
  required Database db,
  required SmsIntakeRepository intake,
  required String namespace,
  required Iterable<TransactionEntry> entries,
  required String categorySlug,
  String? chosenCategoryId,
}) {
  final signals = <String, LearningSignal>{};
  for (final entry in entries) {
    final eventId = entry.eventId;
    if (entry.pipelineVersion != 2 || eventId == null) continue;
    if (chosenCategoryId != null && entry.categoryId == chosenCategoryId) {
      continue;
    }
    final shop = _shopOfEvent(db, intake, namespace, eventId);
    if (shop == null) continue;
    final signal = learningSignalFor(
      kind: 'category_choice',
      eventType: shop.type,
      counterparty: shop.counterparty,
      sender: shop.sender,
      value: categorySlug,
    );
    if (signal != null) signals[signal.id] = signal;
  }
  return signals.values.toList();
}

/// Sends queued shop signals, and finds shops the rules left in "Other".
/// Nothing is queued or sent without the sharing opt-in: consent is checked
/// before and after every request, and when it is gone the queue is emptied.
class LearningSignalUpload {
  LearningSignalUpload({
    required this.intake,
    required this.queue,
    required this.client,
    required this.baseUri,
    required this.headers,
    required this.hasConsent,
    required this.accountIsCurrent,
    required this.taxonomyVersion,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final SmsIntakeRepository intake;
  final OutboxStore queue;
  final http.Client client;
  final Uri baseUri;
  final Future<Map<String, String>> Function() headers;
  final Future<bool> Function() hasConsent;
  final bool Function() accountIsCurrent;
  final int Function() taxonomyVersion;
  final DateTime Function() clock;

  Future<bool> _canShare() async {
    if (!accountIsCurrent()) return false;
    final bool consent;
    try {
      consent = await hasConsent();
    } catch (_) {
      return false;
    }
    if (!accountIsCurrent()) return false;
    if (!consent) {
      queue.db.execute('SAVEPOINT sms_v2_signal_revoke');
      try {
        queue.db.execute(
          "DELETE FROM v2_outbox WHERE namespace=? AND kind='signal'",
          [queue.namespace],
        );
        // Without these the shops could never be reported again after the
        // server deleted them on withdrawal.
        queue.db.execute(
          "DELETE FROM v2_sync_state WHERE namespace=? AND key LIKE 'signal:uncat:%'",
          [queue.namespace],
        );
        queue.db.execute('RELEASE sms_v2_signal_revoke');
      } catch (_) {
        queue.db.execute('ROLLBACK TO sms_v2_signal_revoke');
        queue.db.execute('RELEASE sms_v2_signal_revoke');
        rethrow;
      }
    }
    return consent;
  }

  /// Queues each shop whose spends the rules left in "Other", once per shop
  /// per account (state key `signal:uncat:<key>`).
  int collectUncategorised() {
    final state = SyncStateStore(queue.db, namespace: queue.namespace);
    final decisions = LedgerStore(
      queue.db,
      namespace: queue.namespace,
    ).categoryDecisions();
    var queued = 0;
    for (final entry in decisions.entries) {
      if (entry.value.source != CategorySource.fallback) continue;
      final shop = _shopOfEvent(queue.db, intake, queue.namespace, entry.key);
      if (shop == null) continue;
      final signal = learningSignalFor(
        kind: 'uncategorised',
        eventType: shop.type,
        counterparty: shop.counterparty,
        sender: shop.sender,
      );
      if (signal == null) continue;
      final marker = 'signal:uncat:${signal.merchantKey}';
      if (state.get(marker) != null) continue;
      enqueueLearningSignal(queue, signal);
      state.put(marker, clock().toUtc().toIso8601String());
      queued++;
    }
    return queued;
  }

  Future<void> drain() async {
    if (!await _canShare()) return;
    collectUncategorised();
    while (accountIsCurrent()) {
      if (!await _canShare()) return;
      final records = queue
          .due(clock(), limit: 2500)
          .where((item) => item.kind == 'signal')
          .take(50)
          .toList();
      if (records.isEmpty) return;
      try {
        final admission = await headers();
        if (!await _canShare()) return;
        final response = await client
            .post(
              baseUri.resolve('/sms/v2/learning-signals'),
              headers: {...admission, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'items': [
                  for (final record in records)
                    {
                      for (final key in [
                        'kind',
                        'senderBrand',
                        'merchantKey',
                        'value',
                      ])
                        key: record.json[key],
                      'eventType': 'purchase',
                      'taxonomyVersion': taxonomyVersion(),
                    },
                ],
              }),
            )
            .timeout(const Duration(seconds: 30));
        if (!await _canShare()) return;
        // 503 learning_paused, 429 and 403 are all "not now": the outbox backs
        // off and keeps the signal.
        if (response.statusCode != 200 && response.statusCode != 202) {
          throw const FormatException('Signal upload failed');
        }
        for (final record in records) {
          queue.acknowledge(record);
        }
      } catch (_) {
        for (final record in records) {
          queue.retry(record, clock());
        }
        return;
      }
    }
  }
}
