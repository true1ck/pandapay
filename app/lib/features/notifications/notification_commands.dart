import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart'
    show
        commandOutboxProvider,
        commandOutboxRevisionProvider,
        isOnlineProvider,
        notificationPreferencesRepositoryProvider,
        notificationsProvider,
        outboxFlushRequestProvider,
        pendingOutboxCountProvider,
        userCardsRepositoryProvider;
import '../../data/local_first/command_outbox.dart';
import '../../data/notification_preferences_repository.dart';
import '../../data/user_cards_repository.dart';
import 'notification_local_state.dart';

/// WP-C4: notification work that has to survive a missing network goes through
/// the [CommandOutbox]. Kinds and handlers live here (not in providers.dart);
/// `commandHandlersFor` only spreads [notificationCommandHandlers].
abstract final class NotificationCommand {
  /// Writes one inbox row. Replaying it is harmless: the server keeps one row
  /// per dedupe key (a key is generated when the caller had none).
  static const recordAppNotification = 'recordAppNotification';

  /// Sets some notification preference columns. Latest value per column wins.
  static const updatePreferences = 'notification_prefs_update';

  static const muteMerchant = 'notification_mute_merchant';
  static const unmuteMerchant = 'notification_unmute_merchant';
}

Map<String, CommandHandler> notificationCommandHandlers({
  required UserCardsRepository userCards,
  NotificationPreferencesRepository? prefs,
  void Function()? onInboxSynced,
}) {
  NotificationPreferencesRepository need() =>
      prefs ?? (throw StateError('Notification settings are not available yet'));
  return {
    NotificationCommand.recordAppNotification: (p) async {
      await userCards.replayQueuedNotification(
        category: p['category'] as String,
        title: p['title'] as String,
        body: p['body'] as String?,
        severity: p['severity'] as String? ?? 'info',
        deepLink: p['deepLink'] as String?,
        dedupeKey: p['dedupeKey'] as String,
        clientMutationId: p['clientMutationId'] as String?,
        createdAt: DateTime.tryParse(p['createdAt'] as String? ?? ''),
      );
      onInboxSynced?.call();
    },
    NotificationCommand.updatePreferences: (p) async {
      await need().update(Map<String, dynamic>.from(p['changes'] as Map));
    },
    NotificationCommand.muteMerchant: (p) =>
        need().muteMerchant(p['merchantId'] as String),
    NotificationCommand.unmuteMerchant: (p) =>
        need().unmuteMerchant(p['merchantId'] as String),
  };
}

/// What happened to an inbox row.
enum InboxWrite {
  /// The server has it.
  posted,

  /// Could not reach the server; it is queued and will be sent later.
  queued,

  /// Nothing to write to (guest mode has no server-side inbox).
  skipped,

  /// Neither sent nor queued.
  lost,
}

/// Records an inbox entry: one immediate attempt (as before), then a durable
/// queued command if that fails. Never throws. [timeout] bounds the immediate
/// attempt (the gate passes one so captive Wi-Fi cannot hold a notification).
Future<InboxWrite> recordAppNotificationOutcome(
  dynamic ref, {
  required String category,
  required String title,
  String? body,
  String severity = 'info',
  String? deepLink,
  String? dedupeKey,
  Duration? timeout,
}) async {
  final repo = ref.read(userCardsRepositoryProvider) as UserCardsRepository?;
  if (repo == null) return InboxWrite.skipped;
  final knownOffline = _knownOffline(ref);
  if (!knownOffline) {
    try {
      var call = repo.recordNotification(
        category: category,
        title: title,
        body: body,
        severity: severity,
        deepLink: deepLink,
        dedupeKey: dedupeKey,
      );
      if (timeout != null) call = call.timeout(timeout);
      await call;
      try {
        ref.invalidate(notificationsProvider);
      } catch (_) {}
      return InboxWrite.posted;
    } catch (_) {
      // Fall through to the queue.
    }
  }
  try {
    final commands = await ref.read(commandOutboxProvider.future) as CommandOutbox;
    final mutationId = const Uuid().v4();
    final key = dedupeKey ?? 'client:$mutationId';
    commands.enqueue(
      kind: NotificationCommand.recordAppNotification,
      target: key,
      payload: {
        'category': category,
        'title': title,
        'body': body,
        'severity': severity,
        'deepLink': deepLink,
        'dedupeKey': key,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'clientMutationId': mutationId,
      },
    );
    _announceQueueChange(ref);
    return InboxWrite.queued;
  } catch (_) {
    return InboxWrite.lost;
  }
}

void _announceQueueChange(dynamic ref) {
  try {
    ref.read(commandOutboxRevisionProvider.notifier).state++;
    ref.read(outboxFlushRequestProvider.notifier).state++;
    ref.invalidate(pendingOutboxCountProvider);
  } catch (_) {}
}

/// Result of a settings write.
enum SettingsWrite {
  /// The server confirmed it.
  saved,

  /// Applied on this phone and queued; it syncs when the network is back.
  queued,
}

/// True only when the phone's radio is known to be down. (`valueOrNull` is an
/// extension, so the dynamic [ref] result needs its static type back first.)
bool _knownOffline(dynamic ref) {
  try {
    // The app shell keeps isOnlineProvider alive for the whole session. Only
    // read it when it is already running, so a unit test with no connectivity
    // plugin never starts the real stream.
    if (ref.exists(isOnlineProvider) != true) return false;
    return (ref.read(isOnlineProvider) as AsyncValue<bool>).valueOrNull ==
        false;
  } catch (_) {
    return false;
  }
}

/// Changes notification preferences. The phone's copy changes first, so every
/// alert decision sees the new value at once; the server write is always a
/// queued background command (retried with backoff), never awaited here.
Future<SettingsWrite> updateNotificationPreferences(
  dynamic ref,
  Map<String, dynamic> changes,
) async {
  final repo =
      ref.read(notificationPreferencesRepositoryProvider)
          as NotificationPreferencesRepository?;
  if (repo == null) return SettingsWrite.saved;
  final state = await NotificationLocalState.open(ref);
  final before =
      (await state?.readPreferences())?.prefs ?? NotificationPreferences.defaults;
  await state?.writePreferences(
    NotificationPreferences.fromJson({...before.toJson(), ...changes}),
  );
  refreshNotificationPreferences(ref);

  CommandOutbox? commands;
  try {
    commands = await ref.read(commandOutboxProvider.future) as CommandOutbox;
  } catch (_) {}
  final waiting =
      commands?.pendingOf({NotificationCommand.updatePreferences}) ?? const [];
  if (commands == null) return SettingsWrite.saved;
  final merged = <String, dynamic>{
    for (final w in waiting)
      ...Map<String, dynamic>.from(w.payload['changes'] as Map),
    ...changes,
  };
  commands.enqueue(
    kind: NotificationCommand.updatePreferences,
    target: 'notification_preferences',
    payload: {'changes': merged},
  );
  _announceQueueChange(ref);
  // Local first: the copy above is already the saved value and the send is
  // background work, so the "saved on this phone" note is only for offline.
  return _knownOffline(ref) ? SettingsWrite.queued : SettingsWrite.saved;
}

/// Mutes a merchant's notifications. Same shape as
/// [updateNotificationPreferences]: local copy first, then a queued background send.
Future<SettingsWrite> muteNotificationMerchant(
  dynamic ref,
  String merchantId, {
  String merchantName = 'Unknown merchant',
}) => _changeMute(ref, merchantId, mute: true, merchantName: merchantName);

Future<SettingsWrite> unmuteNotificationMerchant(
  dynamic ref,
  String merchantId,
) => _changeMute(ref, merchantId, mute: false);

Future<SettingsWrite> _changeMute(
  dynamic ref,
  String merchantId, {
  required bool mute,
  String merchantName = 'Unknown merchant',
}) async {
  final repo =
      ref.read(notificationPreferencesRepositoryProvider)
          as NotificationPreferencesRepository?;
  if (repo == null) return SettingsWrite.saved;
  final state = await NotificationLocalState.open(ref);
  final before = (await state?.readMutedMerchants())?.items ?? const [];
  final after = mute
      ? [
          if (!before.any((m) => m.merchantId == merchantId))
            MutedMerchant(
              merchantId: merchantId,
              mutedAt: DateTime.now(),
              merchantName: merchantName,
            ),
          ...before,
        ]
      : [
          for (final m in before)
            if (m.merchantId != merchantId) m,
        ];
  await state?.writeMutedMerchants(after);

  CommandOutbox? commands;
  try {
    commands = await ref.read(commandOutboxProvider.future) as CommandOutbox;
  } catch (_) {}
  final target = 'merchant:$merchantId';
  if (commands == null) return SettingsWrite.saved;
  final queued = commands.enqueue(
    kind: mute
        ? NotificationCommand.muteMerchant
        : NotificationCommand.unmuteMerchant,
    target: target,
    payload: {'merchantId': merchantId},
    cancels: [
      mute
          ? NotificationCommand.unmuteMerchant
          : NotificationCommand.muteMerchant,
    ],
  );
  _announceQueueChange(ref);
  // An opposite command that was still queued cancelled this one: the server
  // never heard of either, so there is nothing left to send.
  return queued && _knownOffline(ref)
      ? SettingsWrite.queued
      : SettingsWrite.saved;
}
