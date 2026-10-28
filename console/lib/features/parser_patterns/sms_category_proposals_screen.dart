import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import 'sms_correction_cases_screen.dart';

/// Only aggregate merchant/category evidence is shown; no user's SMS or
/// transaction fields are returned to the console.
class SmsCategoryProposalsScreen extends ConsumerWidget {
  const SmsCategoryProposalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proposals = ref.watch(smsCategoryProposalsProvider);
    final parserProposals = ref.watch(smsParserProposalsProvider);
    final aiProposals = ref.watch(smsAiProposalsProvider);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
      appBar: AppBar(
        title: const Text('SMS rule approvals'),
        bottom: const TabBar(tabs: [
          Tab(text: 'Categories'),
          Tab(text: 'Parser rules'),
          Tab(text: 'AI decisions'),
          Tab(text: 'Corrections'),
        ]),
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
      ), aiProposals.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Could not load AI proposals: $error')),
        data: (rows) => rows.isEmpty
            ? const Center(child: Text('No AI decisions awaiting review'))
            : ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) => _AiProposalTile(rows[index]),
              ),
      ),
      // C7: explicit user-correction cases — read-only, privacy-safe.
      const SmsCorrectionCasesTab(),
      ]),
      ),
    );
  }
}

class _AiProposalTile extends ConsumerStatefulWidget {
  const _AiProposalTile(this.proposal);
  final Map<String, dynamic> proposal;

  @override
  ConsumerState<_AiProposalTile> createState() => _AiProposalTileState();
}

class _AiProposalTileState extends ConsumerState<_AiProposalTile> {
  bool busy = false;

  Future<void> review(String decision) async {
    final reasonController = TextEditingController();
    try {
      final reason = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${decision == 'approved' ? 'Approve' : 'Reject'} AI learning evidence?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Approval adds this pattern to candidate evidence. A separate parser rule approval is required before device delivery.'),
            TextField(controller: reasonController, maxLength: 500,
              decoration: const InputDecoration(labelText: 'Review reason (required)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, reasonController.text.trim()),
              child: const Text('Save decision')),
          ],
        ),
      );
      if (reason == null) return;
      if (reason.length < 5) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enter a reason of at least 5 characters.')),
          );
        }
        return;
      }
      setState(() => busy = true);
      await ref.read(adminApiProvider)!.reviewSmsAiProposal(
        proposalId: widget.proposal['proposalId'] as String,
        decision: decision,
        reason: reason,
      );
      ref.invalidate(smsAiProposalsProvider);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Evidence $decision')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      reasonController.dispose();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final pending = p['status'] == 'pending';
    final hasTemplate = (p['proposedRule'] is Map) &&
        ((p['proposedRule'] as Map)['template'] is String);
    final fields = p['proposedRule'] is Map ? (p['proposedRule'] as Map)['fields'] : null;
    final hasCategoryEvidence = fields is Map &&
        fields['merchant'] is String && fields['categorySlug'] is String;
    final canApprove = hasTemplate || hasCategoryEvidence;
    return Card(child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${p['proposedRule'] is Map ? (p['proposedRule'] as Map)['family'] : 'AI decision'} · ${p['status']}',
          style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _ProposalEvidence(proposal: p),
        if (!canApprove) const Text('No safe parser or category evidence; reject or review manually.'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton(onPressed: busy || !pending ? null : () => review('rejected'), child: const Text('Reject')),
          FilledButton(onPressed: busy || !pending || !canApprove ? null : () => review('approved'), child: const Text('Approve evidence')),
        ]),
      ]),
    ));
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _ProposalEvidence(proposal: p),
            const SizedBox(height: 12),
            SelectableText(
              'Confidence: ${p['confidence'] ?? '—'}\n'
              'Regex: ${p['regex'] ?? '—'}\n'
              'Fields: ${p['fieldMap'] ?? '—'}\n'
              'Default fields: ${p['defaultFields'] ?? '—'}\n'
              'Metrics: ${p['stageMetrics'] ?? '—'}\n'
              'Rule SHA-256: ${p['currentRuleSha256'] ?? 'unavailable'}',
            ),
          ]),
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
              Text('Merchant: ${widget.proposal['merchant_key']}'),
              Text('Sender: ${widget.proposal['sender_key']}'),
              Text('Context: ${widget.proposal['context_key']}'),
              Text('Fact family: ${widget.proposal['fact_family']}'),
              Text('Category: ${widget.proposal['category_slug']}'),
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
        senderKey: widget.proposal['sender_key'] as String,
        contextKey: widget.proposal['context_key'] as String,
        factFamily: widget.proposal['fact_family'] as String,
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${proposal['merchant_key']} → ${proposal['category_slug']}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Sender: ${proposal['sender_key']} · Context: ${proposal['context_key']} · Family: ${proposal['fact_family']}'),
          const SizedBox(height: 4),
          Text('${proposal['support_count']} users · ${agreement.toStringAsFixed(1)}% agreement · ${proposal['status'] ?? 'pending'}'),
          const SizedBox(height: 10),
          _ProposalEvidence(proposal: proposal),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            OutlinedButton(onPressed: busy ? null : () => review('rejected'), child: const Text('Reject')),
            FilledButton(onPressed: busy ? null : () => review('approved'), child: const Text('Approve')),
          ]),
        ]),
      ),
    );
  }
}

/// Displays only backend-sanitized evidence fields. Never fall back to SMS body,
/// message, OTP, account, reference, or transaction fields.
class _ProposalEvidence extends StatelessWidget {
  const _ProposalEvidence({required this.proposal});
  final Map<String, dynamic> proposal;

  @override
  Widget build(BuildContext context) {
    final example = proposal['redacted_pattern'] ?? proposal['redactedPattern'];
    final samples = proposal['redacted_samples'] ?? proposal['redactedSamples'];
    final origin = proposal['origin'] ?? proposal['proposal_origin'];
    final strength = proposal['evidence_strength'] ?? proposal['evidenceStrength'];
    final rule = proposal['proposed_rule'] ?? proposal['proposedRule'];
    final lines = <Widget>[
      Text('Origin: ${_display(origin)}'),
      Text('Evidence strength: ${_display(strength)}'),
      if (example is String && example.trim().isNotEmpty)
        Text('Redacted SMS pattern: ${example.trim()}'),
      if (samples is List && samples.isNotEmpty)
        Text('Redacted examples: ${samples.whereType<String>().where((s) => s.trim().isNotEmpty).join(' · ')}'),
      if (rule is Map || rule is String) ...[
        const SizedBox(height: 4),
        Text('Proposed rule: ${_display(rule)}', style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
    );
  }

  static String _display(Object? value) => value == null ? 'Not provided' : value.toString();
}
