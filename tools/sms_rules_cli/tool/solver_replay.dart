library;
/// Replays a PRIVATE message export through tier 1 (rules) and tier 2 (solver)
/// and reports COUNTS and REDACTED LAYOUTS only. It never prints a message body,
/// sender, amount, account digit or name.
///
///   dart run tool/solver_replay.dart BUNDLE SMS.jsonl [--layouts N]
///
/// SMS.jsonl rows: {sender, body, observedAt, id}. The file must live outside
/// the repository (the tool refuses a path inside it), like the private
/// corpus described in README.md. The intake gate lives in the app, so it is
/// approximated here: numeric senders (people, telemarketing) and messages
/// with security wording are skipped and counted.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_template.dart';

final _security = RegExp(r'\b(?:otp|one[\s-]?time\s+password|cvv|pin)\b', caseSensitive: false);
final _numericSender = RegExp(r'^\+?\d{8,}$');

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: solver_replay BUNDLE SMS.jsonl [--layouts N]');
    exit(64);
  }
  final repo = Directory('../..').absolute.resolveSymbolicLinksSync().replaceAll('\\', '/').toLowerCase();
  final input = File(args[1]).absolute.resolveSymbolicLinksSync().replaceAll('\\', '/').toLowerCase();
  if (input.startsWith(repo)) {
    stderr.writeln('refusing: the message export must live outside the repository');
    exit(65);
  }
  final ui = args.indexOf('--unresolved');
  final unresolvedLayouts = ui >= 0 ? int.parse(args[ui + 1]) : 0;
  final unresolved = <String, int>{};
  final moneyWord = RegExp(r'(?:rs\.?|inr|₹)\s*[\d,]+', caseSensitive: false);
  final li = args.indexOf('--layouts');
  final layoutsPerGroup = li >= 0 ? int.parse(args[li + 1]) : 0;

  final json = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final withPack = RuleBundle.fromJson(json);
  final bare = RuleBundle.fromJson(Map<String, dynamic>.of(json)..remove('solverPack'));
  final engine = RuleEngine();

  var total = 0, skippedNumeric = 0, skippedSecurity = 0, considered = 0;
  var ruleMatched = 0, ruleIgnored = 0, ruleMatchedChanged = 0;
  var refinedGeneric = 0;
  final refinedLayouts = <String>[];
  var tier1Unknown = 0, solverAccepted = 0, stillUnknown = 0;
  final bySolverRule = <String, int>{};
  final unknownBySender = <String, int>{};
  final layouts = <String, Map<String, int>>{};
  var countedDebitMinor = 0, countedCreditMinor = 0, countedDebits = 0, countedCredits = 0;
  final sw = Stopwatch()..start();

  for (final line in File(args[1]).readAsLinesSync().where((l) => l.trim().isNotEmpty)) {
    final row = jsonDecode(line) as Map<String, dynamic>;
    total++;
    final sender = row['sender'] as String;
    final body = row['body'] as String;
    if (_numericSender.hasMatch(sender.replaceAll(RegExp(r'[\s-]'), ''))) {
      skippedNumeric++;
      continue;
    }
    if (_security.hasMatch(body)) {
      skippedSecurity++;
      continue;
    }
    considered++;
    final at = DateTime.parse(row['observedAt'] as String).toUtc();
    final msg = SmsMessage(sender: sender, body: body, observedAt: at, sourceKey: '${row['id']}');
    final a = engine.interpretDetailed(msg, bare, appVersion: '2.0.0');
    final b = engine.interpretDetailed(msg, withPack, appVersion: '2.0.0');
    if (a.result.outcome == InterpretOutcome.matched) ruleMatched++;
    if (a.result.outcome == InterpretOutcome.ignored) ruleIgnored++;
    if (a.result.outcome != InterpretOutcome.unknown) {
      final same = jsonEncode([for (final f in a.result.facts) f.toJson()]) ==
              jsonEncode([for (final f in b.result.facts) f.toJson()]) &&
          a.winnerId == b.winnerId;
      if (!same) {
        // The one permitted change: a generic catch-all rule enriched by the solver.
        if ((a.winnerId ?? '').startsWith('GEN-') &&
            b.winnerId == 'SOLVER-REFINED') {
          refinedGeneric++;
          final red = redactSms(
            sender: sender,
            body: body,
            observedAt: at,
            options: SmsRedactionOptions(
              salt: 'replay-${DateTime.now().microsecondsSinceEpoch}',
              merchantCatalogue: {},
            ),
          );
          refinedLayouts.add(smsSkeleton(red.body));
        } else {
          ruleMatchedChanged++;
        }
      }
      continue;
    }
    tier1Unknown++;
    final id = b.winnerId ?? '';
    if (id.startsWith('SOLVER-')) {
      solverAccepted++;
      bySolverRule[id] = (bySolverRule[id] ?? 0) + 1;
      for (final f in b.result.facts) {
        if (f is MovementFact && f.evidenceOnly != true) {
          final minor = f.amounts.first.minor;
          if (f.direction == Direction.debit && f.purpose != MovementPurpose.cardPayment) {
            countedDebits++;
            countedDebitMinor += minor;
          } else if (f.direction == Direction.credit && f.purpose != MovementPurpose.cardPayment) {
            countedCredits++;
            countedCreditMinor += minor;
          }
          break;
        }
      }
      if (layoutsPerGroup > 0) {
        final red = redactSms(
          sender: sender,
          body: body,
          observedAt: at,
          options: SmsRedactionOptions(salt: 'replay-${DateTime.now().microsecondsSinceEpoch}', merchantCatalogue: {}),
        );
        final key = smsSkeleton(red.body);
        final m = layouts.putIfAbsent(id, () => {});
        m[key] = (m[key] ?? 0) + 1;
      }
    } else {
      stillUnknown++;
      if (unresolvedLayouts > 0) {
        final red = redactSms(
          sender: sender,
          body: body,
          observedAt: at,
          options: SmsRedactionOptions(salt: 'replay-${DateTime.now().microsecondsSinceEpoch}', merchantCatalogue: {}),
        );
        final key = (moneyWord.hasMatch(body) ? '[amount] ' : '[no amount] ') + smsSkeleton(red.body);
        unresolved[key] = (unresolved[key] ?? 0) + 1;
      }
      final brand = engine.compiled(withPack).normalize(sender).brand;
      unknownBySender[brand] = (unknownBySender[brand] ?? 0) + 1;
    }
  }
  sw.stop();

  stdout.writeln('messages in export: $total');
  stdout.writeln('  skipped like the intake gate: numeric senders $skippedNumeric, security wording $skippedSecurity');
  stdout.writeln('  considered: $considered   (replay took ${sw.elapsedMilliseconds} ms, both engines)');
  stdout.writeln('tier 1 (existing rules): matched $ruleMatched, ignored $ruleIgnored, unknown $tier1Unknown');
  stdout.writeln('  rule-matched messages whose result changed with the solver present: $ruleMatchedChanged   (must be 0)');
  stdout.writeln('  generic catch-all readings enriched by the solver: $refinedGeneric');
  for (final l in refinedLayouts) {
    stdout.writeln('    enriched layout: $l');
  }
  stdout.writeln('of the $tier1Unknown unknown: solver accepted $solverAccepted, still unknown (review / Gemini) $stillUnknown');
  for (final e in (bySolverRule.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))) {
    stdout.writeln('  ${e.key.padRight(22)} ${e.value}');
  }
  stdout.writeln('money the solver would COUNT (excluding card-bill payments): '
      '$countedDebits debits (${(countedDebitMinor / 100).toStringAsFixed(0)} rupees), '
      '$countedCredits credits (${(countedCreditMinor / 100).toStringAsFixed(0)} rupees)');
  final top = (unknownBySender.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(8);
  stdout.writeln('still-unknown by sender brand (top 8): ${top.map((e) => "${e.key}=${e.value}").join("  ")}');
  if (unresolvedLayouts > 0) {
    stdout.writeln('\n## STILL UNRESOLVED (redacted layouts, most frequent first)');
    final sorted = unresolved.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted.take(unresolvedLayouts)) {
      stdout.writeln('  x${e.value}  ${e.key.length > 230 ? e.key.substring(0, 230) : e.key}');
    }
  }
  if (layoutsPerGroup > 0) {
    for (final g in layouts.entries) {
      stdout.writeln('\n## ${g.key}: redacted layouts');
      final sorted = g.value.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sorted.take(layoutsPerGroup)) {
        stdout.writeln('  x${e.value}  ${e.key.length > 220 ? e.key.substring(0, 220) : e.key}');
      }
    }
  }
}
