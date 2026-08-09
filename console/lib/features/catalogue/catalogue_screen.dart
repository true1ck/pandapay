import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-1.1.1 catalogue browse: card list with status + AD-1.1.4's
/// draft->in_review->published->archived state machine (publish sets
/// verified_at server-side — the human verification pass).
///
/// AD-1.1.2 tabbed rule-family editor: each card expands into 8 tabs —
/// Rewards, Caps, Milestones, Fees, Benefits, Forex & Fuel, Cycle,
/// Redemption — covering every rule table v_admin_card_catalogue_export
/// returns (0022's migration). Still missing vs the full plan:
/// diff-before-save confirmation, impact preview, bulk YAML import/export
/// — AD-1.2/AD-1.3 territory, a separate (larger) piece of work from
/// "can an admin actually edit every rule family", which this covers.
class CatalogueScreen extends ConsumerWidget {
  const CatalogueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(adminCardsProvider);

    return cards.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load catalogue: $err')),
      data: (cardList) {
        if (cardList.isEmpty) {
          return const Center(child: Text('No cards found.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: cardList.length,
          itemBuilder: (context, index) => _CardEditorTile(cardList[index]),
        );
      },
    );
  }
}

const Map<String, List<String>> _cardStatusTransitions = {
  'draft': ['in_review'],
  'in_review': ['draft', 'published'],
  'published': ['archived'],
  'archived': [],
};

class _CardEditorTile extends ConsumerStatefulWidget {
  final Map<String, dynamic> card;
  const _CardEditorTile(this.card);

  @override
  ConsumerState<_CardEditorTile> createState() => _CardEditorTileState();
}

class _CardEditorTileState extends ConsumerState<_CardEditorTile> {
  bool _changingStatus = false;
  bool _expanded = false;
  String? _statusError;

  Future<void> _changeStatus(String nextStatus) async {
    setState(() {
      _changingStatus = true;
      _statusError = null;
    });
    try {
      final api = ref.read(adminApiProvider)!;
      await api.changeCardStatus(
        widget.card['id'] as String,
        nextStatus,
        reason: nextStatus == 'published' ? 'Console: human-verified and published' : 'Console status change',
      );
      ref.invalidate(adminCardsProvider);
    } catch (e) {
      setState(() => _statusError = e.toString());
    } finally {
      if (mounted) setState(() => _changingStatus = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final status = card['status'] as String;
    final nextOptions = _cardStatusTransitions[status] ?? const <String>[];
    final verifiedAt = card['verified_at'] as String?;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Text('${card['name']} — $status'),
        subtitle: Text('${card['network']} · data_version ${card['data_version']}'
            '${card['is_upi_linkable'] == true ? ' · UPI-linkable' : ''}'
            '${verifiedAt != null ? ' · verified $verifiedAt' : ' · not verified'}'),
        onExpansionChanged: (v) => setState(() => _expanded = v),
        children: [
          if (nextOptions.isNotEmpty || _statusError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final next in nextOptions)
                        OutlinedButton(
                          onPressed: _changingStatus ? null : () => _changeStatus(next),
                          child: Text(_changingStatus
                              ? '...'
                              : next == 'published'
                                  ? 'Verify & publish'
                                  : 'Move to $next'),
                        ),
                    ],
                  ),
                  if (_statusError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(_statusError!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                ],
              ),
            ),
          if (_expanded) SizedBox(height: 520, child: _CardRuleFamilyTabs(card: card)),
        ],
      ),
    );
  }
}

/// The 8-tab rule-family editor for one card. Rewards keeps the original
/// rate-only editor (already shipped); the other 7 tabs are driven by the
/// same declarative field-spec shape the backend's admin_rule_families.js
/// factory uses, so adding/removing a field here and there stays a
/// one-line change instead of touching 7 near-identical widgets.
class _CardRuleFamilyTabs extends StatelessWidget {
  final Map<String, dynamic> card;
  const _CardRuleFamilyTabs({required this.card});

  @override
  Widget build(BuildContext context) {
    final cardId = card['id'] as String;
    return DefaultTabController(
      length: 8,
      child: Column(
        children: [
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Rewards'),
              Tab(text: 'Caps'),
              Tab(text: 'Milestones'),
              Tab(text: 'Fees'),
              Tab(text: 'Benefits'),
              Tab(text: 'Forex & Fuel'),
              Tab(text: 'Cycle'),
              Tab(text: 'Redemption'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _RewardsTab(cardId: cardId, rewardRules: (card['reward_rules'] as List).cast<Map<String, dynamic>>()),
                _RuleFamilyListTab(
                  cardId: cardId,
                  urlSegment: 'cap-rules',
                  auditEntity: 'cap_rule',
                  rows: (card['cap_rules'] as List? ?? const []).cast<Map<String, dynamic>>(),
                  fields: _capRuleFields,
                ),
                _RuleFamilyListTab(
                  cardId: cardId,
                  urlSegment: 'milestone-rules',
                  auditEntity: 'milestone_rule',
                  rows: (card['milestone_rules'] as List? ?? const []).cast<Map<String, dynamic>>(),
                  fields: _milestoneRuleFields,
                ),
                _RuleFamilyListTab(
                  cardId: cardId,
                  urlSegment: 'fee-waiver-rules',
                  auditEntity: 'fee_waiver_rule',
                  rows: (card['fee_waiver_rules'] as List? ?? const []).cast<Map<String, dynamic>>(),
                  fields: _feeWaiverRuleFields,
                ),
                _RuleFamilyListTab(
                  cardId: cardId,
                  urlSegment: 'card-benefits',
                  auditEntity: 'card_benefit',
                  rows: (card['benefits'] as List? ?? const []).cast<Map<String, dynamic>>(),
                  fields: _cardBenefitFields,
                ),
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Text('Forex', style: Theme.of(context).textTheme.labelLarge),
                    _RuleFamilySingleEditor(
                      cardId: cardId,
                      urlSegment: 'forex-rules',
                      auditEntity: 'forex_rule',
                      row: card['forex'] as Map<String, dynamic>?,
                      fields: _forexRuleFields,
                    ),
                    const SizedBox(height: 20),
                    Text('Fuel surcharge', style: Theme.of(context).textTheme.labelLarge),
                    _RuleFamilySingleEditor(
                      cardId: cardId,
                      urlSegment: 'fuel-surcharge-rules',
                      auditEntity: 'fuel_surcharge_rule',
                      row: card['fuel'] as Map<String, dynamic>?,
                      fields: _fuelSurchargeRuleFields,
                    ),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _RuleFamilySingleEditor(
                      cardId: cardId,
                      urlSegment: 'billing-cycle-rules',
                      auditEntity: 'billing_cycle_rule',
                      row: card['billing_cycle'] as Map<String, dynamic>?,
                      fields: _billingCycleRuleFields,
                    ),
                  ],
                ),
                _RuleFamilyListTab(
                  cardId: cardId,
                  urlSegment: 'redemption-options',
                  auditEntity: 'redemption_option',
                  rows: (card['redemption_options'] as List? ?? const []).cast<Map<String, dynamic>>(),
                  fields: _redemptionOptionFields,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Declarative field specs, one per rule family --------------------------
// `writeKey` is the camelCase JSON key the backend's typed writer validates
// (admin_rule_families.js field specs); `readKey` is the snake_case column
// name as it comes back from v_admin_card_catalogue_export. They differ for
// every multi-word field because the JS request body and the Postgres row
// use different casing conventions, same as everywhere else in this app.

enum _FieldType { text, number, integer, boolean, dropdown }

class _RuleField {
  final String writeKey;
  final String readKey;
  final String label;
  final _FieldType type;
  final List<String>? options;
  final bool required;
  const _RuleField({
    required this.writeKey,
    required this.readKey,
    required this.label,
    required this.type,
    this.options,
    this.required = false,
  });
}

const _rewardUnits = [
  'cashback_percent', 'points_per_100', 'points_per_150', 'points_per_200',
  'miles_per_100', 'flat_points', 'discount_percent',
];
const _capPeriods = ['statement_cycle', 'calendar_month', 'quarter', 'half_year', 'annual', 'lifetime'];
const _capMeasures = ['reward_value', 'spend_amount', 'txn_count'];
const _benefitKinds = [
  'lounge_domestic', 'lounge_international', 'golf', 'concierge', 'insurance_travel',
  'insurance_purchase', 'extended_warranty', 'dining_program', 'movie', 'fuel_surcharge',
  'roadside_assistance', 'other',
];
const _milestoneAnchors = ['card_anniversary', 'calendar_year', 'fiscal_year', 'statement_cycle'];

const _capRuleFields = [
  _RuleField(writeKey: 'label', readKey: 'label', label: 'Label', type: _FieldType.text, required: true),
  _RuleField(writeKey: 'measure', readKey: 'measure', label: 'Measure', type: _FieldType.dropdown, options: _capMeasures, required: true),
  _RuleField(writeKey: 'period', readKey: 'period', label: 'Period', type: _FieldType.dropdown, options: _capPeriods, required: true),
  _RuleField(writeKey: 'capValue', readKey: 'cap_value', label: 'Cap value', type: _FieldType.number, required: true),
  _RuleField(writeKey: 'postCapUnit', readKey: 'post_cap_unit', label: 'Post-cap unit', type: _FieldType.dropdown, options: _rewardUnits),
  _RuleField(writeKey: 'postCapRate', readKey: 'post_cap_rate', label: 'Post-cap rate', type: _FieldType.number),
  _RuleField(writeKey: 'resetsOnDay', readKey: 'resets_on_day', label: 'Resets on day', type: _FieldType.integer),
];

const _milestoneRuleFields = [
  _RuleField(writeKey: 'label', readKey: 'label', label: 'Label', type: _FieldType.text, required: true),
  _RuleField(writeKey: 'period', readKey: 'period', label: 'Period', type: _FieldType.dropdown, options: _capPeriods),
  _RuleField(writeKey: 'thresholdSpendInr', readKey: 'threshold_spend_inr', label: 'Threshold spend (INR)', type: _FieldType.number, required: true),
  _RuleField(writeKey: 'rewardDescription', readKey: 'reward_description', label: 'Reward description', type: _FieldType.text, required: true),
  _RuleField(writeKey: 'rewardValueInr', readKey: 'reward_value_inr', label: 'Reward value (INR)', type: _FieldType.number, required: true),
  _RuleField(writeKey: 'isRepeatable', readKey: 'is_repeatable', label: 'Repeatable', type: _FieldType.boolean),
  _RuleField(writeKey: 'maxRepeats', readKey: 'max_repeats', label: 'Max repeats', type: _FieldType.integer),
  _RuleField(writeKey: 'anchor', readKey: 'anchor', label: 'Anchor', type: _FieldType.dropdown, options: _milestoneAnchors),
];

const _feeWaiverRuleFields = [
  _RuleField(writeKey: 'thresholdSpendInr', readKey: 'threshold_spend_inr', label: 'Threshold spend (INR)', type: _FieldType.number, required: true),
  _RuleField(writeKey: 'period', readKey: 'period', label: 'Period', type: _FieldType.dropdown, options: _capPeriods),
  _RuleField(writeKey: 'waivesFeeInr', readKey: 'waives_fee_inr', label: 'Waives fee (INR)', type: _FieldType.number, required: true),
  _RuleField(writeKey: 'notes', readKey: 'notes', label: 'Notes', type: _FieldType.text),
];

const _cardBenefitFields = [
  _RuleField(writeKey: 'kind', readKey: 'kind', label: 'Kind', type: _FieldType.dropdown, options: _benefitKinds, required: true),
  _RuleField(writeKey: 'label', readKey: 'label', label: 'Label', type: _FieldType.text, required: true),
  _RuleField(writeKey: 'description', readKey: 'description', label: 'Description', type: _FieldType.text),
  _RuleField(writeKey: 'quotaCount', readKey: 'quota_count', label: 'Quota count', type: _FieldType.integer),
  _RuleField(writeKey: 'quotaPeriod', readKey: 'quota_period', label: 'Quota period', type: _FieldType.dropdown, options: _capPeriods),
  _RuleField(writeKey: 'networkProgram', readKey: 'network_program', label: 'Network program', type: _FieldType.text),
  _RuleField(writeKey: 'valueEstimateInr', readKey: 'value_estimate_inr', label: 'Value estimate (INR)', type: _FieldType.number),
];

const _redemptionOptionFields = [
  _RuleField(writeKey: 'programName', readKey: 'program_name', label: 'Program name', type: _FieldType.text, required: true),
  _RuleField(writeKey: 'method', readKey: 'method', label: 'Method', type: _FieldType.text, required: true),
  _RuleField(writeKey: 'valuePerPointInr', readKey: 'value_per_point_inr', label: 'Value per point (INR)', type: _FieldType.number, required: true),
  _RuleField(writeKey: 'minPoints', readKey: 'min_points', label: 'Min points', type: _FieldType.integer),
  _RuleField(writeKey: 'notes', readKey: 'notes', label: 'Notes', type: _FieldType.text),
];

const _forexRuleFields = [
  _RuleField(writeKey: 'markupPercent', readKey: 'markup_percent', label: 'Markup %', type: _FieldType.number, required: true),
  _RuleField(writeKey: 'gstOnMarkup', readKey: 'gst_on_markup', label: 'GST on markup', type: _FieldType.boolean),
  _RuleField(writeKey: 'waiverNotes', readKey: 'waiver_notes', label: 'Waiver notes', type: _FieldType.text),
];

const _fuelSurchargeRuleFields = [
  _RuleField(writeKey: 'surchargePercent', readKey: 'surcharge_percent', label: 'Surcharge %', type: _FieldType.number),
  _RuleField(writeKey: 'waiverPercent', readKey: 'waiver_percent', label: 'Waiver %', type: _FieldType.number),
  _RuleField(writeKey: 'minTxnInr', readKey: 'min_txn_inr', label: 'Min txn (INR)', type: _FieldType.number),
  _RuleField(writeKey: 'maxTxnInr', readKey: 'max_txn_inr', label: 'Max txn (INR)', type: _FieldType.number),
  _RuleField(writeKey: 'monthlyWaiverCap', readKey: 'monthly_waiver_cap', label: 'Monthly waiver cap (INR)', type: _FieldType.number),
];

const _billingCycleRuleFields = [
  _RuleField(writeKey: 'gracePeriodDays', readKey: 'grace_period_days', label: 'Grace period (days)', type: _FieldType.integer),
  _RuleField(writeKey: 'cycleNotes', readKey: 'cycle_notes', label: 'Cycle notes', type: _FieldType.text),
];

// ---- Generic "many rows per card" tab (Caps/Milestones/Fees/Benefits/Redemption) ----

class _RuleFamilyListTab extends ConsumerStatefulWidget {
  final String cardId;
  final String urlSegment;
  final String auditEntity;
  final List<Map<String, dynamic>> rows;
  final List<_RuleField> fields;
  const _RuleFamilyListTab({
    required this.cardId,
    required this.urlSegment,
    required this.auditEntity,
    required this.rows,
    required this.fields,
  });

  @override
  ConsumerState<_RuleFamilyListTab> createState() => _RuleFamilyListTabState();
}

class _RuleFamilyListTabState extends ConsumerState<_RuleFamilyListTab> {
  bool _addingNew = false;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final row in widget.rows)
          _RuleFamilyRowForm(
            key: ValueKey(row['id']),
            cardId: widget.cardId,
            urlSegment: widget.urlSegment,
            auditEntity: widget.auditEntity,
            fields: widget.fields,
            existingRow: row,
          ),
        if (_addingNew)
          _RuleFamilyRowForm(
            cardId: widget.cardId,
            urlSegment: widget.urlSegment,
            auditEntity: widget.auditEntity,
            fields: widget.fields,
            existingRow: null,
            onCreated: () => setState(() => _addingNew = false),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: () => setState(() => _addingNew = true),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
          ),
      ],
    );
  }
}

class _RuleFamilyRowForm extends ConsumerStatefulWidget {
  final String cardId;
  final String urlSegment;
  final String auditEntity;
  final List<_RuleField> fields;
  final Map<String, dynamic>? existingRow;
  final VoidCallback? onCreated;
  const _RuleFamilyRowForm({
    super.key,
    required this.cardId,
    required this.urlSegment,
    required this.auditEntity,
    required this.fields,
    required this.existingRow,
    this.onCreated,
  });

  @override
  ConsumerState<_RuleFamilyRowForm> createState() => _RuleFamilyRowFormState();
}

class _RuleFamilyRowFormState extends ConsumerState<_RuleFamilyRowForm> {
  final _controllers = <String, TextEditingController>{};
  final _boolValues = <String, bool>{};
  final _dropdownValues = <String, String?>{};
  bool _saving = false;
  bool _deleting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final field in widget.fields) {
      final existing = widget.existingRow?[field.readKey];
      switch (field.type) {
        case _FieldType.boolean:
          _boolValues[field.writeKey] = existing as bool? ?? false;
        case _FieldType.dropdown:
          _dropdownValues[field.writeKey] = existing as String?;
        default:
          _controllers[field.writeKey] = TextEditingController(text: existing == null ? '' : '$existing');
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic>? _collectBody() {
    final body = <String, dynamic>{};
    for (final field in widget.fields) {
      switch (field.type) {
        case _FieldType.text:
          final text = _controllers[field.writeKey]!.text.trim();
          if (text.isNotEmpty) {
            body[field.writeKey] = text;
          } else if (field.required) {
            setState(() => _error = '${field.label} is required');
            return null;
          }
        case _FieldType.number:
          final text = _controllers[field.writeKey]!.text.trim();
          if (text.isEmpty) {
            if (field.required) {
              setState(() => _error = '${field.label} is required');
              return null;
            }
          } else {
            final value = double.tryParse(text);
            if (value == null) {
              setState(() => _error = '${field.label} must be a number');
              return null;
            }
            body[field.writeKey] = value;
          }
        case _FieldType.integer:
          final text = _controllers[field.writeKey]!.text.trim();
          if (text.isEmpty) {
            if (field.required) {
              setState(() => _error = '${field.label} is required');
              return null;
            }
          } else {
            final value = int.tryParse(text);
            if (value == null) {
              setState(() => _error = '${field.label} must be a whole number');
              return null;
            }
            body[field.writeKey] = value;
          }
        case _FieldType.boolean:
          body[field.writeKey] = _boolValues[field.writeKey] ?? false;
        case _FieldType.dropdown:
          final value = _dropdownValues[field.writeKey];
          if (value == null && field.required) {
            setState(() => _error = '${field.label} is required');
            return null;
          }
          if (value != null) body[field.writeKey] = value;
      }
    }
    return body;
  }

  Future<void> _save() async {
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final body = _collectBody();
      if (body == null) return;
      final api = ref.read(adminApiProvider)!;
      if (widget.existingRow == null) {
        await api.createRuleFamilyRow(widget.urlSegment, cardProductId: widget.cardId, fields: body, reason: 'Console edit');
        widget.onCreated?.call();
      } else {
        await api.updateRuleFamilyRow(widget.urlSegment, widget.existingRow!['id'] as String, fields: body, reason: 'Console edit');
      }
      ref.invalidate(adminCardsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    setState(() => _deleting = true);
    try {
      final api = ref.read(adminApiProvider)!;
      await api.deleteRuleFamilyRow(widget.urlSegment, widget.existingRow!['id'] as String, reason: 'Console delete');
      ref.invalidate(adminCardsProvider);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _deleting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                for (final field in widget.fields) _buildFieldInput(field),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '...' : (widget.existingRow == null ? 'Create' : 'Save')),
                ),
                if (widget.existingRow != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _deleting ? null : _delete,
                    child: Text(_deleting ? '...' : 'Delete'),
                  ),
                ],
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFieldInput(_RuleField field) {
    switch (field.type) {
      case _FieldType.boolean:
        return SizedBox(
          width: 180,
          child: CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(field.label),
            value: _boolValues[field.writeKey] ?? false,
            onChanged: (v) => setState(() => _boolValues[field.writeKey] = v ?? false),
          ),
        );
      case _FieldType.dropdown:
        return SizedBox(
          width: 200,
          child: DropdownButtonFormField<String>(
            initialValue: _dropdownValues[field.writeKey],
            isExpanded: true,
            decoration: InputDecoration(labelText: field.label, isDense: true),
            items: [
              for (final opt in field.options!)
                DropdownMenuItem(value: opt, child: Text(opt, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _dropdownValues[field.writeKey] = v),
          ),
        );
      case _FieldType.number:
      case _FieldType.integer:
        return SizedBox(
          width: 160,
          child: TextField(
            controller: _controllers[field.writeKey],
            keyboardType: TextInputType.numberWithOptions(decimal: field.type == _FieldType.number),
            decoration: InputDecoration(labelText: field.label, isDense: true),
          ),
        );
      case _FieldType.text:
        return SizedBox(
          width: 220,
          child: TextField(
            controller: _controllers[field.writeKey],
            decoration: InputDecoration(labelText: field.label, isDense: true),
          ),
        );
    }
  }
}

// ---- Generic "one row per card" editor (Forex/Fuel/Cycle) -------------------

class _RuleFamilySingleEditor extends StatelessWidget {
  final String cardId;
  final String urlSegment;
  final String auditEntity;
  final Map<String, dynamic>? row;
  final List<_RuleField> fields;
  const _RuleFamilySingleEditor({
    required this.cardId,
    required this.urlSegment,
    required this.auditEntity,
    required this.row,
    required this.fields,
  });

  @override
  Widget build(BuildContext context) {
    return _SinglePerCardForm(cardId: cardId, urlSegment: urlSegment, existingRow: row, fields: fields);
  }
}

class _SinglePerCardForm extends ConsumerStatefulWidget {
  final String cardId;
  final String urlSegment;
  final Map<String, dynamic>? existingRow;
  final List<_RuleField> fields;
  const _SinglePerCardForm({
    required this.cardId,
    required this.urlSegment,
    required this.existingRow,
    required this.fields,
  });

  @override
  ConsumerState<_SinglePerCardForm> createState() => _SinglePerCardFormState();
}

class _SinglePerCardFormState extends ConsumerState<_SinglePerCardForm> {
  final _controllers = <String, TextEditingController>{};
  final _boolValues = <String, bool>{};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final field in widget.fields) {
      final existing = widget.existingRow?[field.readKey];
      if (field.type == _FieldType.boolean) {
        _boolValues[field.writeKey] = existing as bool? ?? false;
      } else {
        _controllers[field.writeKey] = TextEditingController(text: existing == null ? '' : '$existing');
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final body = <String, dynamic>{};
      for (final field in widget.fields) {
        if (field.type == _FieldType.boolean) {
          body[field.writeKey] = _boolValues[field.writeKey] ?? false;
          continue;
        }
        final text = _controllers[field.writeKey]!.text.trim();
        if (text.isEmpty) {
          if (field.required) {
            setState(() => _error = '${field.label} is required');
            return;
          }
          continue;
        }
        if (field.type == _FieldType.integer) {
          final value = int.tryParse(text);
          if (value == null) {
            setState(() => _error = '${field.label} must be a whole number');
            return;
          }
          body[field.writeKey] = value;
        } else if (field.type == _FieldType.number) {
          final value = double.tryParse(text);
          if (value == null) {
            setState(() => _error = '${field.label} must be a number');
            return;
          }
          body[field.writeKey] = value;
        } else {
          body[field.writeKey] = text;
        }
      }
      final api = ref.read(adminApiProvider)!;
      await api.upsertSinglePerCardRuleFamily(widget.urlSegment, cardProductId: widget.cardId, fields: body, reason: 'Console edit');
      ref.invalidate(adminCardsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final field in widget.fields)
              if (field.type == _FieldType.boolean)
                SizedBox(
                  width: 180,
                  child: CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(field.label),
                    value: _boolValues[field.writeKey] ?? false,
                    onChanged: (v) => setState(() => _boolValues[field.writeKey] = v ?? false),
                  ),
                )
              else
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _controllers[field.writeKey],
                    keyboardType: field.type == _FieldType.number
                        ? const TextInputType.numberWithOptions(decimal: true)
                        : (field.type == _FieldType.integer ? TextInputType.number : TextInputType.text),
                    decoration: InputDecoration(labelText: field.label, isDense: true),
                  ),
                ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '...' : 'Save'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
          ),
      ],
    );
  }
}

// ---- Rewards tab (unchanged behavior, kept as its own small widget) --------

class _RewardsTab extends StatelessWidget {
  final String cardId;
  final List<Map<String, dynamic>> rewardRules;
  const _RewardsTab({required this.cardId, required this.rewardRules});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [for (final rule in rewardRules) _RewardRuleRow(cardId: cardId, rule: rule)],
    );
  }
}

class _RewardRuleRow extends ConsumerStatefulWidget {
  final String cardId;
  final Map<String, dynamic> rule;
  const _RewardRuleRow({required this.cardId, required this.rule});

  @override
  ConsumerState<_RewardRuleRow> createState() => _RewardRuleRowState();
}

class _RewardRuleRowState extends ConsumerState<_RewardRuleRow> {
  late final TextEditingController _rateController;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rateController = TextEditingController(text: '${widget.rule['rate']}');
  }

  Future<void> _save() async {
    final rate = double.tryParse(_rateController.text);
    if (rate == null || rate < 0) {
      setState(() => _error = 'rate must be a non-negative number');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = ref.read(adminApiProvider);
      await api!.updateRewardRuleRate(widget.rule['id'] as String, rate, reason: 'Console edit');
      ref.invalidate(adminCardsProvider); // AD-1.1.5-adjacent: refetch so data_version/rate are current
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text('${widget.rule['unit']}')),
          SizedBox(
            width: 100,
            child: TextField(
              controller: _rateController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Rate', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '...' : 'Save'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
