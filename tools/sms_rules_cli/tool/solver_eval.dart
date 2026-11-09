/// Scores the evidence solver (tier 2) against a labelled synthetic corpus.
///
///   dart run tool/solver_eval.dart PACK CORPUS.jsonl [--bundle BUNDLE] [--verbose]
///
/// With `--bundle`, also splits the results into the messages tier 1 did NOT
/// match, which is the real working set of tier 2.
///
/// Critical errors (must stay at zero before anything is switched on):
///   FALSE COUNT   solver accepts a movement that should not change totals, or
///                 accepts a counting movement with the wrong direction/amount.
///   SILENT MISS   solver accepts a non-money reading for a message that
///                 should have counted (the money would vanish without review).
///   BAD FACT      an accepted reading that cannot be written as a valid fact.
///   WRONG FACT    an accepted reading that writes a bill, mandate, receipt, upcoming
///                 debit, transfer or similar fact the message does not support.
/// Field checks (each is reported, none is critical): dates, minimum due,
/// mandate phase and frequency, evidence-only receipts.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_solver.dart';

const _readName = {
  SolverRead.debit: 'debit',
  SolverRead.credit: 'credit',
  SolverRead.cardPayment: 'card_payment',
  SolverRead.ownTransfer: 'transfer',
  SolverRead.walletTopup: 'wallet_topup',
  SolverRead.investment: 'investment',
  SolverRead.billDue: 'bill_due',
  SolverRead.billReceipt: 'receipt',
  SolverRead.scheduled: 'scheduled',
  SolverRead.mandate: 'mandate',
  SolverRead.redemption: 'redemption',
  SolverRead.holdRelease: 'hold_release',
  SolverRead.requestPending: 'request_pending',
  SolverRead.balance: 'info',
  SolverRead.failed: 'failed',
  SolverRead.promo: 'promo',
  SolverRead.info: 'info',
  SolverRead.unclear: 'unclear',
};

/// Labels that mean "nothing counted, nothing to act on".
String _norm(String r) => const {'balance': 'info', 'pending': 'info'}[r] ?? r;

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'usage: solver_eval PACK CORPUS.jsonl [--bundle BUNDLE] [--verbose]',
    );
    exit(64);
  }
  final verbose = args.contains('--verbose');
  final bi = args.indexOf('--bundle');
  final pack = SolverPack.fromJson(
    jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>,
  );
  final solver = EvidenceSolver(pack);
  RuleBundle? bundle;
  final engine = RuleEngine();
  if (bi >= 0) {
    bundle = RuleBundle.fromJson(
      jsonDecode(File(args[bi + 1]).readAsStringSync()) as Map<String, dynamic>,
    );
  }
  final rows = File(args[1])
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .map((l) => jsonDecode(l) as Map<String, dynamic>)
      .toList();

  final all = _Stats('all messages');
  final t2 = _Stats('messages tier 1 did not match');
  final sw = Stopwatch()..start();
  for (final row in rows) {
    final expect = row['expect'] as Map<String, dynamic>;
    final observed = DateTime.utc(2026, 11, 9, 6);
    final d = solver.solve(row['body'] as String, observedAt: observed);
    var tier1Matched = false;
    if (bundle != null) {
      final out = engine.interpretDetailed(
        SmsMessage(
          sender: row['sender'] as String,
          body: row['body'] as String,
          observedAt: observed,
          sourceKey: row['id'] as String,
        ),
        bundle,
        appVersion: '2.0.0',
      );
      // Ask the engine WITHOUT its solver for tier 1 only: a message that the
      // solver resolved is not a tier 1 match.
      tier1Matched =
          out.result.outcome != InterpretOutcome.unknown &&
          !(out.winnerId ?? '').startsWith('SOLVER-');
    }
    final facts = SolverFacts.build(
      d,
      sourceKey: row['id'] as String,
      observedAt: observed,
      issuerSlug: null,
      packVersion: pack.version,
      bundleVersion: 0,
      engineVersion: smsEngineVersion,
      appVersion: '2.0.0',
    );
    final line = all.add(row, expect, d, facts);
    if (bundle != null && !tier1Matched) t2.add(row, expect, d, facts);
    if (verbose) stdout.writeln(line);
  }
  sw.stop();
  all.print();
  if (bundle != null) t2.print();
  stdout.writeln(
    '\nsolver time: ${sw.elapsedMicroseconds / rows.length} us per message (includes JIT warm-up)',
  );
}

class _Stats {
  _Stats(this.name);
  final String name;
  int n = 0;
  int readOk = 0;
  int accepted = 0;
  int candidate = 0;
  int rightCount = 0;
  int amountOk = 0;
  int maskWanted = 0, maskOk = 0;
  int partyWanted = 0, partyOk = 0;
  int fieldChecks = 0, fieldOk = 0;
  final falseCounts = <String>[];
  final silentMisses = <String>[];
  final badFacts = <String>[];
  final wrongFacts = <String>[];
  final fieldMisses = <String>[];
  final reviewed = <String>[];
  final wrongNonMoney = <String>[];

  String add(
    Map<String, dynamic> row,
    Map<String, dynamic> expect,
    SolverDecision d,
    SolverFactResult? facts,
  ) {
    n++;
    final wantRead = _norm(expect['read'] as String);
    final wantCounts = expect['counts'] == true;
    final gotRead = _norm(_readName[d.read]!);
    final id = row['id'];
    final readMatches = gotRead == wantRead;
    if (d.accepted) {
      accepted++;
      if (readMatches) readOk++;
      if (facts == null && d.read != SolverRead.unclear) {
        badFacts.add(
          '$id accepted ${d.read.name} but no valid fact: ${row['body']}',
        );
      }
    } else {
      candidate++;
      reviewed.add(
        '$id want=$wantRead got=${_readName[d.read]} (${d.reasons.take(2).join('; ')})',
      );
    }
    var flag = 'ok';
    if (d.countsInTotals) {
      final dirOk =
          (d.read == SolverRead.debit && expect['read'] == 'debit') ||
          (d.read == SolverRead.credit && expect['read'] == 'credit');
      final amtOk = d.minor == expect['amount'];
      if (!wantCounts || !dirOk || !amtOk) {
        flag = 'FALSE COUNT';
        falseCounts.add(
          '$id want=$wantRead/${expect['amount']} got=${d.read.name}/${d.minor}  ${row['body']}',
        );
      } else {
        rightCount++;
        amountOk++;
        final wm = expect['mask'];
        if (wm != null) {
          maskWanted++;
          if (d.mask == wm) maskOk++;
        }
        final wp = expect['party'];
        if (wp != null) {
          partyWanted++;
          if ((d.party ?? '').toLowerCase().contains(wp as String)) partyOk++;
        }
      }
    } else if (d.accepted && wantCounts && !readMatches) {
      flag = 'SILENT MISS';
      silentMisses.add('$id want=$wantRead got=${d.read.name}  ${row['body']}');
    } else if (d.accepted &&
        !readMatches &&
        d.read != SolverRead.info &&
        d.read != SolverRead.promo) {
      // A fact the downstream screens would show (bill, mandate, receipt, upcoming
      // debit, transfer ...) that the message does not support.
      flag = 'WRONG FACT';
      wrongFacts.add('$id want=$wantRead got=${d.read.name}  ${row['body']}');
    } else if (d.accepted && !readMatches) {
      flag = 'wrong read';
      wrongNonMoney.add(
        '$id want=$wantRead got=${d.read.name}  ${row['body']}',
      );
    }

    // Field checks for the new scenarios, only where the label states them.
    if (d.accepted && readMatches) {
      void check(String field, Object? want, Object? got) {
        if (want == null) return;
        fieldChecks++;
        if ('$want' == '$got') {
          fieldOk++;
        } else {
          fieldMisses.add('$id $field want=$want got=$got');
          if (flag == 'ok') flag = 'field';
        }
      }

      check('due', expect['due'], d.dueDate?.iso);
      check('statement', expect['statement'], d.statementDate?.iso);
      check('min', expect['min'], d.dueMinorMinimum);
      check(
        'total',
        expect['total'],
        d.read == SolverRead.billDue ? d.minor : null,
      );
      check('phase', expect['phase'], d.mandatePhase);
      check('freq', expect['freq'], d.frequency);
      check('evidenceOnly', expect['evidenceOnly'], d.evidenceOnly);
      check('upcoming', expect['upcoming'], d.scheduledDate?.iso);
      check('recurring', expect['recurring'], d.recurring);
    }
    return '$id ${wantRead.padRight(12)} ${d.read.name.padRight(12)} ${d.verdict.name.padRight(9)} ${d.score.toStringAsFixed(2)} $flag';
  }

  void print() {
    final counting = rightCount + falseCounts.length;
    stdout.writeln('\n== $name (n=$n) ==');
    stdout.writeln(
      'accepted $accepted   sent to review $candidate   exact read among accepted: $readOk/$accepted',
    );
    stdout.writeln(
      'counted movements: $counting   right: $rightCount   FALSE COUNTS: ${falseCounts.length}   SILENT MISSES: ${silentMisses.length}   BAD FACTS: ${badFacts.length}   WRONG FACTS: ${wrongFacts.length}',
    );
    if (rightCount > 0) {
      stdout.writeln(
        'on right counts: amount $amountOk/$rightCount   mask $maskOk/$maskWanted   counterparty $partyOk/$partyWanted',
      );
    }
    if (fieldChecks > 0)
      stdout.writeln(
        'labelled fields (dates, minimum due, phase, frequency, evidence-only): $fieldOk/$fieldChecks',
      );
    for (final s in falseCounts) {
      stdout.writeln('  FALSE COUNT  $s');
    }
    for (final s in silentMisses) {
      stdout.writeln('  SILENT MISS  $s');
    }
    for (final s in badFacts) {
      stdout.writeln('  BAD FACT  $s');
    }
    for (final s in wrongFacts) {
      stdout.writeln('  WRONG FACT  $s');
    }
    for (final s in wrongNonMoney) {
      stdout.writeln('  wrong read  $s');
    }
    for (final s in fieldMisses) {
      stdout.writeln('  field  $s');
    }
    stdout.writeln('  to review (${reviewed.length}):');
    for (final s in reviewed) {
      stdout.writeln('    $s');
    }
  }
}
