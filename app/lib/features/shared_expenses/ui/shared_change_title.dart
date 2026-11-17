import '../storage/shared_store.dart' show SharedQueuedCommand;

/// Plain-language name of a saved change that did not sync. Never shows ids or
/// queue vocabulary; the wording uses what the person typed.
String sharedAttentionTitle(SharedQueuedCommand queued) {
  final payload = (queued.command.toJson()['payload'] as Map);
  String quoted(String key) {
    final value = payload[key];
    return value is String && value.trim().isNotEmpty ? '“$value”' : '';
  }

  return switch (queued.command.kind) {
    'context.create' =>
      payload['contextKind'] == 'direct'
          ? 'Add friend ${quoted('name')}'.trim()
          : 'Create group ${quoted('name')}'.trim(),
    'member.invite' => 'Add ${quoted('displayName')} to a split'.replaceAll(
      '  ',
      ' ',
    ),
    'member.rename' => 'Rename someone to ${quoted('displayName')}'.trim(),
    'membership.respond' => 'Answer a request to join',
    'expense.propose' => 'Add expense ${quoted('title')}'.trim(),
    'expense.respond' =>
      payload['decision'] == 'reject'
          ? 'Reject an expense'
          : 'Approve an expense',
    'settlement.report' => 'Report a payment',
    'settlement.respond' =>
      payload['decision'] == 'reject'
          ? 'Reject a payment report'
          : 'Confirm a payment report',
    _ => 'A change to a split',
  };
}
