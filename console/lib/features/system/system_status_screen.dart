import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/admin_design.dart';
import '../../app/providers.dart';
import '../../app/time_format.dart';

/// Which servers exist, which code they run, and whether they are healthy.
/// Read-only; data comes from GET /admin/system/status.
class SystemStatusScreen extends ConsumerWidget {
  const SystemStatusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(systemStatusProvider);
    return status.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AdminLoadError(
        title: 'System status is unavailable',
        error: error,
        onRetry: () => ref.invalidate(systemStatusProvider),
      ),
      data: (data) {
        if (data['services'] is! List) {
          return const AdminEmptyState(
            icon: Icons.dns_outlined,
            title: 'No status reported',
            message: 'The admin API did not return a system status.',
          );
        }
        final report = _StatusReport.from(data);
        return ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _SummaryBanner(report: report),
            const SizedBox(height: 16),
            _ReleaseCard(release: report.release, database: report.database),
            _Section(
              title: 'Services',
              subtitle:
                  'Programs PandaPay runs. In production they are containers on one virtual machine; the database is hosted separately.',
              child: _Panel(
                children: [
                  for (final row in report.services) _ServiceRow(row: row),
                ],
              ),
            ),
            if (report.jobs.isNotEmpty)
              _Section(
                title: 'Scheduled jobs',
                subtitle:
                    'Work that should run on a timer. Overdue means it missed its window.',
                child: _Panel(
                  children: [for (final job in report.jobs) _JobRow(job: job)],
                ),
              ),
            if (report.extraChecks.isNotEmpty)
              _Section(
                title: 'Other endpoint checks',
                subtitle: 'Extra health URLs configured for this admin API.',
                child: _Panel(
                  children: [
                    for (final c in report.extraChecks)
                      _StatusRow(
                        icon: Icons.http,
                        title: '${c['key']}',
                        detail: '${c['host']}',
                        state: _checkState(c),
                        stateLabel: _checkLabel(c),
                      ),
                  ],
                ),
              ),
            _Section(
              title: 'Code branches',
              subtitle: report.repository == null
                  ? 'Deployed builds carry only their own commit; the branch list comes from a git checkout.'
                  : '${report.repository!['total']} branches in this computer’s checkout, compared with GitHub as of the last fetch.',
              child: report.repository == null
                  ? const _Panel(
                      children: [
                        _StatusRow(
                          icon: Icons.account_tree_outlined,
                          title: 'Branch list not available here',
                          detail:
                              'Run the admin API from a checkout, or see branches on GitHub.',
                          state: _State.neutral,
                          stateLabel: 'Not available',
                        ),
                      ],
                    )
                  : _BranchList(repository: report.repository!),
            ),
          ],
        );
      },
    );
  }
}

enum _State { ok, warn, bad, neutral }

_State _checkState(Map c) => c['ok'] == true ? _State.ok : _State.bad;

String _checkLabel(Map c) {
  if (c['ok'] == true) return 'Up · ${c['latencyMs']} ms';
  if (c['error'] == 'timeout') return 'No answer in 3 s';
  if (c['httpStatus'] != null) return 'Error ${c['httpStatus']}';
  return 'Unreachable';
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

class _ServiceStatus {
  const _ServiceStatus(this.service, this.state, this.label, this.detail);
  final Map service;
  final _State state;
  final String label;
  final String? detail;
}

class _StatusReport {
  _StatusReport({
    required this.release,
    required this.database,
    required this.services,
    required this.jobs,
    required this.extraChecks,
    required this.repository,
    required this.problems,
    required this.generatedAt,
  });

  final Map<String, dynamic> release;
  final Map<String, dynamic> database;
  final List<_ServiceStatus> services;
  final List<Map> jobs;
  final List<Map> extraChecks;
  final Map<String, dynamic>? repository;
  final List<String> problems;
  final DateTime? generatedAt;

  static _StatusReport from(Map<String, dynamic> data) {
    final checks = (data['checks'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final jobs = (data['jobs'] as List? ?? const []).whereType<Map>().toList();
    final database =
        (data['database'] as Map?)?.cast<String, dynamic>() ?? const {};
    final jobsByKey = {for (final j in jobs) j['key']: j};
    final checksByKey = {for (final c in checks) c['key']: c};
    final serviceKeys = <Object?>{};

    _ServiceStatus statusFor(Map s) {
      serviceKeys.add(s['key']);
      final health = '${s['health']}';
      if (health == 'self') {
        return _ServiceStatus(s, _State.ok, 'Up', 'Serving this page');
      }
      if (health == 'database') {
        return database['ok'] == true
            ? _ServiceStatus(
                s,
                _State.ok,
                'Up · ${database['latencyMs']} ms',
                '${database['version']}',
              )
            : _ServiceStatus(s, _State.bad, 'Unreachable', null);
      }
      if (health == 'probe') {
        final c = checksByKey[s['key']];
        if (c == null) {
          return _ServiceStatus(
            s,
            _State.neutral,
            'Not checked',
            'No health URL configured',
          );
        }
        return _ServiceStatus(
          s,
          _checkState(c),
          _checkLabel(c),
          '${c['host']}',
        );
      }
      if (health.startsWith('job:')) {
        final j = jobsByKey[health.substring(4)];
        if (j == null) {
          return _ServiceStatus(
            s,
            _State.neutral,
            'Hidden for your role',
            null,
          );
        }
        final (state, label) = _jobLabel(j);
        return _ServiceStatus(s, state, label, null);
      }
      return switch (s['runs']) {
        'per_deploy' => _ServiceStatus(
          s,
          _State.neutral,
          'Runs during deploys',
          null,
        ),
        'manual' => _ServiceStatus(s, _State.neutral, 'Manual only', null),
        _ => _ServiceStatus(s, _State.neutral, 'Not monitored yet', null),
      };
    }

    final services = [
      for (final s in (data['services'] as List).whereType<Map>()) statusFor(s),
    ];
    final problems = <String>[
      for (final row in services)
        if (row.state == _State.bad || row.state == _State.warn)
          '${row.service['name']}',
      for (final j in jobs)
        if (!serviceKeys.contains(j['key']) &&
            (j['state'] == 'failed' || j['state'] == 'overdue'))
          '${j['name']}',
    ];
    return _StatusReport(
      release: (data['release'] as Map?)?.cast<String, dynamic>() ?? const {},
      database: database,
      services: services,
      jobs: jobs,
      extraChecks: [
        for (final c in checks)
          if (!serviceKeys.contains(c['key'])) c,
      ],
      repository: (data['repository'] as Map?)?.cast<String, dynamic>(),
      problems: problems,
      generatedAt: _date(data['generatedAt']),
    );
  }
}

(_State, String) _jobLabel(Map j) {
  final last = _date(j['lastRunAt']);
  final ago = last == null ? '' : formatAgo(last);
  return switch (j['state']) {
    'ok' => (_State.ok, 'Ran $ago'),
    'overdue' => (_State.warn, 'Overdue · last ran $ago'),
    'failed' => (_State.bad, 'Last run failed · $ago'),
    'never' => (_State.warn, 'No runs recorded'),
    _ => (_State.neutral, 'Could not read history'),
  };
}

class _SummaryBanner extends StatelessWidget {
  const _SummaryBanner({required this.report});
  final _StatusReport report;

  @override
  Widget build(BuildContext context) {
    final healthy = report.problems.isEmpty;
    final tone = healthy ? AdminColors.jade : AdminColors.clay;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AdminColors.slate,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: healthy ? AdminColors.lime : tone,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              healthy ? Icons.check_rounded : Icons.priority_high_rounded,
              color: healthy ? AdminColors.slate : Colors.white,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  healthy
                      ? 'All monitored systems are healthy'
                      : '${report.problems.length} need${report.problems.length == 1 ? 's' : ''} attention',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  healthy
                      ? 'Checked ${report.generatedAt == null ? 'just now' : formatAgo(report.generatedAt!)}. Services marked "not monitored" have no health signal yet.'
                      : report.problems.join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AdminColors.onSlateSubtle,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({required this.release, required this.database});
  final Map<String, dynamic> release;
  final Map<String, dynamic> database;

  @override
  Widget build(BuildContext context) {
    final commit = '${release['commit'] ?? ''}';
    final started = _date(release['startedAt']);
    final deployed = _date(release['deployedAt']);
    final source = switch (release['source']) {
      'deploy' => 'Deployed build',
      'checkout' => 'Local checkout',
      _ => 'Unknown build',
    };
    final facts = <(String, String)>[
      ('Code', source),
      ('Branch', '${release['branch'] ?? '—'}'),
      (
        'Commit',
        commit.isEmpty
            ? '—'
            : commit.substring(0, commit.length < 12 ? commit.length : 12),
      ),
      if (deployed != null) ('Deployed', formatAgo(deployed)),
      (
        'Admin API up for',
        started == null ? '—' : formatAgo(started).replaceAll(' ago', ''),
      ),
      ('Runtime', '${release['runtime'] ?? '—'}'),
      (
        'Database',
        database['ok'] == true ? '${database['version']}' : 'Unreachable',
      ),
    ];
    return _Section(
      title: 'This environment',
      subtitle:
          'The code this admin API is running and the database it talks to.',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AdminColors.paper,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AdminColors.hairline),
        ),
        child: Wrap(
          spacing: 28,
          runSpacing: 14,
          children: [
            for (final (label, value) in facts)
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 120, maxWidth: 280),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700,
                        color: AdminColors.muted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      value,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AdminColors.paper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AdminColors.hairline),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.state,
    required this.stateLabel,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final _State state;
  final String stateLabel;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _State.ok => AdminColors.jade,
      _State.warn => AdminColors.amber,
      _State.bad => AdminColors.clay,
      _State.neutral => AdminColors.muted,
    };
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              stateLabel,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: state == _State.neutral ? AdminColors.muted : color,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 560;
        final text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            if (detail != null) ...[
              const SizedBox(height: 2),
              Text(detail!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AdminColors.slate,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 17, color: AdminColors.lime),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: narrow
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [text, const SizedBox(height: 8), chip],
                      )
                    : Row(
                        children: [
                          Expanded(child: text),
                          const SizedBox(width: 12),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 260),
                            child: chip,
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({required this.row});
  final _ServiceStatus row;

  static const _icons = <String, IconData>{
    'api': Icons.cloud_outlined,
    'auth': Icons.lock_outline,
    'postgres': Icons.storage_outlined,
    'rewards-worker': Icons.redeem_outlined,
    'backup': Icons.backup_outlined,
    'admin-gateway': Icons.shield_outlined,
    'admin-api': Icons.admin_panel_settings_outlined,
  };

  static const _runs = <String, String>{
    'always_on': 'Always on',
    'per_deploy': 'Once per deploy',
    'manual': 'Manual tool',
    'hosted': 'Hosted separately',
    'admin_only': 'Private admin',
  };

  @override
  Widget build(BuildContext context) {
    final runs = _runs[row.service['runs']];
    final purpose = [
      ?runs,
      '${row.service['purpose'] ?? ''}',
    ].join(' · ');
    return _StatusRow(
      icon: _icons[row.service['key']] ?? Icons.settings_outlined,
      title: '${row.service['name']}',
      detail: row.detail == null ? purpose : '$purpose · ${row.detail}',
      state: row.state,
      stateLabel: row.label,
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job});
  final Map job;

  @override
  Widget build(BuildContext context) {
    final (state, label) = _jobLabel(job);
    final every = (job['expectedEveryHours'] as num?)?.toInt();
    final success = _date(job['lastSuccessAt']);
    return _StatusRow(
      icon: Icons.schedule_outlined,
      title: '${job['name']}',
      detail: [
        if (every != null)
          'Expected at least every ${every >= 48 ? '${(every / 24).round()} days' : '$every h'}',
        if (success != null) 'last success ${formatAgo(success)}',
      ].join(' · '),
      state: state,
      stateLabel: label,
    );
  }
}

class _BranchList extends StatefulWidget {
  const _BranchList({required this.repository});
  final Map<String, dynamic> repository;

  @override
  State<_BranchList> createState() => _BranchListState();
}

class _BranchListState extends State<_BranchList> {
  String _filter = '';

  static const _locationLabels = {
    'in_sync': ('On GitHub, in sync', _State.ok),
    'differs': ('Differs from GitHub', _State.warn),
    'local_only': ('Not pushed', _State.neutral),
    'remote_only': ('Only on GitHub', _State.neutral),
  };

  @override
  Widget build(BuildContext context) {
    final all = (widget.repository['branches'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final query = _filter.trim().toLowerCase();
    final shown = query.isEmpty
        ? all
        : all
              .where((b) => '${b['name']}'.toLowerCase().contains(query))
              .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Filter branches',
          ),
          onChanged: (value) => setState(() => _filter = value),
        ),
        const SizedBox(height: 10),
        _Panel(
          children: [
            if (shown.isEmpty)
              const _StatusRow(
                icon: Icons.account_tree_outlined,
                title: 'No matching branches',
                detail: null,
                state: _State.neutral,
                stateLabel: '0',
              ),
            for (final b in shown.take(60))
              Builder(
                builder: (context) {
                  final (label, state) =
                      _locationLabels[b['location']] ??
                      ('Unknown', _State.neutral);
                  final updated = _date(b['updatedAt']);
                  return _StatusRow(
                    icon: b['current'] == true
                        ? Icons.radio_button_checked
                        : Icons.account_tree_outlined,
                    title:
                        '${b['name']}${b['current'] == true ? '  (current)' : ''}',
                    detail: [
                      '${b['commit']}',
                      if (updated != null) formatAgo(updated),
                      if (b['lastAction'] != null) '${b['lastAction']}',
                    ].join(' · '),
                    state: state,
                    stateLabel: label,
                  );
                },
              ),
          ],
        ),
        if (shown.length > 60)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Showing 60 of ${shown.length}. Filter to narrow the list.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
