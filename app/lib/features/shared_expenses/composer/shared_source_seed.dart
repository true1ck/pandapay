import 'package:pandapay_domain/shared_expenses.dart';
import 'package:uuid/uuid.dart';
import '../../../data/user_cards_repository.dart';
import '../data/shared_commands.dart';

/// Navigation intent only. Eligibility and current value still need server
/// admission; neither a visible row nor a syntactically valid ID proves funding.
class SharedSourceSeed {
  final String expenseId, amountText;
  final SharedExpenseSourceReference reference;
  SharedSourceSeed._(this.expenseId, this.amountText, this.reference);
  factory SharedSourceSeed.fromTransaction(
    String accountId,
    TransactionEntry entry,
  ) {
    if (!sharedUuid(accountId) ||
        entry.status != 'active' ||
        entry.entryKind != TxnEntryKind.spend ||
        entry.amount.paise <= 0 ||
        entry.amount.paise > 1000000000) {
      throw const FormatException('Choose a current purchase before sharing');
    }
    final event = entry.eventId;
    final v2 =
        entry.pipelineVersion == 2 &&
        event != null &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(event);
    if (!v2 && !sharedUuid(entry.id)) {
      throw const FormatException('Payment identity is not ready');
    }
    final reference = SharedExpenseSourceReference.parse({
      'kind': v2 ? 'sms_v2_event' : 'legacy_transaction',
      'ownerAccountId': accountId,
      if (v2) ...{'eventId': event, 'localProjectionId': 'v2:$event'},
      if (sharedUuid(entry.id)) ...{
        'canonicalTransactionId': entry.id,
        'sourceVersion': 'pending',
      },
    });
    return SharedSourceSeed._(
      const Uuid().v5(
        Namespace.url.value,
        'pandapay:source-expense:v1:$accountId:${v2 ? event : entry.id}',
      ),
      '${entry.amount.paise ~/ 100}.${(entry.amount.paise % 100).toString().padLeft(2, '0')}',
      reference,
    );
  }
}
