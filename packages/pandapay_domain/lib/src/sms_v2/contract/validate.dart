import 'errors.dart';
import 'schema_validator.dart';

/// JSON-level validators for the v2 contract. They run the same schemas and the
/// same error codes as `api/src/sms_v2/contracts.js`; the conformance tests in
/// `test/sms_v2/contract_fixtures_test.dart` check both against every fixture.
///
/// Typed objects validate with their own `validate()`, which calls these on
/// `toJson()`.

const _day = Duration(days: 1);

ValidationResult validateFactJson(Object? json) => _run(
      'fact.schema.json',
      json,
      'fact.malformed',
      (d) => _factSemantics(d as Map<String, Object?>, ''),
    );

ValidationResult validateInstrumentJson(Object? json) =>
    _run('instrument.schema.json', json, 'instrument.malformed', null);

ValidationResult validateEventJson(Object? json) => _run(
      'event.schema.json',
      json,
      'event.malformed',
      (d) => _eventSemantics(d as Map<String, Object?>, ''),
    );

ValidationResult validateLedgerEntryJson(Object? json) => _run(
      'ledger_entry.schema.json',
      json,
      'ledger.malformed',
      (d) => _ledgerSemantics(d as Map<String, Object?>, ''),
    );

ValidationResult validateBundleJson(Object? json) => _run(
      'rule_bundle.schema.json',
      json,
      'bundle.malformed',
      (d) => _bundleSemantics(d as Map<String, Object?>, ''),
    );

/// Public API validation for the additive sync context and private upload.
ValidationResult validateSyncResponseJson(Object? json) =>
    _run('sync.response.schema.json', json, 'response.sync.malformed', null);

ValidationResult validateFactsBatchRequestJson(Object? json) =>
    _run('facts_batch.request.schema.json', json, 'request.facts_batch.malformed', null);

ValidationResult _run(
  String schema,
  Object? json,
  String fallback,
  List<ContractError> Function(Object? doc)? semantics,
) {
  var errors = SchemaValidator.instance.validate(schema, json, fallback: fallback);
  if (errors.isEmpty && semantics != null) errors = semantics(json);
  return ValidationResult(errors);
}

List<ContractError> _factSemantics(Map<String, Object?> f, String base) {
  final errs = <ContractError>[];
  final occurred = f['occurredAt'];
  if (occurred is String) {
    final o = DateTime.parse(occurred);
    final ob = DateTime.parse(f['observedAt'] as String);
    if (o.difference(ob) > _day) {
      errs.add(ContractError('fact.occurred_after_observed', '$base/occurredAt'));
    }
  }
  final roles = <String>{};
  final amounts = f['amounts'] as List;
  for (var i = 0; i < amounts.length; i++) {
    final role = (amounts[i] as Map)['role'] as String;
    if (!roles.add(role)) {
      errs.add(ContractError('fact.amount.duplicate_role', '$base/amounts/$i/role'));
    }
  }
  final evidence = f['evidence'] as List;
  for (var i = 0; i < evidence.length; i++) {
    final s = evidence[i] as Map;
    if ((s['end'] as num) < (s['start'] as num)) {
      errs.add(ContractError('fact.evidence.span_invalid', '$base/evidence/$i'));
    }
  }
  return errs;
}

List<ContractError> _eventSemantics(Map<String, Object?> e, String base) {
  final errs = <ContractError>[];
  final legs = e['legs'] as List;
  if (legs.isNotEmpty && (legs.first as Map)['factId'] != e['eventId']) {
    errs.add(ContractError('event.anchor_mismatch', '$base/eventId'));
  }
  final seen = <Object?>{};
  for (var i = 0; i < legs.length; i++) {
    final id = (legs[i] as Map)['factId'];
    if (!seen.add(id)) errs.add(ContractError('event.leg_duplicate', '$base/legs/$i/factId'));
  }
  return errs;
}

List<ContractError> _ledgerSemantics(Map<String, Object?> l, String base) {
  final errs = <ContractError>[];
  final to = l['to'] as Map;
  if (l['category'] != null && !to.containsKey('external')) {
    errs.add(ContractError('ledger.category_requires_external_to', '$base/category'));
  }
  if ((l['category'] == null) != (l['categorySource'] == null)) {
    errs.add(ContractError('ledger.category_source_mismatch', '$base/categorySource'));
  }
  return errs;
}

List<ContractError> _bundleSemantics(Map<String, Object?> b, String base) {
  final errs = <ContractError>[];
  final ids = <Object?>{};
  final rules = b['rules'] as List;
  for (var ri = 0; ri < rules.length; ri++) {
    final r = rules[ri] as Map;
    if (!ids.add(r['id'])) {
      errs.add(ContractError('bundle.rule.duplicate_id', '$base/rules/$ri/id'));
    }
    final emits = r['emit'] as List;
    for (var ei = 0; ei < emits.length; ei++) {
      final e = emits[ei] as Map;
      void check(String where, Object? ref) {
        if (ref is num && ref >= ei) {
          errs.add(ContractError('bundle.rule.same_as_invalid', '$base/rules/$ri/emit/$ei/$where'));
        }
      }

      final inst = e['instrument'];
      if (inst is Map) check('instrument', inst['sameAs']);
      final cp = e['counterparty'];
      if (cp is Map) check('counterparty', cp['sameAs']);
      final attrs = e['attrs'];
      if (attrs is Map) {
        attrs.forEach((k, v) {
          if (v is Map) check('attrs/$k', v['sameAs']);
        });
      }
    }
  }
  return errs;
}
