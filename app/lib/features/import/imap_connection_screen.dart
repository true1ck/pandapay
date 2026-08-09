import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

/// ui-spec.md F7 IMAP Connection (fallback) ⭐.
///
/// Real schema gap closed this pass: `imap_connections`
/// (db/supabase/migrations/0018_imap_connections.sql) didn't exist before.
/// Security note (payments-app posture, this project's CLAUDE.md): the app
/// password is encrypted at rest server-side via pgcrypto (see POST
/// /imap-connections' doc-comment, api/src/index.js) — never plaintext —
/// but that's a stopgap (single static key, not real KMS/envelope
/// encryption); flagged again here since this is the screen that collects
/// the credential. The password is only ever POSTed once, over HTTPS in a
/// real deployment, and never logged/echoed back by this screen.
///
/// NOT built this pass: an actual background IMAP poller that reads the
/// mailbox (needs a scheduled job, same class of gap as F3's inbound-email
/// ingestion — see Task F-0). "Test connection" performs a real IMAP
/// handshake server-side (POST /imap-connections/:id/test decrypts the
/// stored app password and opens a live TLS+LOGIN against imap_host:port —
/// see api/src/imap_test.js) — not just a format check.
class ImapConnectionScreen extends ConsumerStatefulWidget {
  const ImapConnectionScreen({super.key});

  @override
  ConsumerState<ImapConnectionScreen> createState() => _ImapConnectionScreenState();
}

class _ImapConnectionScreenState extends ConsumerState<ImapConnectionScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _hostController = TextEditingController(text: 'imap.gmail.com');
  final _portController = TextEditingController(text: '993');
  final _senderFilterController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _senderFilterController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final repo = ref.read(importRepositoryProvider);
    if (repo == null) return;
    setState(() => _saving = true);
    try {
      final conn = await repo.saveImapConnection(
        email: _emailController.text.trim(),
        appPassword: _passwordController.text,
        imapHost: _hostController.text.trim(),
        imapPort: int.tryParse(_portController.text.trim()) ?? 993,
        senderFilter: _senderFilterController.text.trim(),
      );
      _passwordController.clear(); // never keep the typed password around after it's sent
      ref.invalidate(imapConnectionProvider);
      if (mounted) {
        final testResult = await repo.testImapConnection(conn.id);
        ref.invalidate(imapConnectionProvider);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(testResult.ok ? 'Connected — login succeeded.' : (testResult.reason ?? 'Login failed.')),
          ));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(imapConnectionProvider);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('IMAP connection')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(AppRadius.md)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warning),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'Google is progressively restricting basic-auth IMAP access. If this stops working, '
                    'switch to Email Forwarding instead — it doesn\'t depend on IMAP at all.',
                    style: textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          connection.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) =>
                ErrorState(message: userFacingErrorMessage(err), onRetry: () => ref.invalidate(imapConnectionProvider)),
            data: (conn) {
              if (conn != null) {
                return Container(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(AppRadius.md), border: Border.all(color: AppColors.ink100)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(conn.email, style: textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text('${conn.imapHost}:${conn.imapPort}', style: textTheme.bodySmall?.copyWith(color: AppColors.ink500)),
                      const SizedBox(height: AppSpace.sm),
                      Row(
                        children: [
                          Icon(
                            conn.verifiedAt != null ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                            size: 16,
                            color: conn.verifiedAt != null ? AppColors.success : AppColors.warning,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            conn.verifiedAt != null ? 'Login verified' : 'Not yet verified',
                            style: textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          const SizedBox(height: AppSpace.xxl),
          Text('Connect a mailbox', style: textTheme.labelLarge),
          const SizedBox(height: AppSpace.sm),
          TextField(controller: _emailController, decoration: const InputDecoration(labelText: 'Email address', border: OutlineInputBorder())),
          const SizedBox(height: AppSpace.md),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'App password',
              border: const OutlineInputBorder(),
              helperText: 'Not your normal password.',
              suffixIcon: IconButton(
                icon: const Icon(Icons.help_outline_rounded, size: 18),
                tooltip: 'How to generate an app password',
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('App passwords'),
                    content: const Text(
                      'Most providers (e.g. Google) let you generate a scoped "app password" separate from your '
                      'normal login, under Account → Security → App passwords. Use that here, never your real password.',
                    ),
                    actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Got it'))],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(controller: _hostController, decoration: const InputDecoration(labelText: 'IMAP server', border: OutlineInputBorder())),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          TextField(
            controller: _senderFilterController,
            decoration: const InputDecoration(
              labelText: 'Sender filter (optional)',
              hintText: 'e.g. alerts@hdfcbank.net',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          ElevatedButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save & test connection'),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            '"Test connection" performs a real IMAP login against your mail server to confirm the credentials work. '
            'No background poller is wired up yet to read the mailbox automatically (see this screen\'s doc-comment).',
            style: textTheme.bodySmall?.copyWith(color: AppColors.ink500),
          ),
        ],
      ),
    );
  }
}
