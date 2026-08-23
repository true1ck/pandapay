import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-1.1.1 catalogue browse: card list with status + AD-1.1.4's
/// draft->in_review->published->archived state machine (publish sets
/// verified_at server-side — the human verification pass).
///
/// AD-1.1.2 tabbed rule-family editor: each card expands into 10 tabs —
/// Rewards, Caps, Milestones, Fees, Benefits, Forex & Fuel, Cycle,
/// Redemption, Card Info, Provenance — covering every rule table and every
/// card_products column v_admin_card_catalogue_export returns (0022's
/// migration, extended by 0039). Still missing vs the full plan:
/// diff-before-save confirmation, impact preview, bulk YAML import/export
/// — AD-1.2/AD-1.3 territory, a separate (larger) piece of work from
/// "can an admin actually edit every rule family", which this covers.
class CatalogueScreen extends ConsumerWidget {
  const CatalogueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(adminCardsProvider);
    // The Rewards tab's category dropdown needs id->name; categoriesProvider
    // already exists for AD-6.1.4's merchant category filter and hits the
    // same public GET /categories, so this reuses it rather than adding a
    // second fetch of the same reference data.
    final categories = ref.watch(categoriesProvider);
    final categoryOptions = {
      for (final c in categories.value ?? const <Map<String, dynamic>>[])
        c['id'] as String: c['name'] as String,
    };

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
          itemBuilder: (context, index) =>
              _CardEditorTile(cardList[index], categoryOptions: categoryOptions),
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
  final Map<String, String> categoryOptions;
  const _CardEditorTile(this.card, {required this.categoryOptions});

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
          if (_expanded)
            SizedBox(
              height: 520,
              child: _CardRuleFamilyTabs(card: card, categoryOptions: widget.categoryOptions),
            ),
        ],
      ),
    );
  }
}

/// The 10-tab rule-family editor for one card. The 8 rule-table tabs and the
/// Card Info tab are all driven by the same declarative field-spec shape the
/// backend's admin_rule_families.js factory uses, so adding/removing a field
/// stays a one-line change instead of touching each tab's widget by hand.
/// Provenance reuses the exact same widgets, scoped to a smaller field
/// subset — see _ProvenanceTab.
class _CardRuleFamilyTabs extends StatelessWidget {
  final Map<String, dynamic> card;
  final Map<String, String> categoryOptions;
  const _CardRuleFamilyTabs({required this.card, required this.categoryOptions});

  @override
  Widget build(BuildContext context) {
    final cardId = card['id'] as String;
    return DefaultTabController(
      length: 10,
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
              Tab(text: 'Card Info'),
              Tab(text: 'Provenance'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _RuleFamilyListTab(
                  cardId: cardId,
                  urlSegment: 'reward-rules',
                  auditEntity: 'reward_rule',
                  rows: (card['reward_rules'] as List? ?? const []).cast<Map<String, dynamic>>(),
                  fields: _rewardRuleFields,
                  categoryOptions: categoryOptions,
                ),
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
                  categoryOptions: categoryOptions,
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
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _CardOwnFieldsEditor(cardId: cardId, card: card, fields: _cardOwnFields),
                  ],
                ),
                _ProvenanceTab(cardId: cardId, card: card, categoryOptions: categoryOptions),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Provenance tab: card-level source_class/source_license/source_excerpt/
/// source_links + a read-only verified_by line, followed by one collapsible
/// section per rule family that carries the 0037 provenance columns (every
/// family except reward_rules, whose only non-value field — `conditions` —
/// already lives on the Rewards tab instead). Each section reuses the same
/// _RuleFamilyListTab/_RuleFamilySingleEditor widgets the value tabs use,
/// scoped to the provenance-only field subset and reading the exact same
/// `card[...]` rows already fetched — no second request per family.
class _ProvenanceTab extends StatelessWidget {
  final String cardId;
  final Map<String, dynamic> card;
  final Map<String, String> categoryOptions;
  const _ProvenanceTab({required this.cardId, required this.card, required this.categoryOptions});

  @override
  Widget build(BuildContext context) {
    final verifiedBy = card['verified_by'] as String?;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Card-level provenance', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _CardOwnFieldsEditor(cardId: cardId, card: card, fields: _cardProvenanceFields),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            verifiedBy != null ? 'Verified by: $verifiedBy' : 'Verified by: not yet verified',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const Divider(height: 32),
        _ProvenanceSection(
          title: 'Reward rules — conditions',
          child: SizedBox(
            height: 260,
            child: _RuleFamilyListTab(
              cardId: cardId,
              urlSegment: 'reward-rules',
              auditEntity: 'reward_rule',
              rows: (card['reward_rules'] as List? ?? const []).cast<Map<String, dynamic>>(),
              fields: const [
                _RuleField(writeKey: 'conditions', readKey: 'conditions', label: 'Conditions', type: _FieldType.keyValueJson),
              ],
              allowCreate: false,
            ),
          ),
        ),
        _ProvenanceSection(
          title: 'Cap rules provenance',
          child: SizedBox(
            height: 260,
            child: _RuleFamilyListTab(
              cardId: cardId,
              urlSegment: 'cap-rules',
              auditEntity: 'cap_rule',
              rows: (card['cap_rules'] as List? ?? const []).cast<Map<String, dynamic>>(),
              fields: _provenanceFields,
              allowCreate: false,
            ),
          ),
        ),
        _ProvenanceSection(
          title: 'Milestone rules provenance',
          child: SizedBox(
            height: 260,
            child: _RuleFamilyListTab(
              cardId: cardId,
              urlSegment: 'milestone-rules',
              auditEntity: 'milestone_rule',
              rows: (card['milestone_rules'] as List? ?? const []).cast<Map<String, dynamic>>(),
              fields: _provenanceFields,
              allowCreate: false,
            ),
          ),
        ),
        _ProvenanceSection(
          title: 'Fee waiver rules provenance',
          child: SizedBox(
            height: 260,
            child: _RuleFamilyListTab(
              cardId: cardId,
              urlSegment: 'fee-waiver-rules',
              auditEntity: 'fee_waiver_rule',
              rows: (card['fee_waiver_rules'] as List? ?? const []).cast<Map<String, dynamic>>(),
              fields: _provenanceFields,
              allowCreate: false,
            ),
          ),
        ),
        _ProvenanceSection(
          title: 'Benefits provenance',
          child: SizedBox(
            height: 260,
            child: _RuleFamilyListTab(
              cardId: cardId,
              urlSegment: 'card-benefits',
              auditEntity: 'card_benefit',
              rows: (card['benefits'] as List? ?? const []).cast<Map<String, dynamic>>(),
              fields: _provenanceFields,
              allowCreate: false,
            ),
          ),
        ),
        _ProvenanceSection(
          title: 'Redemption options provenance',
          child: SizedBox(
            height: 260,
            child: _RuleFamilyListTab(
              cardId: cardId,
              urlSegment: 'redemption-options',
              auditEntity: 'redemption_option',
              rows: (card['redemption_options'] as List? ?? const []).cast<Map<String, dynamic>>(),
              fields: _provenanceFields,
              allowCreate: false,
            ),
          ),
        ),
        _ProvenanceSection(
          title: 'Forex provenance',
          child: _RuleFamilySingleEditor(
            cardId: cardId,
            urlSegment: 'forex-rules',
            auditEntity: 'forex_rule',
            row: card['forex'] as Map<String, dynamic>?,
            fields: _provenanceFields,
          ),
        ),
        _ProvenanceSection(
          title: 'Fuel surcharge provenance',
          child: _RuleFamilySingleEditor(
            cardId: cardId,
            urlSegment: 'fuel-surcharge-rules',
            auditEntity: 'fuel_surcharge_rule',
            row: card['fuel'] as Map<String, dynamic>?,
            fields: _provenanceFields,
          ),
        ),
        _ProvenanceSection(
          title: 'Billing cycle provenance',
          child: _RuleFamilySingleEditor(
            cardId: cardId,
            urlSegment: 'billing-cycle-rules',
            auditEntity: 'billing_cycle_rule',
            row: card['billing_cycle'] as Map<String, dynamic>?,
            fields: _provenanceFields,
          ),
        ),
      ],
    );
  }
}

class _ProvenanceSection extends StatelessWidget {
  final String title;
  final Widget child;
  const _ProvenanceSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text(title),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 16),
      children: [child],
    );
  }
}

// ---- Declarative field specs, one per rule family --------------------------
// `writeKey` is the camelCase JSON key the backend's typed writer validates
// (admin_rule_families.js field specs); `readKey` is the snake_case column
// name as it comes back from v_admin_card_catalogue_export. They differ for
// every multi-word field because the JS request body and the Postgres row
// use different casing conventions, same as everywhere else in this app.

// keyValueJson backs jsonb columns (reward_rules.conditions,
// card_benefits.conditions, card_products.source_links) with a repeatable
// key/value row editor instead of a raw JSON text box. multiSelectCategories
// backs fee_waiver_rules.excluded_categories (uuid[]) with a category chip
// picker sourced from the same categoryOptions map the reward-rules category
// dropdown already uses.
enum _FieldType { text, number, integer, boolean, dropdown, keyValueJson, multiSelectCategories }

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
const _txnRails = ['upi_qr', 'swipe', 'online', 'contactless', 'atm', 'emi', 'unknown'];
const _capPeriods = ['statement_cycle', 'calendar_month', 'quarter', 'half_year', 'annual', 'lifetime'];
const _capMeasures = ['reward_value', 'spend_amount', 'txn_count'];
const _benefitKinds = [
  'lounge_domestic', 'lounge_international', 'golf', 'concierge', 'insurance_travel',
  'insurance_purchase', 'extended_warranty', 'dining_program', 'movie', 'fuel_surcharge',
  'roadside_assistance', 'other',
];
const _milestoneAnchors = ['card_anniversary', 'calendar_year', 'fiscal_year', 'statement_cycle'];

// categoryId has no static `options` — spend_categories is DB reference
// data, not an enum, so its dropdown is resolved at build time from the
// categoryOptions map (see _buildFieldInput's categoryId special-case)
// rather than field.options.
const _rewardRuleFields = [
  _RuleField(writeKey: 'categoryId', readKey: 'category_id', label: 'Category', type: _FieldType.dropdown),
  _RuleField(writeKey: 'merchantPattern', readKey: 'merchant_pattern', label: 'Merchant pattern', type: _FieldType.text),
  _RuleField(writeKey: 'rail', readKey: 'rail', label: 'Rail', type: _FieldType.dropdown, options: _txnRails),
  _RuleField(writeKey: 'unit', readKey: 'unit', label: 'Unit', type: _FieldType.dropdown, options: _rewardUnits, required: true),
  _RuleField(writeKey: 'rate', readKey: 'rate', label: 'Rate', type: _FieldType.number, required: true),
  _RuleField(writeKey: 'minTxnInr', readKey: 'min_txn_inr', label: 'Min txn (INR)', type: _FieldType.number),
  _RuleField(writeKey: 'maxTxnInr', readKey: 'max_txn_inr', label: 'Max txn (INR)', type: _FieldType.number),
  _RuleField(writeKey: 'priority', readKey: 'priority', label: 'Priority', type: _FieldType.integer),
  _RuleField(writeKey: 'notes', readKey: 'notes', label: 'Notes', type: _FieldType.text),
  _RuleField(writeKey: 'effectiveFrom', readKey: 'effective_from', label: 'Effective from (YYYY-MM-DD)', type: _FieldType.text),
  _RuleField(writeKey: 'effectiveTo', readKey: 'effective_to', label: 'Effective to (YYYY-MM-DD)', type: _FieldType.text),
  _RuleField(writeKey: 'conditions', readKey: 'conditions', label: 'Conditions', type: _FieldType.keyValueJson),
];

const _cardOwnFields = [
  _RuleField(writeKey: 'annualFeeInr', readKey: 'annual_fee_inr', label: 'Annual fee (INR)', type: _FieldType.number),
  _RuleField(writeKey: 'joiningFeeInr', readKey: 'joining_fee_inr', label: 'Joining fee (INR)', type: _FieldType.number),
  _RuleField(writeKey: 'feeGstApplicable', readKey: 'fee_gst_applicable', label: 'GST applicable on fee', type: _FieldType.boolean),
  _RuleField(writeKey: 'isUpiLinkable', readKey: 'is_upi_linkable', label: 'UPI-linkable', type: _FieldType.boolean),
  _RuleField(writeKey: 'artAsset', readKey: 'art_asset', label: 'Art asset key', type: _FieldType.text),
  _RuleField(writeKey: 'artPrimaryColor', readKey: 'art_primary_color', label: 'Art primary color', type: _FieldType.text),
  _RuleField(writeKey: 'baseRewardUnit', readKey: 'base_reward_unit', label: 'Base reward unit', type: _FieldType.dropdown, options: _rewardUnits),
  _RuleField(writeKey: 'baseRewardRate', readKey: 'base_reward_rate', label: 'Base reward rate', type: _FieldType.number),
  _RuleField(writeKey: 'pointValueInr', readKey: 'point_value_inr', label: 'Point value (INR)', type: _FieldType.number),
  _RuleField(writeKey: 'pointValueBasis', readKey: 'point_value_basis', label: 'Point value basis', type: _FieldType.text),
  _RuleField(writeKey: 'positioningNotes', readKey: 'positioning_notes', label: 'Positioning notes', type: _FieldType.text),
  _RuleField(writeKey: 'sourceUrl', readKey: 'source_url', label: 'Source URL', type: _FieldType.text),
];

// ---- Provenance tab: 0037's source_class/source_license/source_excerpt/
// source_url/verified_at columns, added to card_products itself and to 8 of
// its 9 child tables (every one except reward_rules). Every family that has
// them carries the exact same 5 columns, so one shared field-spec covers all
// 8 — redemption-options and card-benefits each get one extra field spread
// on top for their own additional non-provenance data. reward_rules has none
// of these columns (its own conditions field lives on the Rewards tab
// instead), so it has no section on this tab at all.
const _sourceClasses = ['issuer_official', 'third_party_structured', 'third_party_page', 'community_open_source'];

const _provenanceFields = [
  _RuleField(writeKey: 'sourceUrl', readKey: 'source_url', label: 'Source URL', type: _FieldType.text),
  _RuleField(writeKey: 'sourceClass', readKey: 'source_class', label: 'Source class', type: _FieldType.dropdown, options: _sourceClasses),
  _RuleField(writeKey: 'sourceLicense', readKey: 'source_license', label: 'Source license', type: _FieldType.text),
  _RuleField(writeKey: 'sourceExcerpt', readKey: 'source_excerpt', label: 'Source excerpt', type: _FieldType.text),
  _RuleField(writeKey: 'verifiedAt', readKey: 'verified_at', label: 'Verified at (ISO date)', type: _FieldType.text),
];

const _cardProvenanceFields = [
  _RuleField(writeKey: 'sourceClass', readKey: 'source_class', label: 'Source class', type: _FieldType.dropdown, options: _sourceClasses),
  _RuleField(writeKey: 'sourceLicense', readKey: 'source_license', label: 'Source license', type: _FieldType.text),
  _RuleField(writeKey: 'sourceExcerpt', readKey: 'source_excerpt', label: 'Source excerpt', type: _FieldType.text),
  _RuleField(writeKey: 'sourceLinks', readKey: 'source_links', label: 'Source links (e.g. canonical, brochure, tnc)', type: _FieldType.keyValueJson),
];

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
  _RuleField(writeKey: 'excludedCategories', readKey: 'excluded_categories', label: 'Excluded categories', type: _FieldType.multiSelectCategories),
];

const _cardBenefitFields = [
  _RuleField(writeKey: 'kind', readKey: 'kind', label: 'Kind', type: _FieldType.dropdown, options: _benefitKinds, required: true),
  _RuleField(writeKey: 'label', readKey: 'label', label: 'Label', type: _FieldType.text, required: true),
  _RuleField(writeKey: 'description', readKey: 'description', label: 'Description', type: _FieldType.text),
  _RuleField(writeKey: 'quotaCount', readKey: 'quota_count', label: 'Quota count', type: _FieldType.integer),
  _RuleField(writeKey: 'quotaPeriod', readKey: 'quota_period', label: 'Quota period', type: _FieldType.dropdown, options: _capPeriods),
  _RuleField(writeKey: 'networkProgram', readKey: 'network_program', label: 'Network program', type: _FieldType.text),
  _RuleField(writeKey: 'valueEstimateInr', readKey: 'value_estimate_inr', label: 'Value estimate (INR)', type: _FieldType.number),
  _RuleField(writeKey: 'conditions', readKey: 'conditions', label: 'Conditions', type: _FieldType.keyValueJson),
];

const _redemptionOptionFields = [
  _RuleField(writeKey: 'programName', readKey: 'program_name', label: 'Program name', type: _FieldType.text, required: true),
  _RuleField(writeKey: 'method', readKey: 'method', label: 'Method', type: _FieldType.text, required: true),
  _RuleField(writeKey: 'valuePerPointInr', readKey: 'value_per_point_inr', label: 'Value per point (INR)', type: _FieldType.number, required: true),
  _RuleField(writeKey: 'minPoints', readKey: 'min_points', label: 'Min points', type: _FieldType.integer),
  _RuleField(writeKey: 'notes', readKey: 'notes', label: 'Notes', type: _FieldType.text),
  _RuleField(writeKey: 'lastCheckedAt', readKey: 'last_checked_at', label: 'Last checked at (ISO date)', type: _FieldType.text),
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

// ---- Structured mini-editors for jsonb / uuid[] fields ---------------------
// Both expose their current value through a public method reached via a
// GlobalKey the host form stashes at build time, rather than an onChanged
// callback that would setState() the host on every keystroke/tap — the host
// only needs the value once, at Save.

class _KeyValueEditor extends StatefulWidget {
  final Map<String, dynamic> initial;
  const _KeyValueEditor({super.key, required this.initial});

  @override
  State<_KeyValueEditor> createState() => _KeyValueEditorState();
}

class _KeyValueEditorState extends State<_KeyValueEditor> {
  final List<MapEntry<TextEditingController, TextEditingController>> _pairs = [];

  @override
  void initState() {
    super.initState();
    widget.initial.forEach(
      (k, v) => _pairs.add(MapEntry(TextEditingController(text: k), TextEditingController(text: '$v'))),
    );
  }

  @override
  void dispose() {
    for (final p in _pairs) {
      p.key.dispose();
      p.value.dispose();
    }
    super.dispose();
  }

  Map<String, String> currentValue() {
    final map = <String, String>{};
    for (final p in _pairs) {
      final k = p.key.text.trim();
      if (k.isNotEmpty) map[k] = p.value.text.trim();
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final p in _pairs)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                SizedBox(width: 140, child: TextField(controller: p.key, decoration: const InputDecoration(labelText: 'Key', isDense: true))),
                const SizedBox(width: 8),
                SizedBox(width: 220, child: TextField(controller: p.value, decoration: const InputDecoration(labelText: 'Value', isDense: true))),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  onPressed: () => setState(() {
                    p.key.dispose();
                    p.value.dispose();
                    _pairs.remove(p);
                  }),
                ),
              ],
            ),
          ),
        OutlinedButton.icon(
          onPressed: () => setState(() => _pairs.add(MapEntry(TextEditingController(), TextEditingController()))),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add pair'),
        ),
      ],
    );
  }
}

class _CategoryMultiSelect extends StatefulWidget {
  final Map<String, String> categoryOptions;
  final List<String> initial;
  const _CategoryMultiSelect({super.key, required this.categoryOptions, required this.initial});

  @override
  State<_CategoryMultiSelect> createState() => _CategoryMultiSelectState();
}

class _CategoryMultiSelectState extends State<_CategoryMultiSelect> {
  late final Set<String> _selected = widget.initial.toSet();

  List<String> currentValue() => _selected.toList();

  @override
  Widget build(BuildContext context) {
    if (widget.categoryOptions.isEmpty) {
      return const Text('No categories loaded', style: TextStyle(fontSize: 12, color: Colors.grey));
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final entry in widget.categoryOptions.entries)
          FilterChip(
            label: Text(entry.value),
            selected: _selected.contains(entry.key),
            onSelected: (v) => setState(() {
              if (v) {
                _selected.add(entry.key);
              } else {
                _selected.remove(entry.key);
              }
            }),
          ),
      ],
    );
  }
}

// ---- Generic "many rows per card" tab (Caps/Milestones/Fees/Benefits/Redemption) ----

class _RuleFamilyListTab extends ConsumerStatefulWidget {
  final String cardId;
  final String urlSegment;
  final String auditEntity;
  final List<Map<String, dynamic>> rows;
  final List<_RuleField> fields;
  /// id -> name, consumed by categoryId (Rewards) and excludedCategories
  /// (Fees) fields (see _buildFieldInput). Families with neither pass null.
  final Map<String, String>? categoryOptions;
  /// False on the Provenance tab's per-family sections: those pass a
  /// provenance-only field subset (source_url/verified_at/etc) that's
  /// missing every required value field a real new row needs (label,
  /// measure, cap_value, ...), so creating from there would either fail
  /// server-side validation or silently insert a broken row. The value tabs
  /// (Caps/Milestones/etc) keep the default of true.
  final bool allowCreate;
  const _RuleFamilyListTab({
    required this.cardId,
    required this.urlSegment,
    required this.auditEntity,
    required this.rows,
    required this.fields,
    this.categoryOptions,
    this.allowCreate = true,
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
            categoryOptions: widget.categoryOptions,
          ),
        if (widget.allowCreate)
          if (_addingNew)
            _RuleFamilyRowForm(
              cardId: widget.cardId,
              urlSegment: widget.urlSegment,
              auditEntity: widget.auditEntity,
              fields: widget.fields,
              existingRow: null,
              categoryOptions: widget.categoryOptions,
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
  final Map<String, String>? categoryOptions;
  final VoidCallback? onCreated;
  const _RuleFamilyRowForm({
    super.key,
    required this.cardId,
    required this.urlSegment,
    required this.auditEntity,
    required this.fields,
    required this.existingRow,
    this.categoryOptions,
    this.onCreated,
  });

  @override
  ConsumerState<_RuleFamilyRowForm> createState() => _RuleFamilyRowFormState();
}

class _RuleFamilyRowFormState extends ConsumerState<_RuleFamilyRowForm> {
  final _controllers = <String, TextEditingController>{};
  final _boolValues = <String, bool>{};
  final _dropdownValues = <String, String?>{};
  // keyValueJson/multiSelectCategories manage their own internal state
  // (see _KeyValueEditor/_CategoryMultiSelect) — this just holds the
  // GlobalKey used to reach `currentValue()` on those widgets at save time.
  final _compositeKeys = <String, GlobalKey>{};
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
        case _FieldType.keyValueJson:
        case _FieldType.multiSelectCategories:
          _compositeKeys[field.writeKey] = GlobalKey();
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
        case _FieldType.keyValueJson:
          final state = _compositeKeys[field.writeKey]?.currentState as _KeyValueEditorState?;
          body[field.writeKey] = state?.currentValue() ?? <String, String>{};
        case _FieldType.multiSelectCategories:
          final state = _compositeKeys[field.writeKey]?.currentState as _CategoryMultiSelectState?;
          body[field.writeKey] = state?.currentValue() ?? <String>[];
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
        // categoryId has no static field.options (spend_categories is DB
        // data) — its items come from the id->name map threaded down from
        // CatalogueScreen's categoriesProvider watch instead.
        final isCategoryField = field.writeKey == 'categoryId' && widget.categoryOptions != null;
        return SizedBox(
          width: 200,
          child: DropdownButtonFormField<String>(
            initialValue: _dropdownValues[field.writeKey],
            isExpanded: true,
            decoration: InputDecoration(labelText: field.label, isDense: true),
            items: isCategoryField
                ? [
                    for (final entry in widget.categoryOptions!.entries)
                      DropdownMenuItem(value: entry.key, child: Text(entry.value, overflow: TextOverflow.ellipsis)),
                  ]
                : [
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
      case _FieldType.keyValueJson:
        final existing = widget.existingRow?[field.readKey];
        final initialMap = existing is Map ? existing.map((k, v) => MapEntry('$k', v)) : const <String, dynamic>{};
        return SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(field.label, style: Theme.of(context).textTheme.labelMedium),
              _KeyValueEditor(key: _compositeKeys[field.writeKey], initial: initialMap),
            ],
          ),
        );
      case _FieldType.multiSelectCategories:
        final existing = widget.existingRow?[field.readKey];
        final initialList = existing is List ? existing.map((e) => '$e').toList() : const <String>[];
        return SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(field.label, style: Theme.of(context).textTheme.labelMedium),
              _CategoryMultiSelect(
                key: _compositeKeys[field.writeKey],
                categoryOptions: widget.categoryOptions ?? const {},
                initial: initialList,
              ),
            ],
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

// ---- Card Info tab: card_products' own columns, not a child table --------
// Not a _RuleFamilySingleEditor (that upserts a child row keyed by
// card_product_id via PUT .../by-card/:id) — card_products is the parent
// row itself, so this calls AdminApi.updateCardFields -> PUT
// /admin/card-products/:id directly, same field-collection logic as
// _SinglePerCardFormState otherwise.

class _CardOwnFieldsEditor extends ConsumerStatefulWidget {
  final String cardId;
  final Map<String, dynamic> card;
  /// Card Info passes _cardOwnFields; Provenance passes the smaller
  /// _cardProvenanceFields — both hit the same PUT /admin/card-products/:id
  /// partial-update endpoint, just with a different field subset.
  final List<_RuleField> fields;
  const _CardOwnFieldsEditor({required this.cardId, required this.card, required this.fields});

  @override
  ConsumerState<_CardOwnFieldsEditor> createState() => _CardOwnFieldsEditorState();
}

class _CardOwnFieldsEditorState extends ConsumerState<_CardOwnFieldsEditor> {
  final _controllers = <String, TextEditingController>{};
  final _boolValues = <String, bool>{};
  final _dropdownValues = <String, String?>{};
  final _compositeKeys = <String, GlobalKey>{};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final field in widget.fields) {
      final existing = widget.card[field.readKey];
      switch (field.type) {
        case _FieldType.boolean:
          _boolValues[field.writeKey] = existing as bool? ?? false;
        case _FieldType.dropdown:
          _dropdownValues[field.writeKey] = existing as String?;
        case _FieldType.keyValueJson:
        case _FieldType.multiSelectCategories:
          _compositeKeys[field.writeKey] = GlobalKey();
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

  Future<void> _save() async {
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final body = <String, dynamic>{};
      for (final field in widget.fields) {
        switch (field.type) {
          case _FieldType.boolean:
            body[field.writeKey] = _boolValues[field.writeKey] ?? false;
          case _FieldType.dropdown:
            final value = _dropdownValues[field.writeKey];
            if (value != null) body[field.writeKey] = value;
          case _FieldType.number:
            final text = _controllers[field.writeKey]!.text.trim();
            if (text.isNotEmpty) {
              final value = double.tryParse(text);
              if (value == null) {
                setState(() => _error = '${field.label} must be a number');
                return;
              }
              body[field.writeKey] = value;
            }
          case _FieldType.integer:
          case _FieldType.text:
            final text = _controllers[field.writeKey]!.text.trim();
            if (text.isNotEmpty) body[field.writeKey] = text;
          case _FieldType.keyValueJson:
            final state = _compositeKeys[field.writeKey]?.currentState as _KeyValueEditorState?;
            body[field.writeKey] = state?.currentValue() ?? <String, String>{};
          case _FieldType.multiSelectCategories:
            final state = _compositeKeys[field.writeKey]?.currentState as _CategoryMultiSelectState?;
            body[field.writeKey] = state?.currentValue() ?? <String>[];
        }
      }
      final api = ref.read(adminApiProvider)!;
      await api.updateCardFields(widget.cardId, fields: body, reason: 'Console edit');
      ref.invalidate(adminCardsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildFieldInput(_RuleField field) {
    switch (field.type) {
      case _FieldType.boolean:
        return SizedBox(
          width: 220,
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
          width: 220,
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
          width: 200,
          child: TextField(
            controller: _controllers[field.writeKey],
            keyboardType: TextInputType.numberWithOptions(decimal: field.type == _FieldType.number),
            decoration: InputDecoration(labelText: field.label, isDense: true),
          ),
        );
      case _FieldType.text:
        return SizedBox(
          width: 280,
          child: TextField(
            controller: _controllers[field.writeKey],
            decoration: InputDecoration(labelText: field.label, isDense: true),
          ),
        );
      case _FieldType.keyValueJson:
        final existing = widget.card[field.readKey];
        final initialMap = existing is Map ? existing.map((k, v) => MapEntry('$k', v)) : const <String, dynamic>{};
        return SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(field.label, style: Theme.of(context).textTheme.labelMedium),
              _KeyValueEditor(key: _compositeKeys[field.writeKey], initial: initialMap),
            ],
          ),
        );
      case _FieldType.multiSelectCategories:
        // Not used by any current _cardOwnFields/_cardProvenanceFields
        // entry, but handled for completeness since _RuleField's type is
        // shared across every editor in this file.
        return const SizedBox.shrink();
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
          children: [for (final field in widget.fields) _buildFieldInput(field)],
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
