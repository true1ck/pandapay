import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Only aggregate merchant/category evidence is shown; no user's SMS or
/// transaction fields are returned to the console.
class SmsCategoryProposalsScreen extends ConsumerWidget {
  const SmsCategoryProposalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proposals = ref.watch(smsCategoryProposalsProvider);
    final parserProposals = ref.watch(smsParserProposalsProvider);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
      appBar: AppBar(
        title: const Text('SMS rule approvals'),
        bottom: const TabBar(tabs: [Tab(text: 'Categories'), Tab(text: 'Parser rules')]),
      ),
      body: TabBarView(children: [proposals.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Could not load proposals: $error')),
        data: (rows) => rows.isEmpty
            ? const Center(child: Text('No eligible proposals yet'))
            : ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) => _ProposalTile(rows[index]),
              ),
      ), parserProposals.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Could not load parser proposals: $error')),
        data: (rows) => rows.isEmpty
            ? const Center(child: Text('No parser proposals yet'))
            : ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) => _ParserProposalTile(rows[index]),
              ),
      )]),
      ),
    );
  }
}

class _ParserProposalTile extends ConsumerStatefulWidget {
  const _ParserProposalTile(this.proposal);
  final Map<String, dynamic> proposal;
  @override
  ConsumerState<_ParserProposalTile> createState() => _ParserProposalTileState();
}

class _ParserProposalTileState extends ConsumerState<_ParserProposalTile> {
  bool busy = false;

  Future<void> review(String decision) async {
    final ruleSha256 = widget.proposal['currentRuleSha256'];
    if (ruleSha256 is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(ruleSha256)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This parser proposal has no valid current rule hash and cannot be reviewed.')),
      );
      return;
    }
    final controller = TextEditingController();
    try {
      final reason = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${decision == 'approved' ? 'Approve' : 'Reject'} parser rule?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${widget.proposal['candidateId']} · ${widget.proposal['family']}'),
            TextField(controller: controller, maxLength: 500,
              decoration: const InputDecoration(labelText: 'Review reason (required)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save decision')),
          ],
        ),
      );
      if (reason == null) return;
      if (reason.length < 5) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a reason of at least 5 characters.')));
        return;
      }
      setState(() => busy = true);
      await ref.read(adminApiProvider)!.reviewSmsParserProposal(
        candidateId: widget.proposal['candidateId'] as String,
        ruleSha256: ruleSha256,
        decision: decision,
        reason: reason,
      );
      ref.invalidate(smsParserProposalsProvider);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rule $decision')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      controller.dispose();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final canReview = p['currentRuleSha256'] is String &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(p['currentRuleSha256'] as String);
    return ExpansionTile(
      title: Text('${p['candidateId']} · ${p['family']} · ${p['status']}'),
      subtitle: Text('Stage: ${p['state']} · sender: ${p['senderPattern']}'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SelectableText(
            'Confidence: ${p['confidence'] ?? '—'}\n'
            'Regex: ${p['regex'] ?? '—'}\n'
            'Fields: ${p['fieldMap'] ?? '—'}\n'
            'Default fields: ${p['defaultFields'] ?? '—'}\n'
            'Metrics: ${p['stageMetrics'] ?? '—'}\n'
            'Rule SHA-256: ${p['currentRuleSha256'] ?? 'unavailable'}',
          ),
        ),
        if (!canReview)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Review is unavailable because this proposal has no valid current rule hash.'),
          ),
        Wrap(spacing: 8, children: [
          OutlinedButton(onPressed: busy || !canReview ? null : () => review('rejected'), child: const Text('Reject')),
          FilledButton(onPressed: busy || !canReview ? null : () => review('approved'), child: const Text('Approve')),
        ]),
      ],
    );
  }
}

class _ProposalTile extends ConsumerStatefulWidget {
  const _ProposalTile(this.proposal);
  final Map<String, dynamic> proposal;

  @override
  ConsumerState<_ProposalTile> createState() => _ProposalTileState();
}

class _ProposalTileState extends ConsumerState<_ProposalTile> {
  bool busy = false;

  Future<void> review(String decision) async {
    final reasonController = TextEditingController();
    try {
      final reason = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${decision == 'approved' ? 'Approve' : 'Reject'} category rule?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${widget.proposal['merchant_key']} → ${widget.proposal['category_slug']}'),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Review reason (required)'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, reasonController.text.trim()),
              child: const Text('Save decision'),
            ),
          ],
        ),
      );
      if (reason == null) return;
      if (reason.length < 5) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a reason of at least 5 characters.')));
        return;
      }
      setState(() => busy = true);
      await ref.read(adminApiProvider)!.reviewSmsCategoryProposal(
        merchantKey: widget.proposal['merchant_key'] as String,
        categorySlug: widget.proposal['category_slug'] as String,
        decision: decision,
        reason: reason,
      );
      ref.invalidate(smsCategoryProposalsProvider);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rule $decision')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      reasonController.dispose();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final proposal = widget.proposal;
    final agreement = ((proposal['agreement_rate'] as num?)?.toDouble() ?? 0) * 100;
    return ListTile(
      title: Text('${proposal['merchant_key']} → ${proposal['category_slug']}'),
      subtitle: Text('${proposal['support_count']} users · ${agreement.toStringAsFixed(1)}% agreement · ${proposal['status'] ?? 'pending'}'),
      trailing: Wrap(
        spacing: 8,
        children: [
          OutlinedButton(onPressed: busy ? null : () => review('rejected'), child: const Text('Reject')),
          FilledButton(onPressed: busy ? null : () => review('approved'), child: const Text('Approve')),
        ],
      ),
    );
  }
}
