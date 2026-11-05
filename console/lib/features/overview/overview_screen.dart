import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/admin_design.dart';
import '../../app/admin_identity.dart';
import '../../app/providers.dart';
import '../../app/time_format.dart';
import '../sms_rules/ai_drafting_status.dart';
import '../sms_rules/providers.dart';

/// Landing page: what is waiting for a decision, what looks broken, and
/// which environment this is. Read-only by design; every action lives in
/// its own screen. Reuses the screens' providers, so opening a queue after
/// the overview does not refetch it.
class OverviewScreen extends ConsumerWidget {
  const OverviewScreen({required this.onOpen, super.key});

  /// Opens a console destination by its navigation label.
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(adminIdentityProvider);
    bool canOpen(String destination) =>
        identity.can(kDestinationPermissions[destination]);

    // Only watch what this role may read, so no request is made that the
    // server would refuse.
    final dq = identity.can('operations.read')
        ? ref.watch(dataQualityDashboardProvider)
        : null;
    final audits = canOpen('Anonymization Audit')
        ? ref.watch(anonymizationAuditRunsProvider)
        : null;
    final smsRules = canOpen('SMS Rule Approvals')
        ? _SmsRuleBacklog.from(ref)
        : null;

    // The Learning page's own destination; hidden for roles that cannot read it.
    final learning = canOpen('SMS Pipeline Rules')
        ? ref.watch(smsLearningSummaryProvider)
        : null;
    final aiSettings = canOpen('SMS Pipeline Rules')
        ? ref.watch(smsAiSettingsProvider)
        : null;

    _Count dqCount(String key) => _Count.fromAsync(dq, (d) => d?[key]);

    final attention = <_TileData>[
      if (dq != null && canOpen('Policy Alerts'))
        _TileData.queue(
          'Open policy alerts',
          'Issuer changes waiting for a decision',
          Icons.notifications_active_outlined,
          dqCount('alerts_open'),
          'Policy Alerts',
        ),
      if (dq != null && canOpen('Error Reports'))
        _TileData.queue(
          'Pending error reports',
          'Users say a card detail is wrong',
          Icons.fact_check_outlined,
          dqCount('error_reports_pending'),
          'Error Reports',
        ),
      if (smsRules != null)
        _TileData.queue(
          'SMS rules to review',
          smsRules.caption,
          Icons.rule_outlined,
          smsRules.count,
          'SMS Rule Approvals',
        ),
      if (learning != null)
        _TileData.queue(
          'Learning candidates',
          'Shops and names people agree on',
          Icons.lightbulb_outline,
          _Count.fromAsync(
            learning,
            (d) => (d['candidates'] as Map?)?['total'],
          ),
          'SMS Pipeline Rules',
        ),
      if (dq != null && canOpen('Support Tickets'))
        _TileData.queue(
          'Open support tickets',
          'Feedback and problems from users',
          Icons.support_agent_outlined,
          dqCount('support_tickets_pending'),
          'Support Tickets',
        ),
      if (dq != null && canOpen('Conflicts'))
        _TileData.queue(
          'Merchant conflicts',
          'Competing merchant claims to settle',
          Icons.gavel_outlined,
          dqCount('conflicts_pending'),
          'Conflicts',
        ),
      if (dq != null && canOpen('Card Requests'))
        _TileData.queue(
          'Card requests waiting',
          'Cards users want added',
          Icons.playlist_add_outlined,
          dqCount('card_requests_pending'),
          'Card Requests',
          urgent: false,
        ),
    ];

    final system = canOpen('System Status')
        ? ref.watch(systemStatusProvider)
        : null;

    final aiProblems = aiSettings?.valueOrNull == null
        ? const <String>[]
        : aiDraftingProblems(
            settings: [
              for (final row in (aiSettings!.requireValue['settings'] as List? ?? const []))
                (row as Map).cast<String, dynamic>(),
            ],
            metrics: aiSettings.requireValue['metrics'] as Map<String, dynamic>?,
            jobs: [
              for (final job in ((system?.valueOrNull?['jobs']) as List? ?? const []))
                if (job is Map) job.cast<String, dynamic>(),
            ],
            now: DateTime.now(),
          );
    final health = <_TileData>[
      if (system != null) _systemTile(system),
      // Shown only when AI drafting is off, over budget, or its job is failing.
      if (aiProblems.isNotEmpty)
        _TileData.problem(
          'AI drafting',
          aiProblems.take(2).join(' · '),
          Icons.auto_awesome_outlined,
          _Count.value(aiProblems.length),
          'System Status',
        ),
      if (dq != null && canOpen('Scrape Diff Review'))
        _TileData.problem(
          'Scraper failures · 7 days',
          'Issuer pages that could not be read',
          Icons.language_outlined,
          dqCount('scrape_failures_7d'),
          'Scrape Diff Review',
        ),
      if (dq != null && canOpen('Catalogue'))
        _TileData.problem(
          'Cards not verified · 180 days',
          'Published cards due for a re-check',
          Icons.hourglass_bottom_outlined,
          dqCount('cards_stale_180d'),
          'Catalogue',
          severe: false,
        ),
      if (audits != null) _auditTile(audits),
    ];

    final catalogue = <_TileData>[
      if (dq != null && canOpen('Catalogue'))
        _TileData.stat(
          'Published cards',
          'Visible to PandaPay users',
          Icons.credit_card_outlined,
          dqCount('cards_published'),
          'Catalogue',
        ),
      if (dq != null && canOpen('Merchants')) ...[
        _TileData.stat(
          'Published merchants',
          _ofTotal(dq, 'merchants_published', 'merchants_total'),
          Icons.storefront_outlined,
          dqCount('merchants_published'),
          'Merchants',
        ),
        _TileData.stat(
          'High-confidence merchants',
          'High or operator-verified confidence',
          Icons.verified_outlined,
          dqCount('merchants_high_conf'),
          'Merchants',
        ),
        _TileData.stat(
          'Merchant locations',
          'Mapped store locations',
          Icons.place_outlined,
          dqCount('locations_total'),
          'Merchants',
        ),
      ],
    ];

    void refreshAll() {
      if (dq != null) ref.invalidate(dataQualityDashboardProvider);
      if (audits != null) ref.invalidate(anonymizationAuditRunsProvider);
      if (system != null) ref.invalidate(systemStatusProvider);
      if (smsRules != null) _SmsRuleBacklog.invalidate(ref);
      if (learning != null) ref.invalidate(smsLearningSummaryProvider);
      if (aiSettings != null) ref.invalidate(smsAiSettingsProvider);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return RefreshIndicator(
          onRefresh: () async => refreshAll(),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _Hero(
                identity: identity,
                backlog: _Count.sum(attention.map((t) => t.count)),
                onRefresh: refreshAll,
                compact: width < 640,
              ),
              if (attention.isNotEmpty) ...[
                const _SectionHeader(
                  title: 'Needs attention',
                  subtitle:
                      'Queues waiting for a person. Open a tile to work through it.',
                ),
                _TileGrid(tiles: attention, width: width, onOpen: onOpen),
              ],
              if (health.isNotEmpty) ...[
                const _SectionHeader(
                  title: 'Health',
                  subtitle:
                      'Signals that something upstream may be failing or out of date.',
                ),
                _TileGrid(tiles: health, width: width, onOpen: onOpen),
              ],
              if (catalogue.isNotEmpty) ...[
                const _SectionHeader(
                  title: 'Catalogue at a glance',
                  subtitle: 'Current totals. Trends are not recorded yet.',
                ),
                _TileGrid(tiles: catalogue, width: width, onOpen: onOpen),
              ],
              if (attention.isEmpty && health.isEmpty && catalogue.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 32),
                  child: AdminEmptyState(
                    icon: Icons.lock_outline,
                    title: 'Nothing to show for this role',
                    message:
                        'Your role cannot read any operational queues. Ask an owner if you need more access.',
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Failed endpoint checks, an unreachable database, and failed or overdue
  /// scheduled jobs, as reported by the system status endpoint.
  static _TileData _systemTile(AsyncValue<Map<String, dynamic>> status) {
    final data = status.valueOrNull;
    if (data == null || data['services'] is! List) {
      return _TileData.problem(
        'Service problems',
        'Servers, database and scheduled jobs',
        Icons.dns_outlined,
        status.isLoading ? const _Count.loading() : const _Count.failed(),
        'System Status',
      );
    }
    final problems = <String>[
      if ((data['database'] as Map?)?['ok'] != true) 'Database',
      for (final c in (data['checks'] as List? ?? const []).whereType<Map>())
        if (c['ok'] != true) '${c['key']} check',
      for (final j in (data['jobs'] as List? ?? const []).whereType<Map>())
        if (j['state'] == 'failed' || j['state'] == 'overdue') '${j['name']}',
    ];
    return _TileData.problem(
      'Service problems',
      problems.isEmpty
          ? 'Every check is passing'
          : problems.take(2).join(' · ') +
                (problems.length > 2 ? ' · +${problems.length - 2}' : ''),
      Icons.dns_outlined,
      _Count.value(problems.length),
      'System Status',
    );
  }

  static _TileData _auditTile(AsyncValue<List<Map<String, dynamic>>> runs) {
    return runs.when(
      loading: () => const _TileData(
        label: 'Privacy audit',
        caption: 'Latest anonymization check',
        icon: Icons.privacy_tip_outlined,
        count: _Count.loading(),
        destination: 'Anonymization Audit',
        tone: _Tone.neutral,
      ),
      error: (_, _) => const _TileData(
        label: 'Privacy audit',
        caption: 'Could not load audit history',
        icon: Icons.privacy_tip_outlined,
        count: _Count.failed(),
        destination: 'Anonymization Audit',
        tone: _Tone.neutral,
      ),
      data: (list) {
        if (list.isEmpty) {
          return const _TileData(
            label: 'Privacy audit',
            caption: 'No audit has been run in this environment',
            icon: Icons.privacy_tip_outlined,
            count: _Count.text('None'),
            destination: 'Anonymization Audit',
            tone: _Tone.attention,
          );
        }
        final latest = list.first;
        final passed = latest['passed'] == true;
        final ranAt = DateTime.tryParse('${latest['ran_at']}');
        return _TileData(
          label: 'Privacy audit',
          caption:
              '${latest['checks_failed'] ?? 0} of ${latest['checks_total'] ?? 0} checks failed'
              '${ranAt == null ? '' : ' · ${formatAgo(ranAt)}'}',
          icon: Icons.privacy_tip_outlined,
          count: _Count.text(passed ? 'Passed' : 'Failed'),
          destination: 'Anonymization Audit',
          tone: passed ? _Tone.good : _Tone.bad,
        );
      },
    );
  }

  static String _ofTotal(
    AsyncValue<Map<String, dynamic>?>? dq,
    String part,
    String total,
  ) {
    final d = dq?.valueOrNull;
    final t = _asInt(d?[total]);
    return t == null ? 'Merchants users can see' : 'of $t merchants submitted';
  }
}

/// Pending SMS rule decisions across the four review lists the SMS Rule
/// Approvals screen shows. Each list is capped by the API, so a full list
/// is reported as "N+" rather than as an exact total.
class _SmsRuleBacklog {
  const _SmsRuleBacklog(this.count, this.caption);

  final _Count count;
  final String caption;

  static const _caps = {'category': 500, 'parser': 200};

  static _SmsRuleBacklog from(WidgetRef ref) {
    final lists = <String, AsyncValue<List<Map<String, dynamic>>>>{
      'category': ref.watch(smsCategoryProposalsProvider),
      'parser': ref.watch(smsParserProposalsProvider),
    };
    if (lists.values.any((l) => l.isLoading && !l.hasValue)) {
      return const _SmsRuleBacklog(
        _Count.loading(),
        'Category and parser rule reviews',
      );
    }
    var total = 0;
    var atLeast = false;
    var failed = 0;
    final parts = <String>[];
    lists.forEach((key, async) {
      final list = async.valueOrNull;
      if (list == null) {
        failed++;
        return;
      }
      if (list.length >= _caps[key]!) atLeast = true;
      final pending = list.where((p) => _isPending(key, p)).length;
      total += pending;
      if (pending > 0) parts.add('$pending ${_names[key]}');
    });
    if (failed == lists.length) {
      return const _SmsRuleBacklog(
        _Count.failed(),
        'Could not load the review lists',
      );
    }
    final caption = failed > 0
        ? 'Some review lists could not be loaded'
        : parts.isEmpty
        ? 'Category and parser rule reviews'
        : parts.join(' · ');
    return _SmsRuleBacklog(
      _Count.value(total, atLeast: atLeast || failed > 0),
      caption,
    );
  }

  static const _names = {'category': 'category', 'parser': 'parser'};

  // Mirrors each review card's own "can still be decided" rule.
  static bool _isPending(String key, Map<String, dynamic> p) =>
      p['status'] == null || p['status'] == 'pending';

  static void invalidate(WidgetRef ref) {
    ref.invalidate(smsCategoryProposalsProvider);
    ref.invalidate(smsParserProposalsProvider);
  }
}

int? _asInt(Object? value) => switch (value) {
  final num n => n.toInt(),
  final String s => int.tryParse(s),
  _ => null,
};

/// A displayable count: loading, failed, an exact or lower-bound number,
/// or a short status word.
class _Count {
  const _Count.value(int this.value, {this.atLeast = false})
    : text = null,
      loading = false,
      failed = false;
  const _Count.loading()
    : value = null,
      text = null,
      atLeast = false,
      loading = true,
      failed = false;
  const _Count.failed()
    : value = null,
      text = null,
      atLeast = false,
      loading = false,
      failed = true;
  const _Count.text(String this.text)
    : value = null,
      atLeast = false,
      loading = false,
      failed = false;

  final int? value;
  final String? text;
  final bool atLeast;
  final bool loading;
  final bool failed;

  static _Count fromAsync<T>(AsyncValue<T>? async, Object? Function(T) pick) {
    if (async == null || (async.isLoading && !async.hasValue)) {
      return const _Count.loading();
    }
    if (!async.hasValue) return const _Count.failed();
    final n = _asInt(pick(async.requireValue));
    return n == null ? const _Count.failed() : _Count.value(n);
  }

  static _Count sum(Iterable<_Count> counts) {
    var total = 0;
    var atLeast = false;
    var any = false;
    for (final c in counts) {
      if (c.loading) return const _Count.loading();
      if (c.value == null) {
        atLeast = true;
        continue;
      }
      any = true;
      total += c.value!;
      atLeast = atLeast || c.atLeast;
    }
    return any ? _Count.value(total, atLeast: atLeast) : const _Count.failed();
  }

  String get display {
    if (loading) return '…';
    if (failed) return '—';
    if (text != null) return text!;
    return '$value${atLeast ? '+' : ''}';
  }
}

enum _Tone { neutral, attention, bad, good }

class _TileData {
  const _TileData({
    required this.label,
    required this.caption,
    required this.icon,
    required this.count,
    required this.destination,
    required this.tone,
  });

  /// A queue: amber when something waits (clay when it is urgent work).
  factory _TileData.queue(
    String label,
    String caption,
    IconData icon,
    _Count count,
    String destination, {
    bool urgent = true,
  }) => _TileData(
    label: label,
    caption: count.failed ? 'Could not load this count' : caption,
    icon: icon,
    count: count,
    destination: destination,
    tone: count.value == null
        ? _Tone.neutral
        : count.value! > 0
        ? (urgent ? _Tone.attention : _Tone.neutral)
        : _Tone.good,
  );

  /// A failure signal: any non-zero value is a problem.
  factory _TileData.problem(
    String label,
    String caption,
    IconData icon,
    _Count count,
    String destination, {
    bool severe = true,
  }) => _TileData(
    label: label,
    caption: count.failed ? 'Could not load this signal' : caption,
    icon: icon,
    count: count,
    destination: destination,
    tone: count.value == null
        ? _Tone.neutral
        : count.value! > 0
        ? (severe ? _Tone.bad : _Tone.attention)
        : _Tone.good,
  );

  factory _TileData.stat(
    String label,
    String caption,
    IconData icon,
    _Count count,
    String destination,
  ) => _TileData(
    label: label,
    caption: count.failed ? 'Could not load this total' : caption,
    icon: icon,
    count: count,
    destination: destination,
    tone: _Tone.neutral,
  );

  final String label;
  final String caption;
  final IconData icon;
  final _Count count;
  final String destination;
  final _Tone tone;
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.identity,
    required this.backlog,
    required this.onRefresh,
    required this.compact,
  });

  final AdminIdentity identity;
  final _Count backlog;
  final VoidCallback onRefresh;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final env = identity.environment;
    final who = [
      _titleCase(identity.role),
      if (identity.email != null) identity.email!,
    ].join(' · ');

    final summary = Column(
      crossAxisAlignment: compact
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.end,
      children: [
        Text(
          backlog.display,
          style: const TextStyle(
            color: AdminColors.lime,
            fontSize: 44,
            height: 1,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          backlog.value == 0 ? 'nothing waiting for review' : 'awaiting review',
          style: const TextStyle(
            color: AdminColors.onSlateSubtle,
            fontSize: 13,
          ),
        ),
      ],
    );

    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: env.tone == AdminColors.jade
                    ? AdminColors.lime
                    : env.tone,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '${env.label.toUpperCase()} WORKSPACE',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AdminColors.onSlateSubtle,
                  fontSize: 11,
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'Today\u2019s operations',
          style: TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          who,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AdminColors.onSlateMuted, fontSize: 13),
        ),
        const SizedBox(height: 14),
        TextButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Refresh overview'),
          style: TextButton.styleFrom(
            foregroundColor: AdminColors.lime,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            backgroundColor: AdminColors.slateRaised,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(compact ? 18 : 26),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AdminColors.slateRaised, AdminColors.slate],
        ),
        borderRadius: BorderRadius.circular(20),
        border: env == AdminEnvironment.local
            ? null
            : Border.all(color: env.tone, width: 2),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [heading, const SizedBox(height: 18), summary],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: heading),
                const SizedBox(width: 24),
                summary,
              ],
            ),
    );
  }

  static String _titleCase(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 22, 2, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _TileGrid extends StatelessWidget {
  const _TileGrid({
    required this.tiles,
    required this.width,
    required this.onOpen,
  });

  final List<_TileData> tiles;
  final double width;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    const gap = 12.0;
    final columns = width >= 1100
        ? 4
        : width >= 760
        ? 3
        : width >= 460
        ? 2
        : 1;
    final tileWidth = (width - gap * (columns - 1)) / columns;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final tile in tiles)
          SizedBox(
            width: tileWidth,
            child: _Tile(data: tile, onTap: () => onOpen(tile.destination)),
          ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.data, required this.onTap});

  final _TileData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (accent, iconBg, iconFg) = switch (data.tone) {
      _Tone.bad => (AdminColors.clay, AdminColors.clay, Colors.white),
      _Tone.attention => (
        AdminColors.amber,
        AdminColors.slate,
        AdminColors.lime,
      ),
      _Tone.good => (AdminColors.jade, AdminColors.wash, AdminColors.jade),
      _Tone.neutral => (null, AdminColors.slate, AdminColors.lime),
    };
    final valueColor = switch (data.tone) {
      _Tone.bad => AdminColors.clayInk,
      _Tone.good =>
        data.count.text != null ? AdminColors.jade : AdminColors.muted,
      _ => AdminColors.ink,
    };
    return Semantics(
      button: true,
      label: '${data.label}: ${data.count.display}. ${data.caption}',
      excludeSemantics: true,
      child: Material(
        color: AdminColors.paper,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            constraints: const BoxConstraints(minHeight: 132),
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AdminColors.hairline),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (accent != null)
                  Container(
                    width: 3,
                    height: 100,
                    margin: const EdgeInsets.only(right: 12),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: iconBg,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(data.icon, size: 18, color: iconFg),
                          ),
                          const Spacer(),
                          const Icon(
                            Icons.chevron_right,
                            size: 20,
                            color: AdminColors.muted,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        data.count.display,
                        style: TextStyle(
                          color: valueColor,
                          fontSize: 28,
                          height: 1.05,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        data.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        data.caption,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
