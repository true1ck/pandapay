import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-9.1: latest result + full history over `anonymization_audit_runs`.
/// The 6-check function itself (`pandapay.run_anonymization_audit()`) is
/// not new here — see db/supabase/migrations/0010_functions_and_views.sql.
/// AD-9.2 (CI deploy-blocking gate) lives in
/// .github/workflows/anonymization-audit.yml, not in this screen — this
/// screen is for humans reviewing history, not the enforcement mechanism.
class AnonymizationAuditScreen extends ConsumerStatefulWidget {
  const AnonymizationAuditScreen({super.key});

  @override
  ConsumerState<AnonymizationAuditScreen> createState() => _AnonymizationAuditScreenState();
}

class _AnonymizationAuditScreenState extends ConsumerState<AnonymizationAuditScreen> {
  bool _running = false;
  String? _error;

  Future<void> _runNow() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await ref.read(adminApiProvider)!.runAnonymizationAuditNow();
      ref.invalidate(anonymizationAuditRunsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final runs = ref.watch(anonymizationAuditRunsProvider);
    return runs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load audit runs: $err')),
      data: (rows) {
        final latest = rows.isEmpty ? null : rows.first;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: latest == null
                        ? const Text('No audit runs yet.')
                        : _LatestResultCard(latest),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _running ? null : _runNow,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(_running ? 'Running...' : 'Run now'),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
            const Divider(height: 1),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('History will appear here after the first run.'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: rows.length,
                      itemBuilder: (context, i) => _RunTile(rows[i]),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _LatestResultCard extends StatelessWidget {
  final Map<String, dynamic> run;
  const _LatestResultCard(this.run);

  @override
  Widget build(BuildContext context) {
    final passed = run['passed'] == true;
    return Card(
      color: passed
          ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.4)
          : Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(passed ? Icons.check_circle : Icons.error, color: passed ? Colors.green : Colors.red),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(passed ? 'Latest: PASSED' : 'Latest: FAILED',
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    '${run['checks_total']} checks, ${run['checks_failed']} failed · '
                    '${run['ran_at']} · sha: ${run['git_sha'] ?? '—'} · by: ${run['run_by']}',
                    style: const TextStyle(fontSize: 12),
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

class _RunTile extends StatelessWidget {
  final Map<String, dynamic> run;
  const _RunTile(this.run);

  @override
  Widget build(BuildContext context) {
    final passed = run['passed'] == true;
    final findings = (run['findings'] as List?) ?? const [];
    return ListTile(
      leading: Icon(passed ? Icons.check_circle_outline : Icons.error_outline, color: passed ? Colors.green : Colors.red),
      title: Text('${run['ran_at']} — ${run['checks_failed']}/${run['checks_total']} failed'),
      subtitle: findings.isEmpty
          ? null
          : Text(findings.map((f) => '${f['check']} (${f['violations']})').join(', ')),
      trailing: Text(run['git_sha'] as String? ?? '—', style: const TextStyle(fontSize: 12)),
    );
  }
}
