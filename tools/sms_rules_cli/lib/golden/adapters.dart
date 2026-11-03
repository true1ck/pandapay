import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart' show smsEngineVersion;

import 'engine_stage.dart';
import 'models.dart';

// =============================================================================
// The golden runner talks to the pipeline only through these interfaces.
//
// They use plain JSON maps (the shapes in docs/sms-pipeline-v2/contracts.md:
// Fact, Instrument, Event, LedgerEntry) so this package does not depend on the
// WP-01 contract types, which are not merged yet.
//
// A null stage in [GoldenAdapters] is reported as `not_available`, never as a
// failure. After WP-01 merges, the orchestrator wires `loadDefaultAdapters`:
//   interpreter  <- SmsInterpreter        (engine, from the --bundle file)
//   instruments  <- InstrumentResolver
//   linker       <- EventLinker
//   projector    <- LedgerProjector
//   categories   <- CategoryResolver
// Each is a ~10 line wrapper that converts to and from `toJson()`/`fromJson()`.
// =============================================================================

/// What the interpreter made of one message.
class InterpretedMessage {
  const InterpretedMessage({this.facts = const [], this.unknown = false});

  /// Facts as JSON (`factType`, `attrs`, `amounts`, `instrument`, ...). A
  /// message that is not financial yields only `info` facts, or none.
  final List<Map<String, dynamic>> facts;

  /// No rule matched: the message becomes a review item.
  final bool unknown;

  /// Not financial: nothing but `info` facts, and not unknown.
  bool get ignored =>
      !unknown && facts.every((f) => f['factType'] == 'info');
}

/// Stage 1: SmsInterpreter.
abstract interface class InterpreterStage {
  Future<InterpretedMessage> interpret(GoldenMessage message);
}

/// Result of resolving instruments for one scenario.
class InstrumentResolution {
  const InstrumentResolution({required this.instruments, required this.facts});

  /// Every instrument after resolution, including the known ones.
  final List<Map<String, dynamic>> instruments;

  /// The facts, each carrying its resolved `instrumentId` when it has one.
  final List<Map<String, dynamic>> facts;
}

/// Stage 2: InstrumentResolver.
abstract interface class InstrumentStage {
  Future<InstrumentResolution> resolve({
    required List<Map<String, dynamic>> facts,
    required List<Map<String, dynamic>> knownInstruments,
  });
}

/// Stage 3: EventLinker. Events are `{eventId, type, status, legs: [{factId, role}]}`.
abstract interface class LinkerStage {
  Future<List<Map<String, dynamic>>> link({
    required List<Map<String, dynamic>> facts,
    required List<Map<String, dynamic>> instruments,
  });
}

/// Totals over a window, as the screens would show them.
class LedgerTotals {
  const LedgerTotals({
    required this.spendMinor,
    required this.incomeMinor,
    required this.investmentMinor,
    required this.transactionCount,
    this.byCategory = const {},
  });

  final int spendMinor;
  final int incomeMinor;
  final int investmentMinor;
  final int transactionCount;
  final Map<String, int> byCategory;
}

/// Stage 4: LedgerProjector. Entries are LedgerEntry JSON.
abstract interface class ProjectorStage {
  Future<List<Map<String, dynamic>>> project({
    required List<Map<String, dynamic>> events,
    required List<Map<String, dynamic>> facts,
    required List<Map<String, dynamic>> instruments,
  });

  /// Totals over `[from, to]` (either may be null). Must be the ledger
  /// package's own totals function, never a sum written here.
  Future<LedgerTotals> totals({
    required List<Map<String, dynamic>> entries,
    DateTime? from,
    DateTime? to,
  });
}

/// Stage 5: CategoryResolver. Returns the entries with `category` set.
abstract interface class CategoryStage {
  Future<List<Map<String, dynamic>>> categorize({
    required List<Map<String, dynamic>> entries,
  });
}

/// The stages a run has. A null stage is `not_available`.
class GoldenAdapters {
  const GoldenAdapters({
    this.interpreter,
    this.instruments,
    this.linker,
    this.projector,
    this.categories,
    this.label = 'none',
  });

  final InterpreterStage? interpreter;
  final InstrumentStage? instruments;
  final LinkerStage? linker;
  final ProjectorStage? projector;
  final CategoryStage? categories;

  /// Names the implementation in the report.
  final String label;

  Map<String, String> get status => {
    'interpreter': interpreter == null ? 'not_available' : 'available',
    'instruments': instruments == null ? 'not_available' : 'available',
    'linker': linker == null ? 'not_available' : 'available',
    'projector': projector == null ? 'not_available' : 'available',
    'categories': categories == null ? 'not_available' : 'available',
  };
}

/// The adapters for a bundle. The interpreter stage is the real rule engine
/// (WP-02) running [bundlePath]; the other stages stay `not_available` until
/// their packages land and the orchestrator wires them here.
GoldenAdapters loadDefaultAdapters({String? bundlePath}) {
  if (bundlePath == null) {
    return const GoldenAdapters(label: 'unwired (no --bundle given)');
  }
  return GoldenAdapters(
    interpreter: EngineInterpreterStage.fromFile(bundlePath),
    label: 'rule engine $smsEngineVersion + $bundlePath',
  );
}

/// Replays interpretations that were computed elsewhere, such as the output of
/// today's phone or server parser. The file is
/// `{"engine": "<label>", "results": {"<caseId>#<messageIndex>": {"facts": [...], "unknown": false}}}`.
/// A message missing from `results` is treated as ignored.
class PrecomputedInterpreter implements InterpreterStage {
  PrecomputedInterpreter(this.label, this._results, this._keyOf);

  factory PrecomputedInterpreter.fromFile(String path, GoldenBundle bundle) {
    final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final results = (j['results'] as Map).cast<String, dynamic>();
    final keys = <GoldenMessage, String>{};
    for (final c in bundle.cases) {
      for (var i = 0; i < c.messages.length; i++) {
        keys[c.messages[i]] = '${c.id}#$i';
      }
    }
    return PrecomputedInterpreter(j['engine'] as String? ?? path, results, keys);
  }

  final String label;
  final Map<String, dynamic> _results;
  final Map<GoldenMessage, String> _keyOf;

  @override
  Future<InterpretedMessage> interpret(GoldenMessage message) async {
    final key = _keyOf[message];
    final r = key == null ? null : _results[key] as Map<String, dynamic>?;
    if (r == null) return const InterpretedMessage();
    return InterpretedMessage(
      facts: [for (final f in (r['facts'] as List? ?? const [])) (f as Map).cast<String, dynamic>()],
      unknown: r['unknown'] == true,
    );
  }
}
