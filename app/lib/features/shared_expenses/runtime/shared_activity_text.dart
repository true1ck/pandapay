import 'package:pandapay_domain/pandapay_domain.dart' show Money;

import 'shared_expense_summary.dart';

/// One expense version as the phone stores it (a `revision` record of the
/// change feed): who wrote it, which version it replaced, and its values.
class SharedStoredRevision {
  const SharedStoredRevision({
    required this.revisionId,
    required this.expenseId,
    required this.title,
    required this.occurredOn,
    required this.totalMinor,
    required this.isVoid,
    this.authorProfileId,
    this.expectedHeadRevisionId,
    this.snapshot,
  });
  final String revisionId, expenseId, title;
  final String? occurredOn, authorProfileId, expectedHeadRevisionId;
  final int totalMinor;
  final bool isVoid;
  final Map<Object?, Object?>? snapshot;
}

/// What kind of thing an Activity card is about, for its icon.
enum SharedActivityKind { expense, payment, member, group, other }

/// A finished Activity card: a headline, the lines that say what changed, what
/// it means for the person, and where it happened.
class SharedActivityText {
  const SharedActivityText({
    required this.headline,
    this.details = const [],
    this.impact,
    this.kind = SharedActivityKind.other,
  });
  final String headline;
  final List<String> details;
  final String? impact;
  final SharedActivityKind kind;
}

String _money(int minor) => Money.fromPaise(minor).format();

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _day(String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  return d == null ? (iso ?? '') : '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// "Priya added “Groceries”", with the amount, who paid and how it was split on
/// the next line, and what it means for you under that. An edit says what
/// changed, from what to what, against the version it replaced.
///
/// [names] maps member ids to display names, [profiles] maps account ids to
/// names (both already say "You" for the viewer) and [own] is the viewer's
/// member id.
SharedActivityText describeExpenseEvent({
  required String kind,
  required SharedStoredRevision? revision,
  required SharedStoredRevision? previous,
  required Map<Object?, Object?> names,
  required Map<String, String> profiles,
  required String? own,
  String? responderName,
}) {
  final rev = revision;
  if (rev == null) {
    return SharedActivityText(
      headline: switch (kind) {
        'expense.proposed' => 'An expense was proposed',
        'expense.responded' => 'An expense was reviewed',
        _ => 'An expense was added or changed',
      },
      kind: SharedActivityKind.expense,
    );
  }
  final author = rev.authorProfileId == null
      ? null
      : profiles[rev.authorProfileId];
  final who = kind == 'expense.responded'
      ? (responderName ?? 'Someone')
      : (author ?? 'Someone');
  final summary = SharedExpenseSummary.from(rev.snapshot, names, own);
  final waiting = kind == 'expense.proposed' ? ' · waiting for approval' : '';
  final title = '“${rev.title}”';

  if (kind == 'expense.responded') {
    return SharedActivityText(
      headline: '$who reviewed $title',
      details: [
        if (summary != null)
          '${_money(rev.totalMinor)} · ${summary.paidSentence}',
      ],
      kind: SharedActivityKind.expense,
    );
  }
  if (rev.isVoid) {
    final was = previous;
    return SharedActivityText(
      headline: '$who removed $title',
      details: [
        if (was != null) 'It was ${_money(was.totalMinor)}',
        'It no longer counts in balances',
      ],
      kind: SharedActivityKind.expense,
    );
  }

  final added = rev.expectedHeadRevisionId == null;
  final details = <String>[];
  if (added) {
    details.add(
      [
        _money(rev.totalMinor),
        if (summary != null)
          '${summary.paidSentence.replaceFirst(RegExp(r' ₹[0-9,.]+$'), '')} · ${summary.splitWords}',
        if (rev.occurredOn != null) _day(rev.occurredOn),
      ].join(' · '),
    );
  } else {
    final changes = _changes(rev, previous, names, own);
    details.addAll(
      changes.length > 3
          ? [...changes.take(3), 'and ${changes.length - 3} more changes']
          : changes,
    );
    if (changes.isEmpty) {
      details.add('Now ${_money(rev.totalMinor)}');
    }
  }
  final impact = summary == null || summary.position == SharedYourPosition.notIn
      ? null
      : summary.yourSentence;
  return SharedActivityText(
    headline: added
        ? '$who added $title$waiting'
        : (previous != null && previous.title != rev.title
              ? '$who renamed “${previous.title}” to $title$waiting'
              : '$who edited $title$waiting'),
    details: details,
    impact: impact,
    kind: SharedActivityKind.expense,
  );
}

/// The differences between a version and the one it replaced, each on a line.
List<String> _changes(
  SharedStoredRevision now,
  SharedStoredRevision? before,
  Map<Object?, Object?> names,
  String? own,
) {
  if (before == null) return const [];
  final out = <String>[];
  if (before.title != now.title) {
    out.add('Name: “${before.title}” → “${now.title}”');
  }
  if (before.totalMinor != now.totalMinor) {
    out.add('Amount: ${_money(before.totalMinor)} → ${_money(now.totalMinor)}');
  }
  if (before.occurredOn != now.occurredOn) {
    out.add('Date: ${_day(before.occurredOn)} → ${_day(now.occurredOn)}');
  }
  final a = SharedExpenseSummary.from(before.snapshot, names, own);
  final b = SharedExpenseSummary.from(now.snapshot, names, own);
  if (a != null && b != null) {
    String payers(SharedExpenseSummary s) =>
        s.people.where((p) => p.paidMinor > 0).map((p) => p.name).join(' and ');
    final pa = payers(a), pb = payers(b);
    if (pa != pb) out.add('Paid by: $pa → $pb');
    if (a.splitEqually != b.splitEqually ||
        a.people.length != b.people.length) {
      out.add(
        'Split: ${a.splitWords} between ${a.people.length} → '
        '${b.splitWords} between ${b.people.length}',
      );
    }
    final youA = a.people.where((p) => p.isYou).firstOrNull;
    final youB = b.people.where((p) => p.isYou).firstOrNull;
    if ((youA?.shareMinor ?? 0) != (youB?.shareMinor ?? 0)) {
      out.add(
        'Your share: ${_money(youA?.shareMinor ?? 0)} → '
        '${_money(youB?.shareMinor ?? 0)}',
      );
    }
  }
  return out;
}

/// Payments, people and groups: who, what, how much, where.
SharedActivityText describeOtherEvent({
  required String kind,
  required String actor,
  required String? subject,
  required String? contextName,
  required bool direct,
  String? payer,
  String? receiver,
  int? amountMinor,
}) {
  final where = contextName == null || contextName.isEmpty
      ? ''
      : (direct ? ' with $contextName' : ' “$contextName”');
  switch (kind) {
    case 'settlement.reported' ||
        'settlement.confirmed' ||
        'settlement.rejected':
      final p = payer ?? 'Someone', r = receiver ?? 'someone';
      final line = p == 'You'
          ? 'You paid $r'
          : r == 'You'
          ? '$p paid you'
          : '$p paid $r';
      final money = amountMinor == null ? '' : ' ${_money(amountMinor)}';
      return SharedActivityText(
        headline: switch (kind) {
          'settlement.reported' => '$line$money',
          'settlement.confirmed' => '$line$money · confirmed',
          _ => '$line$money · not confirmed',
        },
        details: [
          switch (kind) {
            'settlement.reported' => 'Waiting for the other person to confirm',
            'settlement.confirmed' => 'Balances are updated',
            _ => 'Balances did not change',
          },
        ],
        kind: SharedActivityKind.payment,
      );
    case 'member.invited':
      return SharedActivityText(
        headline: '$actor invited ${subject ?? 'someone'}',
        details: [
          if (where.isNotEmpty) 'To join$where' else 'To join this split',
          'They can see the split once they join',
        ],
        kind: SharedActivityKind.member,
      );
    case 'membership.claimed':
      return SharedActivityText(
        headline: '${subject ?? 'Someone'} joined',
        details: [if (where.isNotEmpty) 'In$where'],
        kind: SharedActivityKind.member,
      );
    case 'membership.requested':
      return SharedActivityText(
        headline: '${subject ?? 'Someone'} asked to join',
        details: [if (where.isNotEmpty) 'To$where', 'Waiting for approval'],
        kind: SharedActivityKind.member,
      );
    case 'membership.responded':
      return SharedActivityText(
        headline: '${subject ?? 'Someone'} answered an invitation',
        details: [if (where.isNotEmpty) 'For$where'],
        kind: SharedActivityKind.member,
      );
    case 'membership.left':
      return SharedActivityText(
        headline: '${subject ?? 'Someone'} left',
        details: [if (where.isNotEmpty) 'From$where'],
        kind: SharedActivityKind.member,
      );
    case 'member.removed':
      return SharedActivityText(
        headline: '${subject ?? 'Someone'} was removed',
        details: [if (where.isNotEmpty) 'From$where'],
        kind: SharedActivityKind.member,
      );
    case 'member.renamed':
      return SharedActivityText(
        headline: '${subject ?? 'Someone'} was renamed',
        kind: SharedActivityKind.member,
      );
    case 'member.owner_changed':
      return SharedActivityText(
        headline: '${subject ?? 'Someone'} is now the owner',
        details: [if (where.isNotEmpty) 'Of$where'],
        kind: SharedActivityKind.member,
      );
    case 'context.created':
      return SharedActivityText(
        headline: direct
            ? '$actor started splitting${contextName == null ? '' : ' with $contextName'}'
            : '$actor created the group${contextName == null ? '' : ' “$contextName”'}',
        details: const ['Add expenses to start splitting'],
        kind: SharedActivityKind.group,
      );
  }
  return SharedActivityText(
    headline: 'A split was updated',
    details: [if (where.isNotEmpty) 'In$where'],
  );
}
