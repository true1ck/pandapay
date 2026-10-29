import 'package:flutter/material.dart';
import '../data/ios_live_probe_session.dart';

/// Diagnostic metadata only until shared intake confirms a non-sensitive record.
class IosLiveProbePanel extends StatelessWidget {
  final Map<Object?, Object?> snapshot;
  final IosLiveProbeSession session;
  final VoidCallback onRefresh;
  final String? error;
  const IosLiveProbePanel({
    super.key,
    required this.snapshot,
    required this.session,
    required this.onRefresh,
    this.error,
  });
  int count(String key) => (snapshot['counts'] as Map?)?[key] as int? ?? 0;
  String date(Object? value) =>
      DateTime.tryParse('$value')?.toLocal().toString().split('.').first ??
      'Unavailable';
  String actionTitle(Object? handler) => switch (handler) {
    'text_sender' => 'Inspect Financial Message on iPhone',
    'person_sender' => 'Inspect Financial Message With Sender',
    _ => 'Unidentified single-message action',
  };
  String state(Object? value) => switch (value) {
    'pending' => 'Received → waiting for shared intake',
    'processing_error' => 'Shared intake failed → pending retry',
    'retained_new' => 'Processed → newly retained',
    'retained_existing' => 'Processed → already retained',
    'ignored' => 'Processed → ignored nonfinancial/promotion',
    'native_duplicate' => 'Rejected duplicate handoff',
    'sensitive' ||
    'rejected_sensitive' => 'Rejected sensitive/security content',
    'invalid' || 'rejected_invalid' => 'Rejected empty/invalid/oversized body',
    'missing_date_rejected' ||
    'rejected_missing_date' => 'Rejected missing original receive date',
    'capacity_rejected' => 'Rejected diagnostic capacity limit',
    'wrong_probe_bundle' => 'Rejected wrong diagnostic bundle',
    _ => 'No outcome reported',
  };
  @override
  Widget build(BuildContext context) {
    final events = (snapshot['events'] as List? ?? []).cast<Map>();
    final missingDateEvent = events
        .where((event) => event['missingDate'] == true)
        .firstOrNull;
    return Card(
      key: const Key('live-incoming-panel'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Live incoming SMS',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text(
              'Single-message Shortcut actions only · This app session',
            ),
            if (count('calls') == 0)
              const Text(
                'No incoming Shortcut handoff received in this app session',
              )
            else ...[
              Text('Last handler invoked: ${date(snapshot['lastInvokedAt'])}'),
              Text(
                'Handler calls: ${count('calls')} · Body values received: ${count('records_received')}',
              ),
              Text(
                'Pending: ${count('pending')} · Processed and acknowledged: ${count('processed')}',
              ),
              Text(
                'Newly retained: ${count('retained_new')} · Already retained: ${count('retained_existing')} · Native duplicates: ${count('native_duplicate')}',
              ),
              Text(
                'Ignored nonfinancial/promotion: ${count('ignored')} · Sensitive rejected: ${count('sensitive') + count('rejected_sensitive')}',
              ),
              Text(
                'Invalid/empty/oversized: ${count('invalid') + count('rejected_invalid')} · Capacity rejected: ${count('capacity_rejected')}',
              ),
              Text(
                'Missing original date: ${count('missing_date')} · Missing sender: ${count('missing_sender')} · Retained with inferred sender: ${count('sender_inferred')}',
              ),
              Text('Processing error attempts: ${count('processing_errors')}'),
              if (events.isNotEmpty)
                Text('Latest: ${state(events.first['state'])}'),
              if (events.isNotEmpty)
                Text('Action: ${actionTitle(events.first['handler'])}'),
              if (count('missing_date') > 0) ...[
                if (missingDateEvent != null)
                  Text(
                    'Missing Date on: ${actionTitle(missingDateEvent['handler'])}',
                  ),
                const Text(
                  'Original Date missing: choose Shortcut Input → Type: Message → Get: Date, if supplied. Do not change Type to Date. If conversion still fails, use the verified range workflow; Current Date and body dates are not receive metadata.',
                ),
              ],
              const Text(
                'The action title identifies the receiver called, not the automation or trigger that launched it.',
              ),
            ],
            const Text(
              'Trigger and input-conversion failures before the handler are UNOBSERVED here. Zero calls means this process has not observed a handoff; it does not identify the cause.',
            ),
            const Text(
              'Process-local only. Installing, restarting or clearing the probe resets this diagnostic. Original SMS receive time is separate from handler/import and processing times.',
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            OutlinedButton(
              onPressed: onRefresh,
              child: const Text('Refresh / retry live handoffs'),
            ),
            if (events.isNotEmpty)
              ExpansionTile(
                title: const Text('Recent live events (up to 30)'),
                children: [
                  for (final event in events)
                    ListTile(
                      title: Text(state(event['state'])),
                      subtitle: Text(
                        'Action: ${actionTitle(event['handler'])} (${event['handler']})\nInvoked/imported: ${date(event['invokedAt'])}\n'
                        'Original received: ${date(event['receivedAt'])} · Processed: ${date(event['processedAt'])}\n'
                        'Date missing: ${event['missingDate'] == true} · Sender missing: ${event['missingSender'] == true} · Inferred: ${event['senderInferred'] == true}',
                      ),
                    ),
                ],
              ),
            Text(
              'Live shared intake: ${session.intake.counts.captured} retained SMS · ${session.intake.transactions} transactions · ${session.intake.reviewCount} review items',
            ),
            if (session.intake.retainedInputs.isNotEmpty)
              ExpansionTile(
                title: const Text('Inspect retained live SMS and transactions'),
                children: [
                  for (final source in session.intake.retainedInputsForRun(
                    'live',
                  ))
                    ExpansionTile(
                      title: Text(
                        '${source.sender} (${source.senderInferred ? 'inferred' : source.senderEvidence})',
                      ),
                      subtitle: Text(
                        'Original received: ${date(source.date)}\nHandler/imported: ${date(source.capturedAt)}',
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(source.body),
                        ),
                      ],
                    ),
                  for (final tx in session.intake.transactionsForRun('live'))
                    ListTile(
                      title: Text(
                        '${tx['merchant_name'] ?? 'Transaction'} · ₹${tx['amount_inr'] ?? tx['amount'] ?? ''}',
                      ),
                      subtitle: Text(
                        'Parser occurrence: ${tx['occurred_at']} (may use receive date if absent in body)',
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
