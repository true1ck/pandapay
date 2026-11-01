import 'dart:convert';
import 'package:flutter/material.dart';

class IosBodyEvidencePanel extends StatelessWidget {
  final Map<String, Object?> snapshot;
  final String? replayStatus;
  const IosBodyEvidencePanel({
    super.key,
    required this.snapshot,
    this.replayStatus,
  });

  @override
  Widget build(BuildContext context) {
    final records = (snapshot['records'] as List).cast<Map<String, Object?>>();
    final extracted = records.where(
      (r) =>
          r['kind'] == 'transaction_candidate' ||
          r['kind'] == 'payment_request',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Extracted message facts',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (replayStatus != null) Text(replayStatus!),
        Text(
          '${snapshot['unique_message_inputs']} messages · ${snapshot['transaction_candidates']} transaction candidates · ${snapshot['payment_requests']} payment requests',
        ),
        const Text(
          'Sender is optional for extraction. These are previews, not posted spending.',
        ),
        for (final record in extracted)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    record['kind'] == 'payment_request'
                        ? 'Payment requested · completion unconfirmed'
                        : record['captured_sender'] == null
                        ? 'Transaction extracted; sender unavailable'
                        : 'Transaction extracted; sender supplied',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (record['transaction_facts'] case final Map facts) ...[
                    Text(
                      '${facts['merchant_name'] ?? 'Merchant unavailable'} · ₹${facts['amount_inr']}',
                    ),
                    Text(
                      'Instrument: ${facts['instrument']} · Method: ${facts['payment_method'] ?? 'Not stated'}',
                    ),
                    if (facts['card_last4'] != null)
                      Text('Card ending ${facts['card_last4']}'),
                    if (facts['card_name'] != null)
                      Text('Saved card: ${facts['card_name']}'),
                    Text('Transaction date: ${facts['occurred_at']}'),
                  ],
                  if (record['request_facts'] case final Map request) ...[
                    Text(
                      '${request['requester']} · ₹${request['requested_amount_inr']}',
                    ),
                    Text(
                      'Payment app named: ${request['payment_app'] ?? 'Not stated'}',
                    ),
                    const Text('Spending added: ₹0'),
                  ],
                  Text(
                    'Captured sender: ${record['captured_sender'] ?? 'Unavailable'}',
                  ),
                  if (record['issuer_named_in_body'] != null)
                    Text(
                      'Issuer named in SMS: ${record['issuer_named_in_body']}',
                    ),
                  Text('SMS received: ${record['original_receive_date']}'),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Extraction input and output (JSON)'),
                    children: [
                      SelectableText(
                        const JsonEncoder.withIndent('  ').convert(record),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (records.isNotEmpty)
          ExpansionTile(
            title: const Text('All captured message inputs'),
            children: [
              for (final record in records)
                ListTile(
                  title: Text(record['kind'] as String),
                  subtitle: Text(record['message_body'] as String),
                ),
            ],
          ),
        const Divider(height: 28),
      ],
    );
  }
}
