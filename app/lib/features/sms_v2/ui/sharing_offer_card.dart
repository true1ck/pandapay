import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/providers.dart' as app;
import '../../consent/template_sharing_disclosure.dart';

/// India's 2023 dark-pattern guidelines list nagging and confirm-shaming, so
/// the offer has two plain buttons, a 30-day snooze, and stops for good after
/// the third "Not now".
const sharingOfferSnooze = Duration(days: 30);
const sharingOfferMaxDismissals = 3;

/// The copy is fixed by the learning-loop plan (Task A3).
abstract final class SharingOfferCopy {
  static const title = 'Help PandaPay read messages like these';
  static const body =
      'Share anonymised message layouts and the categories you pick for '
      'shops, so a rule can be added for everyone. Amounts, names and numbers '
      'are removed.';
  static const turnOn = 'Turn on';
  static const notNow = 'Not now';
}

/// What this phone remembers about the offer for one account.
@immutable
class SharingOfferState {
  const SharingOfferState({this.snoozedUntil, this.dismissals = 0});

  final DateTime? snoozedUntil;
  final int dismissals;

  bool visibleAt(DateTime now) =>
      dismissals < sharingOfferMaxDismissals &&
      (snoozedUntil == null || !now.isBefore(snoozedUntil!));
}

/// The snooze date and the count, under `pandapay.sharing_offer.<namespace>`.
/// Sign-out clears every preference except the install marker, so this goes
/// with the rest of the account's preferences.
class SharingOfferStore {
  SharingOfferStore(this._prefs, this.namespace);

  final SharedPreferences _prefs;
  final String namespace;

  String get key => 'pandapay.sharing_offer.$namespace';

  SharingOfferState read() {
    final raw = _prefs.getString(key);
    if (raw == null) return const SharingOfferState();
    try {
      final map = (jsonDecode(raw) as Map).cast<String, Object?>();
      return SharingOfferState(
        snoozedUntil: DateTime.tryParse(map['snoozedUntil'] as String? ?? ''),
        dismissals: (map['dismissals'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return const SharingOfferState();
    }
  }

  Future<void> dismiss(DateTime now) async {
    final current = read();
    await _prefs.setString(
      key,
      jsonEncode({
        'snoozedUntil': now.add(sharingOfferSnooze).toUtc().toIso8601String(),
        'dismissals': current.dismissals + 1,
      }),
    );
  }
}

/// Overridden in tests; the real clock otherwise.
final sharingOfferClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final sharingOfferStateProvider =
    FutureProvider.autoDispose<SharingOfferState>((ref) async {
      final namespace = ref.watch(app.cacheNamespaceProvider);
      final prefs = await SharedPreferences.getInstance();
      return SharingOfferStore(prefs, namespace).read();
    });

/// Offered at the top of Review, where people meet messages the phone could
/// not read. Consent is recorded only inside the disclosure sheet, never by
/// this card.
class SharingOfferCard extends ConsumerWidget {
  const SharingOfferCard({super.key, required this.openItems});

  /// Open review items; the offer is only relevant while there is something
  /// to review.
  final int openItems;

  Future<void> _notNow(BuildContext context, WidgetRef ref) async {
    final namespace = ref.read(app.cacheNamespaceProvider);
    final prefs = await SharedPreferences.getInstance();
    await SharingOfferStore(
      prefs,
      namespace,
    ).dismiss(ref.read(sharingOfferClockProvider)());
    ref.invalidate(sharingOfferStateProvider);
  }

  Future<void> _turnOn(BuildContext context, WidgetRef ref) async {
    await TemplateSharingDisclosure.show(context, sourceScreen: 'review_inbox');
    ref.invalidate(app.smsSharedLearningConsentProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (openItems < 1) return const SizedBox.shrink();
    final consent = ref.watch(app.smsSharedLearningConsentProvider);
    // Not shown while the answer is unknown, or when it failed to load.
    if (!consent.hasValue || consent.value != null) {
      return const SizedBox.shrink();
    }
    final offer = ref.watch(sharingOfferStateProvider).valueOrNull;
    if (offer == null || !offer.visibleAt(ref.watch(sharingOfferClockProvider)())) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: BambooPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              SharingOfferCopy.title,
              style: BambooFonts.heading(16, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              SharingOfferCopy.body,
              style: BambooFonts.ui(13, color: BambooInk.ink700, height: 1.4),
            ),
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                FilledButton(
                  style: BambooButtons.primary,
                  onPressed: () => _turnOn(context, ref),
                  child: const Text(SharingOfferCopy.turnOn),
                ),
                const SizedBox(width: AppSpace.sm),
                TextButton(
                  style: BambooButtons.quiet,
                  onPressed: () => _notNow(context, ref),
                  child: const Text(SharingOfferCopy.notNow),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
