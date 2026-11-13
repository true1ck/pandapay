import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../data/user_cards_repository.dart';
import 'spend_exclusion.dart';

/// Other transactions that share something with one the person just left out
/// of spending: the same merchant, or the same tag (for example Family).
class ExclusionMatchGroup {
  const ExclusionMatchGroup({required this.label, required this.entries});
  final String label;
  final List<TransactionEntry> entries;
}

String _merchantKey(String? name) {
  final n = (name ?? '').trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
  return n == 'UNKNOWN' ? '' : n;
}

/// The groups worth offering, from the transactions already loaded: only rows
/// that could still be left out, never the source itself, empty groups dropped.
/// A row in two groups is listed in both; applying counts it once.
List<ExclusionMatchGroup> exclusionMatches(
  TransactionEntry source,
  Iterable<TransactionEntry> all,
) {
  final open = [
    for (final e in all)
      if (e.id != source.id && canExcludeFromSpend(e) && !e.excludeFromSpend) e,
  ];
  final groups = <ExclusionMatchGroup>[];
  final key = _merchantKey(source.merchantName);
  if (key.isNotEmpty) {
    final same = [
      for (final e in open)
        if (_merchantKey(e.merchantName) == key) e,
    ];
    if (same.isNotEmpty) {
      groups.add(
        ExclusionMatchGroup(
          label: 'Same merchant: ${source.merchantName!.trim()}',
          entries: same,
        ),
      );
    }
  }
  for (final tag in source.tags) {
    final tagged = [
      for (final e in open)
        if (e.tags.any((t) => t.id == tag.id)) e,
    ];
    if (tagged.isNotEmpty) {
      groups.add(
        ExclusionMatchGroup(label: 'Tagged ${tag.name}', entries: tagged),
      );
    }
  }
  return groups;
}

/// Asks which matches to leave out too. Nothing is ticked at first, and nothing
/// changes until the person confirms. Returns the chosen rows (each once), or
/// null when they skip.
Future<List<TransactionEntry>?> showExclusionMatchesSheet(
  BuildContext context,
  List<ExclusionMatchGroup> groups,
) {
  return showModalBottomSheet<List<TransactionEntry>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: BambooInk.paper,
    builder: (sheet) => _MatchesSheet(groups: groups),
  );
}

class _MatchesSheet extends StatefulWidget {
  const _MatchesSheet({required this.groups});
  final List<ExclusionMatchGroup> groups;

  @override
  State<_MatchesSheet> createState() => _MatchesSheetState();
}

class _MatchesSheetState extends State<_MatchesSheet> {
  final _ticked = <int>{};

  List<TransactionEntry> get _chosen {
    final seen = <String>{};
    return [
      for (final i in _ticked)
        for (final e in widget.groups[i].entries)
          if (seen.add(e.id)) e,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final count = _chosen.length;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Leave out similar transactions too?',
              style: BambooFonts.heading(18, color: BambooInk.ink900),
            ),
            const SizedBox(height: 4),
            Text(
              'Nothing changes unless you tick it and confirm.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink700),
            ),
            const SizedBox(height: AppSpace.sm),
            for (var i = 0; i < widget.groups.length; i++)
              CheckboxListTile(
                key: Key('exclusion-match-$i'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _ticked.contains(i),
                onChanged: (v) => setState(() {
                  v == true ? _ticked.add(i) : _ticked.remove(i);
                }),
                title: Text(widget.groups[i].label),
                subtitle: Text('${widget.groups[i].entries.length} transactions'),
              ),
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Not now'),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('exclusion-match-apply'),
                  onPressed: count == 0
                      ? null
                      : () => Navigator.of(context).pop(_chosen),
                  child: Text(count == 0 ? 'Leave out' : 'Leave out $count'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
