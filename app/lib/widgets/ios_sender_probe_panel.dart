import 'dart:convert';

import 'package:flutter/material.dart';

class IosSenderProbePanel extends StatelessWidget {
  final List<Map<String, Object?>> events;
  final Map<String, Object?>? liveInput, historyInput, comparison;
  final VoidCallback? onCheckToday, onCheckLiveDay;
  final bool showChecks;
  const IosSenderProbePanel({
    super.key,
    required this.events,
    this.liveInput,
    this.historyInput,
    this.comparison,
    this.onCheckToday,
    this.onCheckLiveDay,
    this.showChecks = false,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Sender input vs inference',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const Text(
        'Compare receiver inputs without changing the main app. A receiver tagged live can also be called from a history shortcut. Guesses stay separate.',
      ),
      if (showChecks || onCheckToday != null) ...[
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onCheckToday,
          icon: const Icon(Icons.today),
          label: const Text('Check today’s history'),
        ),
        OutlinedButton.icon(
          onPressed: onCheckLiveDay,
          icon: const Icon(Icons.compare_arrows),
          label: const Text('Check latest received message'),
        ),
        const Text(
          'Uses the selected probe shortcut below. No Quick Look steps needed.',
        ),
      ],
      if (liveInput != null)
        _capture(context, 'Latest single-message receiver', liveInput!),
      if (historyInput != null)
        _capture(context, 'Latest range receiver', historyInput!),
      if (historyInput != null)
        const Text(
          'saved_without_sender is an action result. The sender value is shown above.',
        ),
      if (comparison != null && comparison!['status'] != 'not_started')
        _comparison(context, comparison!),
      if (events.isEmpty) const Text('No sender comparison received yet.'),
      if (events.isNotEmpty) _event(context, events.first),
      if (events.length > 1)
        ExpansionTile(
          key: const PageStorageKey('earlier-sender-comparisons'),
          title: Text('Earlier comparisons (${events.length - 1})'),
          children: [
            for (final event in events.skip(1)) _event(context, event),
          ],
        ),
    ],
  );

  Widget _capture(
    BuildContext context,
    String title,
    Map<String, Object?> input,
  ) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('Sender received: ${input['capturedSender'] ?? 'Not supplied'}'),
          Text('Receiver: ${input['receiver']}'),
          Text('Input source: ${input['input_mode'] ?? 'native_handoff'}'),
          if (input['sender_conversion'] != null)
            Text('Sender conversion: ${input['sender_conversion']}'),
          if (input['sender_parameter_state'] != null)
            Text('Sender input state: ${input['sender_parameter_state']}'),
          Text(
            'Sender parameter: ${input['sender_parameter'] ?? 'Not reported'}',
          ),
          Text(
            'Text field: ${input['sender_text'] == null
                ? 'omitted'
                : input['sender_text'] is String && (input['sender_text'] as String).trim().isEmpty
                ? 'empty'
                : input['sender_text']}',
          ),
          Text(
            'Native value type: ${input['native_sender_runtime_type'] ?? 'Not reported'}',
          ),
          Text(
            'Receive date: ${input['original_receive_date'] ?? 'Not supplied'}',
          ),
          if (input['sender_person'] case final Map person
              when person['present'] == true)
            Text(
              'Person address: ${person['handle'] ?? 'Not supplied; name only is not an address'}',
            ),
          const SizedBox(height: 8),
          Text(
            '${input['message_body'] ?? ''}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    ),
  );

  Widget _comparison(BuildContext context, Map<String, Object?> value) {
    final title = switch (value['status']) {
      'no_live_reference' =>
        'History check started without a single-message reference',
      'waiting_for_history' => 'Waiting for matching message text from history',
      'no_matching_text' =>
        'That reference message text was not found in this history run',
      'ambiguous_text' =>
        'Multiple history messages have that text; no sender chosen',
      'history_missing_sender' =>
        'Receiver comparison: range sender is missing',
      'same_sender' => 'Receiver comparison: sender values match',
      'different_sender' => 'Receiver comparison: sender values differ',
      _ => 'Sender comparison pending',
    };
    final live = value['live'] as Map?;
    final history = value['history'] as Map?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (live != null)
              Text(
                'Single-message sender: ${live['capturedSender'] ?? 'Not supplied'}',
              ),
            if (history != null)
              Text(
                'Range sender: ${history['capturedSender'] ?? 'Not supplied'}',
              ),
            if (history != null)
              const Text(
                'Compared by exact message text. These inputs stay separate; no sender is filled in.',
              ),
          ],
        ),
      ),
    );
  }

  Widget _event(BuildContext context, Map<String, Object?> event) => Card(
    key: ValueKey(event['id']),
    child: ExpansionTile(
      key: PageStorageKey('sender-event-${event['id']}'),
      title: Text(
        '${event['origin']} receiver · ${event['senderPresent'] == true ? 'sender supplied' : 'sender address missing'}',
      ),
      subtitle: Text('${event['receivedAt'] ?? 'Date unavailable'}'),
      children: [
        _json(context, 'Input received from Shortcut (raw)', event['input']),
        _json(context, 'Without sender inference', event['direct']),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Body-based guess for comparison. This is not a captured sender.',
          ),
        ),
        _json(context, 'Body-only inference comparison', event['inferred']),
      ],
    ),
  );

  Widget _json(BuildContext context, String title, Object? value) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SelectableText(
          key: PageStorageKey('sender-json-$title'),
          const JsonEncoder.withIndent('  ').convert(value),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ],
    ),
  );
}
