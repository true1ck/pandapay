import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/support_api.dart';
import '../onboarding/request_unsupported_card_screen.dart';

/// H9 Feedback & Support. Standalone pushed screen — built per this task's
/// plan without touching providers.dart/router.dart/account_screen.dart, so
/// callers reach it with a plain
/// `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const
/// FeedbackSupportScreen()))`, same as ToolsHubScreen's tiles.
///
/// [prefilledKind]/[prefilledMessage] let a caller pre-populate the form —
/// A6's "trouble receiving my code?" link passes
/// `prefilledKind: 'general', prefilledMessage: "I'm not receiving my OTP
/// code."`. The class name and these two constructor params are the stable
/// contract other in-flight screens (A6, A8) are written against; don't
/// rename either without updating those call sites.
class FeedbackSupportScreen extends ConsumerWidget {
  final String? prefilledKind;
  final String? prefilledMessage;

  const FeedbackSupportScreen({super.key, this.prefilledKind, this.prefilledMessage});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final token = ref.watch(accessTokenProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Feedback & Support')),
      body: token == null
          ? const EmptyState(
              icon: Icons.support_agent_outlined,
              title: 'Sign in to send feedback',
              message: 'Support tickets are tied to your account so we can follow up with you.',
            )
          : _FeedbackForm(
              accessToken: token,
              prefilledKind: prefilledKind,
              prefilledMessage: prefilledMessage,
            ),
    );
  }
}

const _kKinds = <String, String>{
  'bug': 'Bug',
  'wrong_card_data': 'Wrong card data',
  'card_request': 'Request a card',
  'general': 'General',
};

class _FeedbackForm extends ConsumerStatefulWidget {
  final String accessToken;
  final String? prefilledKind;
  final String? prefilledMessage;

  const _FeedbackForm({required this.accessToken, this.prefilledKind, this.prefilledMessage});

  @override
  ConsumerState<_FeedbackForm> createState() => _FeedbackFormState();
}

class _FeedbackFormState extends ConsumerState<_FeedbackForm> {
  late String _kind;
  late final TextEditingController _messageController;
  bool _showDiagnostics = false;
  bool _submitting = false;
  String? _error;

  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _kind = widget.prefilledKind != null && _kKinds.containsKey(widget.prefilledKind)
        ? widget.prefilledKind!
        : 'general';
    _messageController = TextEditingController(text: widget.prefilledMessage ?? '');
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    // Real current values only — this is what actually gets sent, so it's
    // what the "show what we'll send" preview must render, not a
    // placeholder that only looks plausible.
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _packageInfo = info);
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _diagnostics => {
        'appVersion': _appVersion,
        'platform': Platform.operatingSystem,
      };

  String get _appVersion {
    final info = _packageInfo;
    if (info == null) return '…';
    final build = info.buildNumber;
    return build.isEmpty ? info.version : '${info.version}+$build';
  }

  Future<void> _submit() async {
    final message = _messageController.text.trim();
    if (message.isEmpty) {
      setState(() => _error = 'Please describe the issue before sending.');
      return;
    }
    if (_packageInfo == null) {
      // Diagnostics must be real values, not sent ahead of loading them —
      // guard rather than send a partial/placeholder payload.
      setState(() => _error = 'Still preparing diagnostics — try again in a moment.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final api = SupportApi(apiBaseUrl: _supportApiBaseUrl, accessToken: widget.accessToken);
      await api.submitTicket(
        kind: _kind,
        message: message,
        diagnostics: _diagnostics,
        appVersion: _appVersion,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Thanks for letting us know'),
          content: const Text('We typically respond within 2 business days.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = userFacingErrorMessage(err);
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Text('What kind of feedback is this?', style: textTheme.labelLarge),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: _kKinds.entries
              .map(
                (entry) => ChoiceChip(
                  label: Text(entry.value),
                  selected: _kind == entry.key,
                  onSelected: (_) => setState(() => _kind = entry.key),
                ),
              )
              .toList(),
        ),
        if (_kind == 'card_request') ...[
          const SizedBox(height: AppSpace.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RequestUnsupportedCardScreen()),
              ),
              child: const Text('Request a specific card instead'),
            ),
          ),
        ],
        const SizedBox(height: AppSpace.xl),
        Text('Tell us what happened', style: textTheme.labelLarge),
        const SizedBox(height: AppSpace.sm),
        TextField(
          controller: _messageController,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Describe the issue or request…',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        _DiagnosticsPreview(
          expanded: _showDiagnostics,
          onToggle: () => setState(() => _showDiagnostics = !_showDiagnostics),
          diagnosticsJson: _packageInfo == null ? null : jsonEncode(_diagnostics),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpace.lg),
          Text(_error!, style: textTheme.bodyMedium?.copyWith(color: AppColors.error)),
        ],
        const SizedBox(height: AppSpace.xxl),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Send'),
        ),
      ],
    );
  }
}

/// "Show what we'll send" — collapsed by default, shows the exact JSON
/// diagnostics payload before submit. This is a literal spec requirement
/// ("shown to user before sending"), not a nice-to-have — the Submit button
/// above sends precisely this map, nothing more.
class _DiagnosticsPreview extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;
  final String? diagnosticsJson;

  const _DiagnosticsPreview({required this.expanded, required this.onToggle, required this.diagnosticsJson});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.ink100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Row(
                children: [
                  const Icon(Icons.data_object_rounded, size: 18, color: AppColors.ink500),
                  const SizedBox(width: AppSpace.sm),
                  const Expanded(child: Text('Show what we\'ll send')),
                  Icon(
                    expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    color: AppColors.ink500,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, AppSpace.md),
              child: Text(
                diagnosticsJson ?? 'Loading…',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: AppColors.ink700),
              ),
            ),
        ],
      ),
    );
  }
}

const _supportApiBaseUrl = 'http://localhost:4000';
