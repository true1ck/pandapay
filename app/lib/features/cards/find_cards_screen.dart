import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_discovery_engine.dart';
import '../../data/user_cards_repository.dart' show CardDiscoveryResult, DiscoveredCard;
import '../import/email_forwarding_screen.dart';
import '../import/gmail_connect_screen.dart';
import '../import/gmail_connect_service.dart';
import '../import/gmail_discovery_service.dart';
import '../import/statement_pdf_import_screen.dart';
import '../sms_import/sms_backup_import_screen.dart';
import '../sms_import/sms_listener_service.dart';
import 'card_picker_screen.dart';

/// "Find my cards" — design 30's fastest add-a-card path, over **both**
/// forwarded bank email, direct Gmail auto-detection, and (on Android) bank SMS.
///
/// Parsing is 100% on-device (LocalCardDiscoveryEngine) with zero raw email
/// bodies uploaded to any server.
///
/// Nothing is added without a tap. Each suggestion shows the text that
/// produced it, because the failure this screen has to avoid is adding a
/// card the user doesn't own and then ranking against it.
class FindCardsScreen extends ConsumerStatefulWidget {
  /// Task S-3: SMS bodies to scan alongside the user's forwarded email,
  /// handed over by [SmsBackupImportScreen] after its on-device filter has
  /// already narrowed a backup file down to probable bank alerts, or
  /// populated by reading device SMS inbox on Android.
  final List<String> smsBodies;

  const FindCardsScreen({super.key, this.smsBodies = const []});

  @override
  ConsumerState<FindCardsScreen> createState() => _FindCardsScreenState();
}

class _FindCardsScreenState extends ConsumerState<FindCardsScreen> {
  CardDiscoveryResult? _result;
  bool _scanning = false;
  bool _adding = false;
  String? _error;
  final _added = <String>{};

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  Future<void> _scan({List<String>? customBodies}) async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      var bodies = customBodies != null ? List<String>.from(customBodies) : List<String>.from(widget.smsBodies);
      if (bodies.isEmpty && _isAndroid) {
        const smsService = SmsListenerService();
        var hasPerm = await smsService.hasPermissions();
        if (!hasPerm) {
          hasPerm = await smsService.requestPermissions();
        }
        if (hasPerm) {
          final readBodies = await smsService.readInboxSmsBodies();
          if (readBodies.isNotEmpty) {
            bodies = readBodies;
          }
        }
      }

      final repo = ref.read(userCardsRepositoryProvider);
      if (repo != null) {
        // Authenticated: scan via API (combines forwarded emails + local SMS bodies)
        final subset = bodies.length > 500
            ? bodies.sublist(bodies.length - 500)
            : bodies;
        final result = await repo.discoverCards(smsBodies: subset);
        if (mounted) setState(() => _result = result);
      } else {
        // Guest mode / on-device matching against local catalogue
        final catalogue = await ref.read(catalogueProvider.future);
        final localRepo = await ref.read(localUserCardsRepositoryProvider.future);
        final owned = await localRepo.fetchUserCards(catalogue: catalogue);
        final ownedIds = owned.map((c) => c.cardProductId).toSet();

        final localResult = LocalCardDiscoveryEngine.discoverAcrossMessages(
          smsBodies: bodies,
          catalogue: catalogue,
          isSms: true,
        );

        final filteredSuggestions = localResult.suggestions
            .where((s) => !ownedIds.contains(s.cardProductId))
            .toList();

        if (mounted) {
          setState(() {
            _result = CardDiscoveryResult(
              suggestions: filteredSuggestions,
              emailsScanned: 0,
              smsScanned: bodies.length,
            );
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _scanGmail() async {
    // First: a fresh connect via the pre-consent screen. If Gmail is already
    // connected on this device, try a silent token and skip straight to the
    // scan; otherwise walk the user through the explanation + Google picker.
    String? accessToken = await ref.read(gmailConnectControllerProvider.notifier).silentToken();
    if (accessToken == null) {
      if (!mounted) return;
      accessToken = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const GmailConnectScreen()),
      );
    }
    if (accessToken == null || accessToken.isEmpty) return; // cancelled

    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final catalogue = await ref.read(catalogueProvider.future);
      final gmailService = ref.read(gmailDiscoveryServiceProvider);

      final discovery = await gmailService.scanGmailForCards(
        catalogue: catalogue,
        accessToken: accessToken,
      );

      final repo = ref.read(userCardsRepositoryProvider);
      final localRepo = await ref.read(localUserCardsRepositoryProvider.future);
      final owned = repo != null
          ? await repo.fetchUserCards()
          : await localRepo.fetchUserCards(catalogue: catalogue);
      final ownedIds = owned.map((c) => c.cardProductId).toSet();

      final filtered = discovery.suggestions
          .where((s) => !ownedIds.contains(s.cardProductId))
          .toList();

      await ref
          .read(gmailConnectControllerProvider.notifier)
          .recordScan(cardsFound: filtered.length);

      if (mounted) {
        setState(() {
          _result = CardDiscoveryResult(
            suggestions: filtered,
            emailsScanned: discovery.emailsScanned,
            smsScanned: _result?.smsScanned ?? 0,
          );
        });
        if (filtered.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No new bank statement emails found in Gmail.'),
            ),
          );
        }
      }
    } on GmailScanException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } catch (e) {
      if (mounted) setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }


  Future<void> _requestAndScanSms() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      const smsService = SmsListenerService();
      var hasPerm = await smsService.hasPermissions();
      if (!hasPerm) {
        hasPerm = await smsService.requestPermissions();
      }
      if (hasPerm) {
        final readBodies = await smsService.readInboxSmsBodies();
        if (readBodies.isNotEmpty) {
          await _scan(customBodies: readBodies);
          return;
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              hasPerm
                  ? 'No bank SMS messages found on this device.'
                  : 'SMS permission was not granted. You can pick cards from the catalogue.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _openCardPicker() async {
    final picked = await Navigator.of(context).push<List<CardProduct>>(
      MaterialPageRoute(
        builder: (_) => const CardPickerScreen(),
      ),
    );
    if (picked != null && picked.isNotEmpty && mounted) {
      final repo = ref.read(userCardsRepositoryProvider);
      final local = repo == null ? await ref.read(localUserCardsRepositoryProvider.future) : null;
      for (final card in picked) {
        if (repo != null) {
          await repo.addCard(card.id);
        } else {
          await local!.addCard(card.id);
        }
        _added.add(card.id);
      }
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added ${picked.length} card${picked.length == 1 ? '' : 's'} to wallet.')),
        );
      }
    }
  }

  void _showOtherOptionsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: AppSpace.lg),
                decoration: BoxDecoration(
                  color: BambooInk.ink300,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
              Text(
                'Other ways to import',
                style: BambooFonts.heading(18, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.md),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: BambooInk.paperMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.picture_as_pdf_outlined, color: BambooInk.slate),
                ),
                title: Text('Import bank statement PDF', style: BambooFonts.heading(15, color: BambooInk.ink900)),
                subtitle: Text('Parses password-protected statements locally on-device', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const StatementPdfImportScreen()),
                  );
                },
              ),
              const Divider(height: AppSpace.lg),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: BambooInk.paperMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.upload_file_outlined, color: BambooInk.slate),
                ),
                title: Text('Import SMS backup file', style: BambooFonts.heading(15, color: BambooInk.ink900)),
                subtitle: Text('Import XML backup from SMS Backup & Restore', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SmsBackupImportScreen()),
                  );
                },
              ),
              const Divider(height: AppSpace.lg),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: BambooInk.paperMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.forward_to_inbox_rounded, color: BambooInk.slate),
                ),
                title: Text('Set up email forwarding', style: BambooFonts.heading(15, color: BambooInk.ink900)),
                subtitle: Text('Forward bank emails automatically for continuous sync', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const EmailForwardingScreen()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _add(DiscoveredCard card) async {
    if (_adding) return;

    if (card.isPlaceholder) {
      final picked = await Navigator.of(context).push<List<CardProduct>>(
        MaterialPageRoute(
          builder: (_) => CardPickerScreen(initialSearch: card.issuerName),
        ),
      );
      if (picked != null && picked.isNotEmpty && mounted) {
        setState(() => _adding = true);
        final messenger = ScaffoldMessenger.of(context);
        try {
          final repo = ref.read(userCardsRepositoryProvider);
          final local = repo == null ? await ref.read(localUserCardsRepositoryProvider.future) : null;
          for (final c in picked) {
            if (repo != null) {
              await repo.addCard(c.id);
            } else {
              await local!.addCard(c.id);
            }
          }
          if (mounted) setState(() => _added.add(card.cardProductId)); // Mark the placeholder as added
          ref.invalidate(myCardsProvider);
          ref.invalidate(userCardsProvider);
          messenger.showSnackBar(SnackBar(content: Text('Added ${picked.length} card(s) to wallet.')));
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
        } finally {
          if (mounted) setState(() => _adding = false);
        }
      }
      return;
    }

    setState(() => _adding = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repo = ref.read(userCardsRepositoryProvider);
      final local = repo == null ? await ref.read(localUserCardsRepositoryProvider.future) : null;
      if (repo != null) {
        await repo.addCard(card.cardProductId);
      } else {
        await local!.addCard(card.cardProductId);
      }
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      // Design 19's own worked example: "Axis Ace added · Found
      // automatically from a bank SMS". dedupeKey keeps a re-add from
      // stacking duplicates in the inbox.
      await recordAppNotification(
        ref,
        category: 'card_added',
        title: '${card.name} added',
        body: 'Found automatically in ${card.sources.contains('email') ? 'your bank email' : 'your SMS'}.',
        severity: 'good',
        dedupeKey: 'card_added:${card.cardProductId}',
      );
      if (mounted) setState(() => _added.add(card.cardProductId));
      messenger.showSnackBar(SnackBar(content: Text('${card.name} added to your wallet.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Find my cards', style: BambooFonts.heading(19, color: BambooInk.ink900)),
        actions: [
          IconButton(
            tooltip: 'Scan again',
            onPressed: _scanning ? null : () => _scan(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: AppBackground(child: _body()),
    );
  }

  Widget _body() {
    if (_scanning && _result == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: () => _scan());
    }
    final result = _result;
    if (result == null) return const SizedBox.shrink();

    if (result.suggestions.isEmpty) {
      final readNothing = result.emailsScanned == 0 && result.smsScanned == 0;
      return _DiscoveryEmptyState(
        readNothing: readNothing,
        result: result,
        isAndroid: _isAndroid,
        scanning: _scanning,
        scannedSummary: _scannedSummary(result),
        onConnectGmail: _scanGmail,
        onScanSms: _requestAndScanSms,
        onPickFromCatalogue: _openCardPicker,
        onOtherOptions: _showOtherOptionsSheet,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, AppSpace.md, 20, 30),
      children: [
        Text(
          'We read ${_scannedSummary(result)} and think you carry '
          '${result.suggestions.length} '
          'of these. Add the ones you actually have.',
          style: BambooFonts.ui(13.5, color: BambooInk.ink500, height: 1.5),
        ),
        if (!_isAndroid) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            'iOS never lets any app read your SMS, so this looks at forwarded bank email only.',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.5),
          ),
        ],
        const SizedBox(height: AppSpace.lg),
        for (final s in result.suggestions)
          _SuggestionCard(
            card: s,
            added: _added.contains(s.cardProductId),
            busy: _adding,
            onAdd: () => _add(s),
          ),
        const SizedBox(height: AppSpace.xl),
        const Divider(color: BambooInk.ink300, height: 1),
        const SizedBox(height: AppSpace.xl),
        _DiscoveryActionButtons(
          isAndroid: _isAndroid,
          scanning: _scanning,
          smsAlreadyScanned: result.smsScanned > 0,
          gmailAlreadyScanned: result.emailsScanned > 0,
          onConnectGmail: _scanGmail,
          onScanSms: _requestAndScanSms,
          onPickFromCatalogue: _openCardPicker,
          onOtherOptions: _showOtherOptionsSheet,
        ),
      ],
    );
  }

  String _scannedSummary(CardDiscoveryResult r) {
    final parts = <String>[
      if (r.emailsScanned > 0) '${r.emailsScanned} bank email${r.emailsScanned == 1 ? '' : 's'}',
      if (r.smsScanned > 0) '${r.smsScanned} SMS',
    ];
    return parts.isEmpty ? 'nothing' : parts.join(' and ');
  }
}

class _SuggestionCard extends StatelessWidget {
  final DiscoveredCard card;
  final bool added;
  final bool busy;
  final VoidCallback onAdd;

  const _SuggestionCard({
    required this.card,
    required this.added,
    required this.busy,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final sources = card.sources
        .map((s) => s == 'email' ? 'your bank email' : 'your SMS')
        .join(' and ');

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  card.name,
                  style: BambooFonts.heading(16, color: BambooInk.ink900),
                ),
              ),
              if (card.last4.isNotEmpty)
                Text(
                  '•••• ${card.last4.first}',
                  style: BambooFonts.heading(13, color: BambooInk.ink300, letterSpacing: 1),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // The evidence line is the point of this screen: it lets someone
          // spot a wrong suggestion instead of trusting a bare list.
          Text(
            'Found in $sources — ${card.evidence.take(3).join(', ')}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.45),
          ),
          const SizedBox(height: AppSpace.md),
          if (added)
            Row(
              children: [
                const Icon(Icons.check_circle_rounded, size: 18, color: BambooInk.jade),
                const SizedBox(width: 6),
                Text(
                  'Added to your wallet',
                  style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.jade),
                ),
              ],
            )
          else
            FilledButton(
              onPressed: busy ? null : onAdd,
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: BambooFonts.ui(14, weight: FontWeight.w700),
              ),
              child: Text(card.isPlaceholder ? 'Select your ${card.issuerName ?? 'Bank'} Card' : 'Yes, I have ${card.name}'),
            ),
        ],
      ),
    );
  }
}

class _DiscoveryEmptyState extends StatelessWidget {
  final bool readNothing;
  final CardDiscoveryResult result;
  final bool isAndroid;
  final bool scanning;
  final String scannedSummary;
  final VoidCallback onConnectGmail;
  final VoidCallback onScanSms;
  final VoidCallback onPickFromCatalogue;
  final VoidCallback onOtherOptions;

  const _DiscoveryEmptyState({
    required this.readNothing,
    required this.result,
    required this.isAndroid,
    required this.scanning,
    required this.scannedSummary,
    required this.onConnectGmail,
    required this.onScanSms,
    required this.onPickFromCatalogue,
    required this.onOtherOptions,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: BambooInk.paperMuted,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              size: 32,
              color: BambooInk.slate,
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          Text(
            readNothing ? 'Auto-detect your cards' : 'No cards recognised',
            style: BambooFonts.heading(20, color: BambooInk.ink900),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            readNothing
                ? 'Detect cards instantly on-device from your bank emails or SMS, or select them directly from the catalogue.'
                : 'We scanned $scannedSummary and could not match any card in our catalogue. Add your cards directly instead.',
            style: BambooFonts.ui(13.5, color: BambooInk.ink500, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpace.xl),

          // Action buttons
          _DiscoveryActionButtons(
            isAndroid: isAndroid,
            scanning: scanning,
            smsAlreadyScanned: result.smsScanned > 0,
            gmailAlreadyScanned: result.emailsScanned > 0,
            onConnectGmail: onConnectGmail,
            onScanSms: onScanSms,
            onPickFromCatalogue: onPickFromCatalogue,
            onOtherOptions: onOtherOptions,
          ),
        ],
      ),
    );
  }
}

class _DiscoveryActionButtons extends StatelessWidget {
  final bool isAndroid;
  final bool scanning;
  final bool smsAlreadyScanned;
  final bool gmailAlreadyScanned;
  final VoidCallback onConnectGmail;
  final VoidCallback onScanSms;
  final VoidCallback onPickFromCatalogue;
  final VoidCallback onOtherOptions;

  const _DiscoveryActionButtons({
    required this.isAndroid,
    required this.scanning,
    required this.smsAlreadyScanned,
    required this.gmailAlreadyScanned,
    required this.onConnectGmail,
    required this.onScanSms,
    required this.onPickFromCatalogue,
    required this.onOtherOptions,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Primary: Connect Gmail
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: BambooInk.slate,
            foregroundColor: BambooInk.lime,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
          ),
          icon: const Icon(Icons.mail_outline_rounded, size: 20),
          label: const Text('Connect Gmail (1-Tap Auto Find)'),
          onPressed: scanning ? null : onConnectGmail,
        ),
        const SizedBox(height: AppSpace.md),

        // Secondary: Scan SMS (if Android)
        if (isAndroid && !smsAlreadyScanned) ...[
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: BambooInk.slate,
              side: const BorderSide(color: BambooInk.ink300),
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              textStyle: BambooFonts.ui(14, weight: FontWeight.w600),
            ),
            icon: const Icon(Icons.sms_outlined, size: 18),
            label: const Text('Scan device bank SMS'),
            onPressed: scanning ? null : onScanSms,
          ),
          const SizedBox(height: AppSpace.md),
        ],

        // Pick from catalogue
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: BambooInk.slate,
            side: const BorderSide(color: BambooInk.ink300),
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: BambooFonts.ui(14, weight: FontWeight.w600),
          ),
          icon: const Icon(Icons.add_card_rounded, size: 18),
          label: const Text('Search & pick from catalogue'),
          onPressed: onPickFromCatalogue,
        ),
        const SizedBox(height: AppSpace.xl),

        // Secondary options text button
        TextButton.icon(
          onPressed: onOtherOptions,
          icon: const Icon(Icons.more_horiz_rounded, size: 18, color: BambooInk.ink500),
          label: Text(
            'PDF Statement · SMS Backup · Email Forwarding',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500, weight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

