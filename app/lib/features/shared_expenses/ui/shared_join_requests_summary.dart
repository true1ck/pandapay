import 'package:flutter/material.dart';
import '../../../app/design/app_theme.dart';
import '../data/shared_directory.dart';

/// The name of the split a request is for, as the owner reads it.
String sharedRequestSplitName(SharedJoinRequest r) =>
    r.isDirect ? 'your split' : r.contextName;

/// "Goa trip, Flat 4B and 1 more" for the splits that have waiting requests.
String sharedRequestSplitsLine(List<SharedJoinRequest> requests) {
  final names = <String>[];
  for (final r in requests) {
    final name = sharedRequestSplitName(r);
    if (!names.contains(name)) names.add(name);
  }
  if (names.length <= 2) return names.join(' and ');
  final extra = names.length - 2;
  return '${names[0]}, ${names[1]} and $extra more';
}

/// The title of the summary row for [requests] (at least one).
String sharedRequestsSummaryTitle(List<SharedJoinRequest> requests) {
  if (requests.length == 1) {
    final r = requests.single;
    return '${r.label ?? 'Someone'} wants to join ${sharedRequestSplitName(r)}';
  }
  return '${requests.length} people want to join';
}

/// One slim row that replaces the pile of inline request cards. Hidden (no
/// space at all) when nobody is waiting.
class SharedJoinRequestsSummary extends StatelessWidget {
  final List<SharedJoinRequest> requests;
  final VoidCallback onReview;
  const SharedJoinRequestsSummary({
    super.key,
    required this.requests,
    required this.onReview,
  });

  @override
  Widget build(BuildContext context) {
    if (requests.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final title = sharedRequestsSummaryTitle(requests);
    final detail = requests.length == 1
        ? 'Tap Review to approve or decline.'
        : sharedRequestSplitsLine(requests);
    return Semantics(
      container: true,
      button: true,
      label: '$title. $detail. Review',
      excludeSemantics: true,
      onTap: onReview,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: InkWell(
            key: const Key('join-requests-summary'),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: onReview,
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Row(
                children: [
                  Icon(
                    Icons.person_add_alt_1_outlined,
                    size: 20,
                    color: scheme.tertiary,
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: BambooFonts.heading(
                            15,
                          ).copyWith(color: scheme.onSurface),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: BambooFonts.ui(
                            12.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  // Looks like the action; the whole row is the tap target.
                  ExcludeSemantics(
                    child: TextButton.icon(
                      onPressed: onReview,
                      iconAlignment: IconAlignment.end,
                      icon: const Icon(Icons.chevron_right_rounded, size: 18),
                      label: const Text('Review'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
