import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/needs_review_repository.dart';
import '../../data/sms_backup_xml_parser.dart';
import '../../data/user_cards_repository.dart';
import '../cards/find_cards_screen.dart';
import 'sms_text_hint.dart';

/// ui-spec.md F4 SMS Import — the one-time backup-file import path, and the
/// only SMS path that ships in the prod build (smsextractionimple.md §2).
/// It needs no SMS permission: the user exports their own messages with a
/// backup app and hands us the file.
///
/// ## What actually happens to the user's messages
///
/// This matters enough to spell out, because the screen used to claim
/// something different (see smsextractionimple.md §0.2). The flow is:
///
///   1. The XML is read and parsed ON THIS DEVICE.
///   2. Every message is tested against [looksLikeTransactionSms]. Anything
///      that doesn't look like a bank alert — OTPs, friends, delivery
///      notices, the overwhelming majority of a real inbox — is dropped
///      here and never leaves the phone.
///   3. What survives is sent to POST /transactions/from-sms/batch, which
///      runs the real regex parse server-side against `parser_patterns`.
///
/// So parsing is SERVER-side; only the filtering is local. The honest claim
/// — and the one the UI now makes — is that the message text isn't STORED:
/// a parsed message becomes a transaction row, and an unparsed one becomes
/// `redactSmsShape()` output in `parser_failures`, which has a CHECK
/// constraint forbidding digits. Neither keeps the body.
///
/// ## Dates and cycle state
///
/// Each message carries its original timestamp ([BackupSmsMessage.sentAt])
/// and is imported as a `backfill`, which records the transaction but does
/// not advance this cycle's cap/milestone/fee-waiver counters. Importing
/// two years of history should not report two years of progress against
/// this month's caps.
class SmsBackupImportScreen extends ConsumerStatefulWidget {
  const SmsBackupImportScreen({super.key});

  @override
  ConsumerState<SmsBackupImportScreen> createState() => _SmsBackupImportScreenState();
}

/// A group of messages that all mention the same card suffix, so the user
/// can attribute them in one action instead of per message.
///
/// Grouping by last-4 replaces the old single "import everything against
/// this one card" dropdown. A real backup file covers every card the user
/// owns; attributing all of it to one card produced confidently wrong
/// per-card spend, which is the number this app exists to get right.
class _MessageGroup {
  /// The card suffix these messages mention, or null for "no suffix found".
  final String? last4;
  final List<BackupSmsMessage> messages;

  /// Which of the user's cards to import against. Null means "skip" — a
  /// first-class choice, not an unset state. A backup file legitimately
  /// contains alerts for cards the user has since closed.
  String? userCardId;

  _MessageGroup({required this.last4, required this.messages});
}

enum _Phase { pick, review, importing, done }

class _SmsBackupImportScreenState extends ConsumerState<SmsBackupImportScreen> {
  _Phase _phase = _Phase.pick;

  String? _fileName;
  String? _pickError;

  /// Counts from the on-device pass, shown to the user so the privacy claim
  /// is something they can see rather than something they have to believe.
  int _totalInFile = 0;
  int _keptAfterFilter = 0;
  int _droppedUndated = 0;

  List<_MessageGroup> _groups = [];

  int _progressDone = 0;
  int _progressTotal = 0;
  bool _cancelRequested = false;

  int _imported = 0;
  int _duplicates = 0;
  int _unparsed = 0;

  /// The bodies that passed the on-device filter, kept for Task S-3's
  /// "find my cards from these messages" hand-off. In memory only, for this
  /// screen's lifetime — POST /card-discovery never persists them.
  final List<String> _keptBodies = [];

  Future<void> _pickFile() async {
    setState(() => _pickError = null);
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xml']);
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;

    if (picked.size > kMaxBackupFileBytes) {
      final mb = (kMaxBackupFileBytes / (1024 * 1024)).round();
      setState(
        () => _pickError =
            'That file is ${(picked.size / (1024 * 1024)).toStringAsFixed(0)} MB. '
            'The importer handles files up to $mb MB — try exporting a shorter date range.',
      );
      return;
    }

    try {
      final bytes = await picked.readAsBytes();
      // utf8.decode, NOT String.fromCharCodes: the latter treats each byte
      // as a code unit, so the 3-byte UTF-8 sequence for `₹` became three
      // garbage characters. In an INR-only app that silently broke amount
      // parsing for every issuer whose template uses the symbol.
      // allowMalformed keeps one bad byte from failing an otherwise good
      // 40,000-message file.
      final messages = parseSmsBackupXml(utf8.decode(bytes, allowMalformed: true));
      if (messages.isEmpty) {
        setState(() => _pickError = "Couldn't find any messages in that file.");
        return;
      }
      _prepare(picked.name, messages);
    } on SmsBackupParseException catch (e) {
      setState(() => _pickError = e.message);
    } catch (_) {
      setState(() => _pickError = "Couldn't read that file. Try picking it again.");
    }
  }

  /// The on-device pass: filter, then group by card suffix. Nothing has left
  /// the phone at this point and nothing will until the user taps Import.
  void _prepare(String fileName, List<BackupSmsMessage> all) {
    final kept = <BackupSmsMessage>[];
    var undated = 0;
    for (final m in all) {
      if (!looksLikeTransactionSms(m.body)) continue;
      // A message with no usable original date can't be imported: the
      // server needs it both to date the transaction and to build the
      // re-import key. Counted and reported rather than dropped in silence.
      if (m.sentAt == null) {
        undated++;
        continue;
      }
      kept.add(m);
    }

    final byLast4 = <String?, List<BackupSmsMessage>>{};
    for (final m in kept) {
      byLast4.putIfAbsent(extractLast4Hint(m.body), () => []).add(m);
    }

    final groups = byLast4.entries.map((e) => _MessageGroup(last4: e.key, messages: e.value)).toList()
      // Largest groups first, and the "no suffix" bucket last — it's the
      // one the user can say least about, so it shouldn't lead.
      ..sort((a, b) {
        if ((a.last4 == null) != (b.last4 == null)) return a.last4 == null ? 1 : -1;
        return b.messages.length.compareTo(a.messages.length);
      });

    setState(() {
      _fileName = fileName;
      _totalInFile = all.length;
      _keptAfterFilter = kept.length;
      _droppedUndated = undated;
      _groups = groups;
      _keptBodies
        ..clear()
        ..addAll(kept.map((m) => m.body));
      _phase = kept.isEmpty ? _Phase.pick : _Phase.review;
      if (kept.isEmpty) {
        _pickError =
            'None of the ${all.length} messages in that file look like bank alerts, '
            'so there is nothing to import.';
      }
    });
  }

  Future<void> _runImport() async {
    final repo = ref.read(userCardsRepositoryProvider);
    final importRepo = ref.read(importRepositoryProvider);
    if (repo == null || importRepo == null) return;

    final queue = <SmsBatchMessage>[];
    final sourceMessages = <BackupSmsMessage>[];
    for (final group in _groups) {
      if (group.userCardId == null) continue;
      for (final m in group.messages) {
        queue.add(
          SmsBatchMessage(
            userCardId: group.userCardId!,
            sender: m.sender,
            body: m.body,
            occurredAt: m.sentAt!,
          ),
        );
        sourceMessages.add(m);
      }
    }
    if (queue.isEmpty) return;

    setState(() {
      _phase = _Phase.importing;
      _cancelRequested = false;
      _progressDone = 0;
      _progressTotal = queue.length;
      _imported = 0;
      _duplicates = 0;
      _unparsed = 0;
    });

    // 200 is the server's per-request cap (SMS_BATCH_LIMIT). Chunking
    // rather than one giant request keeps progress meaningful and makes
    // cancel land within a second or so.
    const chunkSize = 200;
    try {
      for (var start = 0; start < queue.length; start += chunkSize) {
        if (_cancelRequested) break;
        final end = (start + chunkSize).clamp(0, queue.length);
        final chunk = queue.sublist(start, end);
        final result = await repo.logTransactionsFromSmsBatch(messages: chunk);

        // Same "never silently drop" discipline as the live listener: an
        // unparsed message still has its text in hand right here, so it
        // goes to needs-review rather than vanishing.
        for (final localIndex in result.unparsedIndices) {
          final original = sourceMessages[start + localIndex];
          await ref
              .read(needsReviewRepositoryProvider)
              .add(
                NeedsReviewItem(
                  id: '${original.sender}_${original.sentAt!.microsecondsSinceEpoch}',
                  sender: original.sender,
                  body: original.body,
                  reason: result.reasonByIndex[localIndex],
                  receivedAt: original.sentAt!,
                ),
              );
        }

        if (!mounted) return;
        setState(() {
          _progressDone = end;
          _imported += result.imported;
          _duplicates += result.duplicate;
          _unparsed += result.unparsed;
        });
      }

      await importRepo.recordSmsImportBatch(
        messageCount: _progressDone,
        parsedCount: _imported,
        failedCount: _unparsed,
      );
      if (_unparsed > 0) ref.invalidate(needsReviewItemsProvider);
      ref.invalidate(userCardsProvider);
      ref.invalidate(smsImportBatchesProvider);
      ref.invalidate(transactionsProvider);
      if (mounted) setState(() => _phase = _Phase.done);
    } catch (e) {
      if (mounted) {
        setState(() => _phase = _Phase.review);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Import SMS backup', style: BambooFonts.heading(16, color: BambooInk.ink900)),
      ),
      body: AppBackground(child: SafeArea(child: _body())),
    );
  }

  Widget _body() => switch (_phase) {
    _Phase.pick => _PickView(error: _pickError, onPick: _pickFile),
    _Phase.review => _reviewView(),
    _Phase.importing => _importingView(),
    _Phase.done => _doneView(),
  };

  // ---- Review -------------------------------------------------------------

  Widget _reviewView() {
    final userCards = ref.watch(userCardsProvider);

    return userCards.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(userCardsProvider),
      ),
      data: (cards) {
        // D4: a user with no cards is the exact user "find my cards from
        // SMS" is for. The old screen showed them a permanently disabled
        // button. Send them to discovery — with the messages we've already
        // filtered, so it has something to work with.
        if (cards.isEmpty) {
          return EmptyState(
            icon: Icons.credit_card_outlined,
            title: 'Add a card first',
            message:
                'We found $_keptAfterFilter bank alerts in $_fileName, but there are no cards in your '
                'wallet to file them against. PandaPay can work out which cards these belong to.',
            action: FilledButton(
              style: _primaryButtonStyle,
              onPressed: () => _openDiscovery(),
              child: const Text('Find my cards from these messages'),
            ),
          );
        }

        final selectedCount = _groups
            .where((g) => g.userCardId != null)
            .fold<int>(0, (sum, g) => sum + g.messages.length);

        return ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            _FilterSummary(
              fileName: _fileName ?? '',
              total: _totalInFile,
              kept: _keptAfterFilter,
              undated: _droppedUndated,
            ),
            const SizedBox(height: AppSpace.lg),
            Text(
              'Which card is each set for?',
              style: BambooFonts.heading(15, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Grouped by the card number mentioned in the message. Leave a set on '
              '"Skip" to leave it out entirely.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            for (final group in _groups) ...[
              _GroupCard(
                group: group,
                cards: cards,
                onChanged: (v) => setState(() => group.userCardId = v),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
            const SizedBox(height: AppSpace.lg),
            OutlinedButton.icon(
              style: _secondaryButtonStyle,
              icon: const Icon(Icons.auto_awesome_outlined, size: 18),
              label: const Text('Find more cards from these messages'),
              onPressed: _openDiscovery,
            ),
            const SizedBox(height: AppSpace.xl),
            FilledButton(
              style: _primaryButtonStyle.copyWith(
                minimumSize: WidgetStatePropertyAll(const Size.fromHeight(52)),
              ),
              onPressed: selectedCount == 0 ? null : _runImport,
              child: Text(
                selectedCount == 0
                    ? 'Pick a card to continue'
                    : 'Import $selectedCount message${selectedCount == 1 ? '' : 's'}',
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'Imported history is recorded in your activity, but does not change this '
              "cycle's cap or milestone progress.",
              textAlign: TextAlign.center,
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openDiscovery() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => FindCardsScreen(smsBodies: List.of(_keptBodies))),
    );
    if (mounted) ref.invalidate(userCardsProvider);
  }

  // ---- Importing ----------------------------------------------------------

  Widget _importingView() {
    final fraction = _progressTotal == 0 ? 0.0 : _progressDone / _progressTotal;
    return Padding(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _cancelRequested ? 'Finishing the current batch…' : 'Importing…',
            style: BambooFonts.heading(17, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 8,
              backgroundColor: BambooInk.paperMuted,
              valueColor: const AlwaysStoppedAnimation(BambooInk.slate),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            '$_progressDone of $_progressTotal · $_imported added'
            '${_duplicates > 0 ? ' · $_duplicates already imported' : ''}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.xl),
          Center(
            child: TextButton(
              onPressed: _cancelRequested ? null : () => setState(() => _cancelRequested = true),
              child: Text(
                'Stop',
                style: BambooFonts.ui(13.5, color: _cancelRequested ? BambooInk.ink300 : BambooInk.clay),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'Stopping keeps what has already been imported. You can run the same file '
            'again later — anything already added is skipped, not duplicated.',
            textAlign: TextAlign.center,
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
        ],
      ),
    );
  }

  // ---- Done ---------------------------------------------------------------

  Widget _doneView() {
    final parts = <String>[
      '$_imported added',
      if (_duplicates > 0) '$_duplicates already imported',
      if (_unparsed > 0) "$_unparsed couldn't be read — sent to Needs Review",
    ];
    return EmptyState(
      icon: Icons.check_circle_outline_rounded,
      title: _cancelRequested ? 'Import stopped' : 'Import complete',
      message: parts.join(' · '),
      action: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            style: _primaryButtonStyle,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
          const SizedBox(height: AppSpace.sm),
          TextButton(
            onPressed: _openDiscovery,
            child: Text(
              'Find cards from these messages',
              style: BambooFonts.ui(13.5, color: BambooInk.ink900),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Pieces ---------------------------------------------------------------

final ButtonStyle _primaryButtonStyle = FilledButton.styleFrom(
  backgroundColor: BambooInk.slate,
  foregroundColor: BambooInk.lime,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
);

final ButtonStyle _secondaryButtonStyle = OutlinedButton.styleFrom(
  foregroundColor: BambooInk.ink900,
  side: const BorderSide(color: BambooInk.hairlineOnPaper),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
);

class _PickView extends StatelessWidget {
  final String? error;
  final VoidCallback onPick;
  const _PickView({required this.error, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Text(
          'Import from an SMS backup file',
          style: BambooFonts.heading(20, color: BambooInk.ink900),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          'Export your messages with a backup app (SMS Backup & Restore produces the XML '
          'format this reads), then pick the file here. PandaPay never reads your messages '
          'off your phone directly — you choose the file, and you choose which cards it applies to.',
          style: BambooFonts.ui(13.5, color: BambooInk.ink500),
        ),
        const SizedBox(height: AppSpace.xl),
        // The privacy story, stated as mechanics rather than reassurance —
        // every line here is something the code actually does (see this
        // file's doc-comment). It replaces an earlier claim of on-device
        // parsing, which was not true.
        const _PrivacyPoint(
          icon: Icons.filter_alt_outlined,
          text:
              'Your phone filters the file first. Only messages that look like bank alerts '
              'are sent — the rest never leave the device.',
        ),
        const _PrivacyPoint(
          icon: Icons.cloud_outlined,
          text:
              'Those alerts are sent to PandaPay over an encrypted connection to pull out the '
              'amount, merchant and date.',
        ),
        const _PrivacyPoint(
          icon: Icons.delete_outline_rounded,
          text:
              'The message text itself is never stored on our servers — only the transaction '
              'it produced.',
        ),
        const SizedBox(height: AppSpace.xl),
        if (error != null) ...[
          Container(
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Text(error!, style: BambooFonts.ui(12.5, color: BambooInk.clay)),
          ),
          const SizedBox(height: AppSpace.md),
        ],
        FilledButton.icon(
          style: _primaryButtonStyle.copyWith(
            minimumSize: WidgetStatePropertyAll(const Size.fromHeight(52)),
          ),
          icon: const Icon(Icons.upload_file_outlined),
          label: const Text('Select backup file'),
          onPressed: onPick,
        ),
      ],
    );
  }
}

class _PrivacyPoint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _PrivacyPoint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: BambooInk.ink500),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(text, style: BambooFonts.ui(13, color: BambooInk.ink900)),
          ),
        ],
      ),
    );
  }
}

/// Shows the user the result of the on-device pass in plain numbers. The
/// point is that "most of your inbox never leaves your phone" is verifiable
/// here rather than merely asserted in the copy above.
class _FilterSummary extends StatelessWidget {
  final String fileName;
  final int total;
  final int kept;
  final int undated;

  const _FilterSummary({
    required this.fileName,
    required this.total,
    required this.kept,
    required this.undated,
  });

  @override
  Widget build(BuildContext context) {
    final dropped = total - kept - undated;
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BambooInk.slateRaised, BambooInk.slate],
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fileName,
            style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpace.sm),
          Text('$kept bank alerts found', style: BambooFonts.heading(18, color: BambooInk.onSlate)),
          const SizedBox(height: AppSpace.xs),
          Text(
            '$total messages read on this device · $dropped not bank alerts, kept on your phone'
            '${undated > 0 ? ' · $undated skipped (no date in the export)' : ''}',
            style: BambooFonts.ui(12, color: BambooInk.onSlateMuted),
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final _MessageGroup group;
  final List<UserCard> cards;
  final ValueChanged<String?> onChanged;

  const _GroupCard({required this.group, required this.cards, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final title = group.last4 == null
        ? 'No card number in the message'
        : 'Card ending ${group.last4}';

    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: BambooFonts.heading(14, color: BambooInk.ink900)),
              ),
              Text(
                '${group.messages.length}',
                style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink500),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          DropdownButtonFormField<String?>(
            initialValue: group.userCardId,
            isExpanded: true,
            style: BambooFonts.ui(14, color: BambooInk.ink900),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpace.md,
                vertical: AppSpace.md,
              ),
              filled: true,
              fillColor: BambooInk.paper,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
              ),
            ),
            items: [
              DropdownMenuItem(
                value: null,
                child: Text('Skip these', style: BambooFonts.ui(14, color: BambooInk.ink500)),
              ),
              for (final c in cards)
                DropdownMenuItem(
                  value: c.id,
                  child: Text(
                    c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
