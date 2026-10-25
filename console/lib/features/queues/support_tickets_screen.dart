import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// User Feedback & Support Tickets queue (H9 support_tickets).
/// Shows all feedback submitted from either the wallet page or global app settings.
class SupportTicketsScreen extends ConsumerStatefulWidget {
  const SupportTicketsScreen({super.key});

  @override
  ConsumerState<SupportTicketsScreen> createState() =>
      _SupportTicketsScreenState();
}

class _SupportTicketsScreenState extends ConsumerState<SupportTicketsScreen> {
  String _selectedState = 'all';
  String _selectedKind = 'all';

  @override
  Widget build(BuildContext context) {
    final ticketsAsync = ref.watch(supportTicketsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('User Feedback & Support Tickets'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(supportTicketsProvider),
          ),
        ],
      ),
      body: ticketsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Failed to load support tickets: $err'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => ref.invalidate(supportTicketsProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (ticketList) {
          final pendingCount =
              ticketList.where((t) => t['state'] == 'pending').length;
          final resolvedCount =
              ticketList.where((t) => t['state'] == 'resolved').length;
          final dismissedCount =
              ticketList.where((t) => t['state'] == 'dismissed').length;

          final filtered = ticketList.where((t) {
            if (_selectedState != 'all' && t['state'] != _selectedState) {
              return false;
            }
            if (_selectedKind != 'all' && t['kind'] != _selectedKind) {
              return false;
            }
            return true;
          }).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Summary and filter row
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilterChip(
                      label: Text('All (${ticketList.length})'),
                      selected: _selectedState == 'all',
                      onSelected: (_) => setState(() => _selectedState = 'all'),
                    ),
                    FilterChip(
                      label: Text('Pending ($pendingCount)'),
                      selected: _selectedState == 'pending',
                      onSelected: (_) =>
                          setState(() => _selectedState = 'pending'),
                    ),
                    FilterChip(
                      label: Text('Resolved ($resolvedCount)'),
                      selected: _selectedState == 'resolved',
                      onSelected: (_) =>
                          setState(() => _selectedState = 'resolved'),
                    ),
                    FilterChip(
                      label: Text('Dismissed ($dismissedCount)'),
                      selected: _selectedState == 'dismissed',
                      onSelected: (_) =>
                          setState(() => _selectedState = 'dismissed'),
                    ),
                    const SizedBox(width: 16),
                    DropdownButton<String>(
                      value: _selectedKind,
                      items: const [
                        DropdownMenuItem(
                          value: 'all',
                          child: Text('All categories'),
                        ),
                        DropdownMenuItem(value: 'bug', child: Text('Bug')),
                        DropdownMenuItem(
                          value: 'wrong_card_data',
                          child: Text('Wrong card data'),
                        ),
                        DropdownMenuItem(
                          value: 'card_request',
                          child: Text('Card request'),
                        ),
                        DropdownMenuItem(
                          value: 'general',
                          child: Text('General'),
                        ),
                      ],
                      onChanged: (v) =>
                          setState(() => _selectedKind = v ?? 'all'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          ticketList.isEmpty
                              ? 'No support tickets or feedback recorded yet.'
                              : 'No tickets match the selected filters.',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) =>
                            _SupportTicketCard(filtered[index]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SupportTicketCard extends ConsumerStatefulWidget {
  final Map<String, dynamic> ticket;
  const _SupportTicketCard(this.ticket);

  @override
  ConsumerState<_SupportTicketCard> createState() =>
      _SupportTicketCardState();
}

class _SupportTicketCardState extends ConsumerState<_SupportTicketCard> {
  bool _busy = false;
  bool _showDiagnostics = false;
  String? _error;

  String _kindLabel(String kind) {
    switch (kind) {
      case 'bug':
        return 'Bug';
      case 'wrong_card_data':
        return 'Wrong Card Data';
      case 'card_request':
        return 'Card Request';
      case 'general':
      default:
        return 'General';
    }
  }

  Color _kindColor(String kind) {
    switch (kind) {
      case 'bug':
        return Colors.red.shade700;
      case 'wrong_card_data':
        return Colors.purple.shade700;
      case 'card_request':
        return Colors.blue.shade700;
      case 'general':
      default:
        return Colors.teal.shade700;
    }
  }

  Future<void> _resolve() async {
    final responseController = TextEditingController();
    final shouldResolve = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resolve Ticket'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add an optional response or internal resolution note for this ticket:',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: responseController,
              decoration: const InputDecoration(
                hintText: 'e.g. Verified and corrected in card catalogue',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Mark Resolved'),
          ),
        ],
      ),
    );

    if (shouldResolve != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final ticketId = widget.ticket['id'] as String;
      await ref.read(adminApiProvider)!.resolveSupportTicket(
        ticketId,
        responseText: responseController.text.trim().isEmpty
            ? null
            : responseController.text.trim(),
      );
      ref.invalidate(supportTicketsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dismiss() async {
    final reasonController = TextEditingController();
    final shouldDismiss = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dismiss Ticket'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Are you sure you want to dismiss this ticket?'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              decoration: const InputDecoration(
                hintText: 'Optional dismissal reason',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );

    if (shouldDismiss != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final ticketId = widget.ticket['id'] as String;
      await ref.read(adminApiProvider)!.dismissSupportTicket(
        ticketId,
        reason: reasonController.text.trim().isEmpty
            ? null
            : reasonController.text.trim(),
      );
      ref.invalidate(supportTicketsProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.ticket;
    final isPending = t['state'] == 'pending';
    final isStale = t['is_stale'] == true;
    final kind = (t['kind'] ?? 'general') as String;
    final reporter = t['user_email'] ?? t['user_name'];
    final diagnostics = t['diagnostics'];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top badges row
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _kindColor(kind).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _kindColor(kind).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    _kindLabel(kind),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _kindColor(kind),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isPending
                        ? Colors.amber.shade100
                        : (t['state'] == 'resolved'
                            ? Colors.green.shade100
                            : Colors.grey.shade200),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    (t['state'] ?? 'pending').toString().toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: isPending
                          ? Colors.amber.shade900
                          : (t['state'] == 'resolved'
                              ? Colors.green.shade900
                              : Colors.grey.shade800),
                    ),
                  ),
                ),
                if (isStale) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade100,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Stale · ${t['age_days']}d',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.orange.shade900,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (t['app_version'] != null)
                  Text(
                    'v${t['app_version']}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // Reporter row
            Row(
              children: [
                Icon(
                  reporter != null ? Icons.person : Icons.person_outline,
                  size: 16,
                  color: Colors.grey.shade700,
                ),
                const SizedBox(width: 6),
                Text(
                  reporter != null ? '$reporter' : 'Guest / Unauthenticated',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: reporter != null
                        ? Colors.black87
                        : Colors.grey.shade700,
                  ),
                ),
                const SizedBox(width: 12),
                if (t['created_at'] != null)
                  Text(
                    '• ${t['created_at'].toString().split('T').first}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // Message content
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: SelectableText(
                t['message'] ?? '',
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
            ),

            // Operator response if resolved
            if (t['response'] != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Operator response / note:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.green.shade900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${t['response']}',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.green.shade900,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Diagnostics expandable preview
            if (diagnostics != null) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () =>
                    setState(() => _showDiagnostics = !_showDiagnostics),
                child: Row(
                  children: [
                    const Icon(Icons.data_object, size: 16, color: Colors.grey),
                    const SizedBox(width: 6),
                    Text(
                      _showDiagnostics
                          ? 'Hide diagnostics'
                          : 'Show diagnostics',
                      style: const TextStyle(fontSize: 12, color: Colors.blue),
                    ),
                  ],
                ),
              ),
              if (_showDiagnostics) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    diagnostics is String
                        ? diagnostics
                        : const JsonEncoder.withIndent('  ')
                            .convert(diagnostics),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ],

            // Error display
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],

            // Action buttons
            if (isPending) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    icon: _busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check, size: 16),
                    label: const Text('Resolve'),
                    onPressed: _busy ? null : _resolve,
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Dismiss'),
                    onPressed: _busy ? null : _dismiss,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
