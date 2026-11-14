import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../app/providers.dart'
    show
        commandOutboxProvider,
        commandOutboxRevisionProvider,
        outboxFlushRequestProvider,
        pendingOutboxCountProvider;
import '../../data/local_first/command_outbox.dart';

/// WP-C11 kill switch. False restores the old "call the server and fail"
/// behaviour of every account / settings write below.
const kAccountLocalFirst = true;

/// Command kinds this package puts in the shared [CommandOutbox] (the table is
/// already in `QueueRegistry`, so the banner and sign-out count them).
abstract final class AccountCommand {
  /// One consent row (grant or withdrawal). Carries a client mutation id so a
  /// replay after a lost reply writes no second audit row.
  static const consentSubmit = 'consent_submit';

  /// The two-step profile name save (api `display_name`, then auth name).
  static const profileName = 'profile_name_save';
  static const contributionsOptIn = 'contributions_opt_in';

  /// A support ticket (client id makes a replay a no-op on a new server).
  static const supportTicket = 'support_ticket_submit';
  static const cardRequest = 'card_request_submit';
  static const dataErrorReport = 'data_error_report_submit';

  /// Inbox read marks; the target is the notification id or `all`.
  static const notificationRead = 'notification_mark_read';
  static const notificationReadAll = 'notification_mark_all_read';

  /// Merchant future-rule edits (carry the expected version).
  static const merchantRuleUpdate = 'merchant_rule_update';
  static const merchantRuleDisable = 'merchant_rule_disable';
}

String newClientId() => const Uuid().v4();

enum AccountWrite {
  /// The server accepted it now.
  sent,

  /// Saved on the phone; it will be sent when the network allows.
  queued,
}

/// Queues [kind] without calling the server. [ref] is a `WidgetRef` or `Ref`.
Future<void> queueAccountCommand(
  dynamic ref, {
  required String kind,
  required String target,
  required Map<String, Object?> payload,
  List<String> cancels = const [],
}) async {
  final commands = await ref.read(commandOutboxProvider.future) as CommandOutbox;
  commands.enqueue(
    kind: kind,
    target: target,
    payload: payload,
    cancels: cancels,
  );
  try {
    ref.read(commandOutboxRevisionProvider.notifier).state++;
    ref.read(outboxFlushRequestProvider.notifier).state++;
    ref.invalidate(pendingOutboxCountProvider);
  } catch (_) {}
}

/// Local first, always: the write is saved on the phone and queued, and the
/// outbox sends it in the background (retried until the server answers), so a
/// save never waits on the network. [live], [timeout] and [knownOffline] only
/// matter when [kAccountLocalFirst] is switched off.
Future<AccountWrite> sendOrQueue(
  dynamic ref, {
  required String kind,
  required String target,
  required Map<String, Object?> payload,
  required Future<void> Function() live,
  List<String> cancels = const [],
  Duration timeout = const Duration(seconds: 8),
  bool? knownOffline,
}) async {
  if (!kAccountLocalFirst) {
    await live();
    return AccountWrite.sent;
  }
  await queueAccountCommand(
    ref,
    kind: kind,
    target: target,
    payload: payload,
    cancels: cancels,
  );
  return AccountWrite.queued;
}

/// Copy for a write that was queued.
const savedOfflineMessage = 'Saved. We’ll sync it in the background.';
