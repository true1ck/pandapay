import 'package:pandapay_domain/sms_v2.dart'
    show linkForGolden, resolveInstrumentsForGolden, smsEngineVersion;

import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:pandapay_domain/sms_v2_ledger.dart' as ledger;

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
  bool get ignored => !unknown && facts.every((f) => f['factType'] == 'info');
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
GoldenAdapters adaptersForBundle(v2.RuleBundle bundle, {String? label}) {
  final interpreter = EngineInterpreterStage(bundle);
  final ledgerStage = _LedgerStage(interpreter);
  return GoldenAdapters(
    interpreter: interpreter,
    instruments: _RegistryInstrumentStage(interpreter),
    linker: _RuleLinkerStage(interpreter),
    projector: ledgerStage,
    categories: ledgerStage,
    label: label ?? 'rule engine $smsEngineVersion',
  );
}

/// Stage 2: WP-04's instrument registry over the bundle's senders.
class _RegistryInstrumentStage implements InstrumentStage {
  _RegistryInstrumentStage(this.interpreter);
  final EngineInterpreterStage interpreter;

  @override
  Future<InstrumentResolution> resolve({
    required List<Map<String, dynamic>> facts,
    required List<Map<String, dynamic>> knownInstruments,
  }) async {
    final r = resolveInstrumentsForGolden(
      facts: facts,
      knownInstruments: knownInstruments,
      bundle: interpreter.bundle,
    );
    return InstrumentResolution(
      instruments: [for (final i in r.instruments) i.cast<String, dynamic>()],
      facts: [for (final f in r.facts) f.cast<String, dynamic>()],
    );
  }
}

/// Stage 3: WP-05's rule-driven linker with the bundle's link rules.
class _RuleLinkerStage implements LinkerStage {
  _RuleLinkerStage(this.interpreter);
  final EngineInterpreterStage interpreter;

  @override
  Future<List<Map<String, dynamic>>> link({
    required List<Map<String, dynamic>> facts,
    required List<Map<String, dynamic>> instruments,
  }) async => [
    for (final e in linkForGolden(
      facts: facts,
      instruments: instruments,
      bundle: interpreter.bundle,
    ))
      e.cast<String, dynamic>(),
  ];
}

/// Replays interpretations that were computed elsewhere, such as the output of
/// today's phone or server parser. The file is
/// `{"engine": "<label>", "results": {"<caseId>#<messageIndex>": {"facts": [...], "unknown": false}}}`.
/// A message missing from `results` is treated as ignored.
class PrecomputedInterpreter implements InterpreterStage {
  PrecomputedInterpreter(this.label, this._results, this._keyOf);

  final String label;
  final Map<String, dynamic> _results;
  final Map<GoldenMessage, String> _keyOf;

  @override
  Future<InterpretedMessage> interpret(GoldenMessage message) async {
    final key = _keyOf[message];
    final r = key == null ? null : _results[key] as Map<String, dynamic>?;
    if (r == null) return const InterpretedMessage();
    return InterpretedMessage(
      facts: [
        for (final f in (r['facts'] as List? ?? const []))
          (f as Map).cast<String, dynamic>(),
      ],
      unknown: r['unknown'] == true,
    );
  }
}

/// Project and categorise in one pass so refunds can inherit purchase context.
class _LedgerStage implements ProjectorStage, CategoryStage {
  _LedgerStage(this.interpreter);
  final EngineInterpreterStage interpreter;
  ledger.LedgerSnapshot? _snapshot;

  @override
  Future<List<Map<String, dynamic>>> project({
    required List<Map<String, dynamic>> events,
    required List<Map<String, dynamic>> facts,
    required List<Map<String, dynamic>> instruments,
  }) async {
    final ids = <String, String>{};
    final parsed = <String, v2.Fact>{};
    for (final f in facts) {
      final copy = Map<String, Object?>.from(f);
      final id = copy.remove('instrumentId') as String?;
      final fact = v2.Fact.fromJson(copy);
      parsed[fact.factId] = fact;
      if (id != null) ids[fact.factId] = id;
    }
    _snapshot = ledger.LedgerSnapshot.project(
      events: events.map(v2.Event.fromJson),
      factsById: parsed,
      instrumentsById: {
        for (final i in instruments)
          i['instrumentId'] as String: v2.Instrument.fromJson(i),
      },
      bundle: interpreter.bundle,
      instrumentIdByFactId: ids,
    );
    return [for (final e in _snapshot!.entries) e.toJson()];
  }

  @override
  Future<List<Map<String, dynamic>>> categorize({
    required List<Map<String, dynamic>> entries,
  }) async => entries;

  @override
  Future<LedgerTotals> totals({
    required List<Map<String, dynamic>> entries,
    DateTime? from,
    DateTime? to,
  }) async {
    final snapshot = _snapshot!;
    final t =
        ledger.DefaultLedgerProjector(
          categoryByEvent: snapshot.categoryByEvent,
        ).totals(
          entries.map(v2.LedgerEntry.fromJson),
          snapshot.events,
          from ?? DateTime.utc(1900),
          to ?? DateTime.utc(9999),
        );
    return LedgerTotals(
      spendMinor: t.spendMinor,
      incomeMinor: t.incomeMinor,
      investmentMinor: t.investmentMinor,
      transactionCount: t.transactionCount,
      byCategory: t.byCategory,
    );
  }
}
