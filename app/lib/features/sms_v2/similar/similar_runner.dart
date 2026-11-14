import 'package:flutter/material.dart';

import '../../../app/design/app_theme.dart';
import 'similar_changes.dart';

/// Applies a change to the ticked transactions without holding the person up.
///
/// The sheet has already closed. A thin banner at the top shows the progress
/// and can be stopped; the person can keep using the app, or leave the screen,
/// while it runs. When it ends, the banner is replaced by a result bar, with
/// Undo when the change can be taken back. Nothing here touches the screen
/// that started it, so it still finishes after that screen is gone.
Future<void> applySimilarInBackground({
  required ScaffoldMessengerState messenger,
  required SimilarChanges changes,
  required SimilarOffer offer,
  required Set<String> eventIds,
  required VoidCallback onChanged,
}) async {
  if (eventIds.isEmpty) return;
  final total = eventIds.length;
  final done = ValueNotifier<int>(0);
  var stop = false;
  messenger.hideCurrentMaterialBanner();
  messenger.showMaterialBanner(
    MaterialBanner(
      backgroundColor: BambooInk.paper,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      content: ValueListenableBuilder<int>(
        valueListenable: done,
        builder: (context, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Changing $value of $total…',
              style: BambooFonts.ui(13, color: BambooInk.ink900),
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: total == 0 ? null : value / total),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => stop = true, child: const Text('Stop'))],
    ),
  );
  try {
    final result = await changes.apply(
      offer,
      onlyEventIds: eventIds,
      onProgress: (value, _) => done.value = value,
      shouldContinue: () => !stop,
    );
    messenger.hideCurrentMaterialBanner();
    onChanged();
    final waiting = result.awaitingSync > 0
        ? ' ${result.awaitingSync} still syncing; try again after the next sync.'
        : '';
    final changeId = result.changeId;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        persist: false,
        content: Text(
          result.stopped
              ? 'Stopped after changing ${result.changed}.$waiting'
              : 'Changed ${result.changed} other transaction${result.changed == 1 ? '' : 's'}.$waiting',
        ),
        action: changeId == null
            ? null
            : SnackBarAction(
                label: 'Undo',
                onPressed: () {
                  changes.undo(changeId);
                  onChanged();
                },
              ),
      ),
    );
  } catch (_) {
    messenger.hideCurrentMaterialBanner();
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Couldn\'t change the others. This transaction is saved; you can try again from its edit screen.',
        ),
      ),
    );
  } finally {
    done.dispose();
  }
}
