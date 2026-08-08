import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../data/api_exception.dart';
import '../../data/changelog_repository.dart';
import 'whats_new_providers.dart';

/// Task H10 (What's New).
///
/// [WhatsNewContent] is the reusable core — rendered both inside a
/// `showModalBottomSheet` (the automatic post-launch prompt) and inside a
/// normal pushed [WhatsNewScreen] (the manual "What's New" row in H1's
/// Settings Hub, wired by a later task).
class WhatsNewContent extends ConsumerWidget {
  const WhatsNewContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final changelog = ref.watch(changelogProvider);
    final textTheme = Theme.of(context).textTheme;

    return changelog.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpace.xxl),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: ErrorState(
          message: userFacingErrorMessage(error),
          onRetry: () => ref.invalidate(changelogProvider),
        ),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(AppSpace.xxl),
            child: Center(
              child: Text("No updates yet", style: textTheme.bodyMedium),
            ),
          );
        }
        return ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.all(AppSpace.lg),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const SizedBox(height: AppSpace.lg),
          itemBuilder: (context, index) => _ChangelogEntryCard(entry: entries[index]),
        );
      },
    );
  }
}

class _ChangelogEntryCard extends StatelessWidget {
  final ChangelogEntry entry;

  const _ChangelogEntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(entry.title, style: textTheme.titleMedium),
                ),
                if (entry.highlightsDataChange) ...[
                  const SizedBox(width: AppSpace.sm),
                  const StatusPill(
                    label: 'Affects your recommendations',
                    foreground: AppColors.warning,
                    background: AppColors.warningBg,
                    icon: Icons.bolt_rounded,
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              '${entry.appVersion} · ${DateFormat.yMMMd().format(entry.publishedAt)}',
              style: textTheme.labelSmall,
            ),
            const SizedBox(height: AppSpace.md),
            _MarkdownLiteBody(source: entry.bodyMarkdown),
          ],
        ),
      ),
    );
  }
}

/// Deliberately not a real markdown renderer — no markdown package exists in
/// pubspec.yaml today, and adding one for a single settings screen is more
/// weight than this content warrants (per the plan's own scoping note).
/// Handles exactly two constructs: `**bold**` spans and leading `- ` bullet
/// lines, rendered as a single `Text.rich` per line.
class _MarkdownLiteBody extends StatelessWidget {
  final String source;

  const _MarkdownLiteBody({required this.source});

  @override
  Widget build(BuildContext context) {
    final bodyStyle = Theme.of(context).textTheme.bodyMedium;
    final lines = source.split('\n').where((l) => l.trim().isNotEmpty).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final rawLine in lines) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.xs),
            child: _boldSpans(rawLine, bodyStyle),
          ),
        ],
      ],
    );
  }

  Widget _boldSpans(String rawLine, TextStyle? bodyStyle) {
    var line = rawLine.trim();
    final isBullet = line.startsWith('- ');
    if (isBullet) line = '•  ${line.substring(2)}';

    final spans = <TextSpan>[];
    final boldPattern = RegExp(r'\*\*(.+?)\*\*');
    var cursor = 0;
    for (final match in boldPattern.allMatches(line)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: line.substring(cursor, match.start)));
      }
      spans.add(TextSpan(
        text: match.group(1),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ));
      cursor = match.end;
    }
    if (cursor < line.length) {
      spans.add(TextSpan(text: line.substring(cursor)));
    }
    return Text.rich(TextSpan(style: bodyStyle, children: spans));
  }
}

/// The normal pushed-screen entry point — H1's "What's New" row (manual
/// re-read), wired by a later task.
class WhatsNewScreen extends StatelessWidget {
  const WhatsNewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("What's New")),
      body: const WhatsNewContent(),
    );
  }
}

/// Compares two `app_version` strings loosely as dot-separated integer
/// components (e.g. "1.10.0" > "1.9.0"). NOT full semver (no pre-release/
/// build-metadata handling) — deliberately simplified per the plan's own
/// note that a not-equal check against the stored last-seen value combined
/// with "at least one entry has a different version" is an acceptable
/// simplification for this feature. Returns true if [a] is newer than [b].
bool _isNewerVersion(String a, String b) {
  if (a == b) return false;
  final partsA = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final partsB = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final len = partsA.length > partsB.length ? partsA.length : partsB.length;
  for (var i = 0; i < len; i++) {
    final va = i < partsA.length ? partsA[i] : 0;
    final vb = i < partsB.length ? partsB[i] : 0;
    if (va != vb) return va > vb;
  }
  return false;
}

/// Designed to be called once from Home right after first render post-launch
/// (wired by a later task, not this one). Fetches the real current app
/// version via `package_info_plus`, compares it against
/// [lastSeenAppVersionProvider]'s stored value, and — only if there's also
/// at least one changelog entry whose `app_version` differs from (and is
/// not older than) the stored last-seen value — shows [WhatsNewContent] in
/// a modal bottom sheet. On dismiss, marks the current version as seen so
/// the sheet doesn't reappear on the next launch without a version bump.
Future<void> maybeShowWhatsNewSheet(BuildContext context, WidgetRef ref) async {
  final packageInfo = await PackageInfo.fromPlatform();
  final currentVersion = packageInfo.version;

  // lastSeenAppVersionProvider is a StateNotifierProvider (not an
  // AsyncNotifierProvider), so there's no `.future` to await here — matches
  // the same `.valueOrNull` read pattern router.dart/tutorial_overlay.dart
  // already use for onboardingCompleteProvider/tutorialSeenProvider. In
  // practice this resolves near-instantly (a single SharedPreferences
  // read), and this function is only ever called after Home's first
  // render, well after app init has had time to complete.
  final lastSeen = ref.read(lastSeenAppVersionProvider).valueOrNull;
  if (lastSeen == currentVersion) return;

  final entries = await ref.read(changelogProvider.future);
  final hasNewerEntry = entries.any((entry) {
    if (lastSeen == null) return true;
    return entry.appVersion != lastSeen && !_isNewerVersion(lastSeen, entry.appVersion);
  });
  if (!hasNewerEntry) return;

  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (_) => const SafeArea(child: WhatsNewContent()),
  );

  await ref.read(lastSeenAppVersionProvider.notifier).markSeen(currentVersion);
}
