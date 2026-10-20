import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/transaction_tag_picker.dart';
import '../../data/api_exception.dart';
import '../../data/local/split_repository.dart';
import '../../data/local/sms_intake_repository.dart';
import '../../data/local/transaction_attachments_repository.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import '../account/account_screen.dart' show AccountTile;
import '../cards/card_summary.dart';
import 'report_transaction_screen.dart';
import '../sync/split_sync.dart';
import '../insights/spend_trends_screen.dart';

/// D2 Transaction Detail (ui-spec Group D). Deep-linkable at /activity/:id.
/// Full record incl. source and reconciliation status. Actions: edit (D3),
/// mark ignored (refund/reversal/transfer), plus design 18's own two rows:
/// **Add a note** and **Split this expense**.
///
/// Both of those were previously flagged here as real gaps rather than
/// faked. Notes had no write path (the full transaction PATCH exists, but
/// routing a note through it would recompute reward state for a comment
/// edit), and `transaction_splits` had a table and an RLS policy since
/// migration 0004 with no route ever reading or writing it. Both routes
/// exist now — `PATCH /transactions/:id/note` and
/// `GET`/`PUT /transactions/:id/splits`.
///
/// Still NOT built: the "a better card existed" panel, which needs the
/// shared historical-recompute calculator. Note that D6 Missed
/// Opportunities and design 04's Insights both answer that question in
/// aggregate via `compareToOwnedCards`; what's missing is the per-row
/// version with its cap/milestone state as of the transaction date, which
/// this schema does not retain (see historical_comparison.dart).
class TransactionDetailScreen extends ConsumerWidget {
  final String transactionId;
  final TransactionEntry? initialEntry;

  const TransactionDetailScreen({
    super.key,
    required this.transactionId,
    this.initialEntry,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txn = ref.watch(_transactionProvider(transactionId));
    // Activity and Spending already hold the complete row that was tapped.
    // Use it immediately while a live refresh is pending or unavailable.
    final entry = txn.valueOrNull ?? initialEntry;
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Transaction',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
        actions: [
          if (entry?.status == 'active' && !transactionId.startsWith('local-'))
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final changed = await context.push<bool>(
                  '/activity/$transactionId/edit',
                  extra: entry,
                );
                if (changed == true) {
                  ref.invalidate(_transactionProvider(transactionId));
                }
              },
            ),
        ],
      ),
      body: AppBackground(
        child: entry != null
            ? transactionId.startsWith('local-')
                  ? Padding(
                      padding: const EdgeInsets.all(AppSpace.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.merchantName ?? 'Saved transaction',
                            style: BambooFonts.heading(20),
                          ),
                          const SizedBox(height: AppSpace.md),
                          Text(
                            entry.amount.format(),
                            style: BambooFonts.heading(28),
                          ),
                          const SizedBox(height: AppSpace.md),
                          const Text(
                            'Saved on this device. Details and editing will be available after this entry syncs.',
                          ),
                        ],
                      ),
                    )
                  : _DetailBody(entry: entry)
            : txn.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => ErrorState(
                  message: userFacingErrorMessage(err),
                  onRetry: () =>
                      ref.invalidate(_transactionProvider(transactionId)),
                ),
                data: (_) => const EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'Transaction not available offline',
                  message: 'Reconnect and try again to load this transaction.',
                ),
              ),
      ),
    );
  }
}

final _transactionProvider = FutureProvider.family<TransactionEntry?, String>((
  ref,
  id,
) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  final loaded = ref.read(transactionsProvider).valueOrNull;
  final fromLoaded = loaded == null
      ? null
      : loaded.where((entry) => entry.id == id).firstOrNull;
  final cached = await cachedTransactionById(ref, id);
  final fallback = fromLoaded ?? cached;
  if (repo == null || id.startsWith('local-')) return fallback;
  try {
    return await repo.fetchTransaction(id);
  } catch (error) {
    if (isAuthenticationFailure(error) || fallback != null) return fallback;
    rethrow;
  }
});

final _capturedSmsProvider = FutureProvider.family<SmsIntakeEntry?, String>((
  ref,
  sourceKey,
) async {
  if (sourceKey.isEmpty) return null;
  final namespace = ref.read(cacheNamespaceProvider);
  if (namespace == 'signed-out') return null;
  final cache = await ref.read(responseCacheProvider.future);
  return SmsIntakeRepository(
    cache.financialStore.database,
  ).capturedById(namespace, sourceKey);
});

extension _TransactionFirstOrNull on Iterable<TransactionEntry> {
  TransactionEntry? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

class _DetailBody extends ConsumerStatefulWidget {
  final TransactionEntry entry;
  const _DetailBody({required this.entry});

  @override
  ConsumerState<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends ConsumerState<_DetailBody> {
  bool _ignoring = false;
  bool _attaching = false;
  final _imagePicker = ImagePicker();

  /// Held locally so the note and split rows update the moment they're
  /// saved, rather than waiting on a re-fetch of the parent transaction.
  /// Seeded from the entry; splits are loaded once on init.
  late String? _note = widget.entry.note;
  List<TransactionSplit> _splits = const [];
  String? _splitLoadError;
  bool _loadingSplits = true;
  bool _savingSplits = false;
  SplitRepository? _splitStore;
  LocalSplitDocument? _localSplit;

  @override
  void dispose() {
    _splitStore?.removeListener(_splitChanged);
    super.dispose();
  }

  void _splitChanged() {
    if (!mounted) return;
    if (_splitStore?.namespace != ref.read(cacheNamespaceProvider)) return;
    final local = _splitStore?.local(widget.entry.id);
    if (local == null) return;
    setState(() {
      _localSplit = local;
      _splits = local.document.splits;
      _loadingSplits = false;
      _splitLoadError = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _loadSplits();
  }

  Future<void> _loadSplits() async {
    try {
      final store = await ref.read(splitRepositoryProvider.future);
      if (!mounted) return;
      if (store.namespace != ref.read(cacheNamespaceProvider)) return;
      final cacheKey =
          '${store.namespace}:transaction_splits:${widget.entry.id}';
      if (_splitStore != store) {
        _splitStore?.removeListener(_splitChanged);
        _splitStore = store;
        store.addListener(_splitChanged);
      }
      // Migrate the old account-scoped read cache once. Pending documents in
      // the repository always take precedence over an endpoint snapshot.
      if (store.local(widget.entry.id) == null) {
        try {
          final cache = await ref.read(responseCacheProvider.future);
          final raw = await cache.get(cacheKey);
          if (raw != null) {
            store.seed(
              widget.entry.id,
              TransactionSplitDocument.fromJson(
                jsonDecode(raw) as Map<String, dynamic>,
              ),
              await cache.fetchedAt(cacheKey) ??
                  DateTime.fromMillisecondsSinceEpoch(0),
            );
          }
        } catch (_) {
          // A corrupt legacy blob is disposable; the durable outbox is not.
        }
      }
      await store.read(widget.entry.id);
      _splitChanged();
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadingSplits = false;
          _splitLoadError = isAuthenticationFailure(error)
              ? const AuthenticationUnavailableException().message
              : userFacingErrorMessage(error);
        });
      }
    }
  }

  Future<void> _resolveSplit(bool keepLocal) async {
    try {
      final store = _splitStore;
      if (store == null) return;
      final server = await store.fetchServerVersion(widget.entry.id);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            keepLocal ? 'Keep your saved split?' : 'Use the server split?',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Current server version'),
                if (server.splits.isEmpty)
                  const Text('No shares recorded.')
                else
                  _SplitSummary(
                    splits: server.splits,
                    total: widget.entry.amount,
                  ),
                const SizedBox(height: AppSpace.md),
                Text(
                  keepLocal
                      ? 'Your saved shares will replace this version when synced.'
                      : 'Your unsynced changes will be replaced with this version.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(keepLocal ? 'Keep my split' : 'Use server split'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        await store.resolve(
          widget.entry.id,
          keepLocal: keepLocal,
          reviewedServerVersion: server,
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    }
  }

  Future<void> _showNoteSheet() async {
    final controller = TextEditingController(text: _note ?? '');
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => Padding(
        // Lifts the sheet above the keyboard, which otherwise covers the
        // field it exists to expose.
        padding: EdgeInsets.only(
          left: AppSpace.lg,
          right: AppSpace.lg,
          top: AppSpace.lg,
          bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Note',
              style: BambooFonts.heading(18, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              maxLength: 2000,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: const InputDecoration(hintText: 'What was this for?'),
            ),
            const SizedBox(height: AppSpace.sm),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.onSlate,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == null) return;
    await _saveNote(saved.trim());
  }

  Future<void> _saveNote(String note) async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) return;
    final previous = _note;
    setState(() => _note = note.isEmpty ? null : note);
    try {
      await repo.updateTransactionNote(
        widget.entry.id,
        note.isEmpty ? null : note,
      );
      // The detail provider is refreshed below, but Activity, Home, and
      // Spending can still be holding the same transaction in their own
      // provider/cache. Invalidate the shared list as well so reopening the
      // transaction or searching for its note reads the value just saved.
      ref.invalidate(transactionsProvider);
      ref.invalidate(_transactionProvider(widget.entry.id));
    } catch (e) {
      if (mounted) setState(() => _note = previous);
      final offline = ref.read(isOnlineProvider).valueOrNull == false;
      if (offline) {
        final queue = await ref.read(syncQueueProvider.future);
        queue.enqueueUpdate(
          entity: 'transactions',
          entityId: widget.entry.id,
          fields: {'note': note.isEmpty ? null : note},
        );
        ref.invalidate(pendingSyncCountProvider);
        if (mounted) {
          setState(() => _note = note.isEmpty ? null : note);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Note saved offline — will sync when you reconnect.',
              ),
            ),
          );
        }
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "Couldn't save the note. ${userFacingErrorMessage(e)}",
            ),
          ),
        );
      }
    }
  }

  Future<void> _showSplitSheet() async {
    if (_savingSplits) return;
    // A detail row can be opened before the one-time split read has settled.
    // Finish that read before opening the editor so an existing split is not
    // accidentally presented as a new split and then overwritten.
    if (_loadingSplits) await _loadSplits();
    if (!mounted) return;
    if (_splitLoadError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Retry loading the current split before editing it.'),
        ),
      );
      return;
    }
    final result = await showModalBottomSheet<List<TransactionSplit>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) =>
          _SplitSheet(total: widget.entry.amount, initial: _splits),
    );
    if (result == null) return;

    if (!mounted) return;
    setState(() => _savingSplits = true);
    try {
      final store = _splitStore;
      if (store == null) {
        throw StateError('Local storage is unavailable. Try again.');
      }
      if (store.namespace != ref.read(cacheNamespaceProvider)) {
        throw StateError(
          'Account changed. Reopen the transaction before editing.',
        );
      }
      store.save(widget.entry.id, result, widget.entry.amount);
      _splitChanged();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _savingSplits = false);
    }
  }

  Future<void> _markIgnored(String reason) async {
    setState(() => _ignoring = true);
    try {
      await ref
          .read(userCardsRepositoryProvider)!
          .ignoreTransaction(widget.entry.id, reason: reason);
      ref.invalidate(_transactionProvider(widget.entry.id));
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      ref.invalidate(transactionsProvider);
      ref.invalidate(utilizationTransactionsProvider);
      ref.invalidate(homeSummaryProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Marked as ignored.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _ignoring = false);
    }
  }

  Future<void> _showIgnoreSheet() async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Text(
                'Why is this being ignored?',
                style: BambooFonts.heading(16, color: BambooInk.ink900),
              ),
            ),
            for (final r in const ['refund', 'reversal', 'transfer'])
              ListTile(
                title: Text(
                  _reasonLabel(r),
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                ),
                onTap: () => Navigator.of(context).pop(r),
              ),
          ],
        ),
      ),
    );
    if (reason != null) await _markIgnored(reason);
  }

  static String _reasonLabel(String r) => switch (r) {
    'refund' => 'Refund',
    'reversal' => 'Reversal',
    'transfer' => 'Not a spend (transfer)',
    _ => r,
  };

  Future<void> _openEdit() async {
    final changed = await context.push<bool>(
      '/activity/${widget.entry.id}/edit',
    );
    if (changed == true && mounted) {
      ref.invalidate(_transactionProvider(widget.entry.id));
    }
  }

  Future<void> _addReceipt() async {
    if (_attaching) return;
    final option = await showModalBottomSheet<_ReceiptPickOption>(
      context: context,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.lg,
                AppSpace.lg,
                AppSpace.sm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Add proof of payment',
                  style: BambooFonts.heading(17, color: BambooInk.ink900),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.of(context).pop(_ReceiptPickOption.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose a photo'),
              onTap: () =>
                  Navigator.of(context).pop(_ReceiptPickOption.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file_rounded),
              title: const Text('Choose a file'),
              subtitle: const Text('Receipt, PDF, warranty, or any other file'),
              onTap: () => Navigator.of(context).pop(_ReceiptPickOption.file),
            ),
          ],
        ),
      ),
    );
    if (option == null || !mounted) return;

    setState(() => _attaching = true);
    try {
      final repository = await ref.read(
        transactionAttachmentsRepositoryProvider.future,
      );
      if (option == _ReceiptPickOption.file) {
        final picked = await FilePicker.pickFiles(
          type: FileType.any,
          withData: true,
        );
        if (picked == null || picked.files.isEmpty) return;
        final file = picked.files.single;
        if (file.path != null) {
          await repository.addFromPath(
            transactionId: widget.entry.id,
            sourcePath: file.path!,
            fileName: file.name,
            mimeType: file.extension == null ? null : _mimeFor(file.extension!),
          );
        } else if (file.bytes != null) {
          await repository.addFromBytes(
            transactionId: widget.entry.id,
            bytes: file.bytes!,
            fileName: file.name,
            mimeType: file.extension == null ? null : _mimeFor(file.extension!),
          );
        }
      } else {
        final image = await _imagePicker.pickImage(
          source: option == _ReceiptPickOption.camera
              ? ImageSource.camera
              : ImageSource.gallery,
          imageQuality: 95,
        );
        if (image == null) return;
        await repository.addFromPath(
          transactionId: widget.entry.id,
          sourcePath: image.path,
          fileName: image.name,
          mimeType: image.mimeType ?? 'image/jpeg',
        );
      }
      ref.invalidate(transactionAttachmentsProvider(widget.entry.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Attachment saved on this device.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not attach that file: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _attaching = false);
    }
  }

  Future<void> _openAttachment(TransactionAttachment attachment) async {
    if (_isImageAttachment(attachment)) {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: InteractiveViewer(
            child: Image.file(File(attachment.localPath), fit: BoxFit.contain),
          ),
        ),
      );
      return;
    }
    final opened = await launchUrl(
      Uri.file(attachment.localPath),
      mode: LaunchMode.externalApplication,
    );
    if (opened) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(attachment.localPath, mimeType: attachment.mimeType)],
        text: attachment.fileName,
      ),
    );
  }

  Future<void> _deleteAttachment(TransactionAttachment attachment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove attachment?'),
        content: Text('Remove ${attachment.fileName} from this transaction?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final repository = await ref.read(
      transactionAttachmentsRepositoryProvider.future,
    );
    await repository.delete(attachment);
    ref.invalidate(transactionAttachmentsProvider(widget.entry.id));
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final tagRepository = ref.watch(transactionTagsProvider);
    final tags =
        tagRepository?.tagsForTransaction(entry.id, fallback: entry.tags) ??
        entry.tags;
    final isActive = entry.status == 'active';
    final attachments = ref.watch(transactionAttachmentsProvider(entry.id));

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Column(
                children: [
                  if (!isActive)
                    Container(
                      margin: const EdgeInsets.only(bottom: AppSpace.lg),
                      padding: const EdgeInsets.all(AppSpace.md),
                      decoration: BoxDecoration(
                        color: BambooInk.paperMuted,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.visibility_off_outlined,
                            size: 16,
                            color: BambooInk.ink500,
                          ),
                          const SizedBox(width: AppSpace.xs),
                          Expanded(
                            child: Text(
                              'This transaction is ${entry.status} — excluded from caps and rankings.',
                              style: BambooFonts.ui(
                                12.5,
                                color: BambooInk.ink500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Center(
                    child: Column(
                      children: [
                        MoneyText(
                          entry.amount,
                          confidence: Confidence.estimated,
                          style: BambooFonts.money(26, color: BambooInk.ink900),
                        ),
                        const SizedBox(height: AppSpace.xs),
                        Text(
                          entry.merchantName ??
                              (entry.entryKind == TxnEntryKind.income
                                  ? 'Income'
                                  : entry.entryKind.label),
                          style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpace.xl),
                  _DetailRow(label: 'Card', value: _cardOrPaymentLabel(entry)),
                  _DetailRow(label: 'Category', value: entry.categoryLabel),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final tag in tags)
                          ActionChip(
                            label: Text(tag.name),
                            avatar: Icon(
                              Icons.label_rounded,
                              size: 16,
                              color: transactionTagColor(tag.color),
                            ),
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    SpendTrendsScreen(initialTagIds: {tag.id}),
                              ),
                            ),
                          ),
                        if (tagRepository != null)
                          ActionChip(
                            label: Text(
                              tags.isEmpty ? 'Add tags' : 'Edit tags',
                            ),
                            avatar: const Icon(Icons.add_rounded, size: 16),
                            onPressed: () async {
                              final selected = await showTransactionTagPicker(
                                context,
                                selectedIds: tags.map((t) => t.id).toSet(),
                              );
                              if (selected == null ||
                                  !mounted ||
                                  ref.read(transactionTagsProvider) !=
                                      tagRepository)
                                return;
                              try {
                                await tagRepository.replace(
                                  entry.id,
                                  selected,
                                  fallback: entry.tags,
                                );
                              } catch (error) {
                                if (context.mounted)
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        userFacingErrorMessage(error),
                                      ),
                                    ),
                                  );
                              }
                            },
                          ),
                      ],
                    ),
                  ),
                  if (isActive &&
                      (entry.categoryName == null ||
                          [
                            'other',
                            'unknown',
                            'uncategorized',
                            'unclassified',
                          ].contains(entry.categoryName!.trim().toLowerCase())))
                    TextButton.icon(
                      onPressed: _openEdit,
                      icon: const Icon(Icons.category_outlined),
                      label: const Text('Assign category'),
                    ),
                  _DetailRow(
                    label: 'Date',
                    value: entry.occurredAt
                        .toLocal()
                        .toString()
                        .split('.')
                        .first,
                  ),
                  _DetailRow(label: 'Rail', value: _railLabel(entry.rail)),
                  _DetailRow(
                    label: 'Source',
                    value: _sourceLabel(entry.source),
                  ),
                  _DetailRow(
                    label: 'Verification',
                    value: _verificationLabel(entry),
                  ),
                  if (entry.observations.isNotEmpty)
                    _DetailRow(
                      label: 'Reported by',
                      value: entry.observations
                          .map(
                            (observation) => _sourceLabel(observation.source),
                          )
                          .toSet()
                          .join(', '),
                    ),
                  if (entry.observations.any(
                    (observation) =>
                        (observation.source == 'sms' ||
                            observation.source == 'sms_bulk') &&
                        observation.reference?.isNotEmpty == true,
                  ))
                    _DetailRow(
                      label: 'SMS reference',
                      value: entry.observations
                          .firstWhere(
                            (observation) =>
                                (observation.source == 'sms' ||
                                    observation.source == 'sms_bulk') &&
                                observation.reference?.isNotEmpty == true,
                          )
                          .reference!,
                    ),
                  if (entry.observations.any(
                    (observation) =>
                        observation.source == 'sms' ||
                        observation.source == 'sms_bulk',
                  ))
                    _DetailRow(
                      label: 'SMS received',
                      value: _smsReceivedLabel(entry),
                    ),
                  _DetailRow(
                    label: 'Status',
                    value:
                        entry.status[0].toUpperCase() +
                        entry.status.substring(1),
                  ),
                  if (entry.source == 'sms' ||
                      entry.source == 'sms_bulk' ||
                      entry.observations.any(
                        (observation) =>
                            observation.source == 'sms' ||
                            observation.source == 'sms_bulk',
                      ))
                    _SmsEvidenceSection(entry: entry),
                  if (_note != null && _note!.isNotEmpty)
                    _DetailRow(label: 'Note', value: _note!),
                  if (isActive) ...[
                    const SizedBox(height: AppSpace.lg),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: BambooInk.slate,
                        foregroundColor: BambooInk.lime,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        textStyle: BambooFonts.ui(
                          14.5,
                          weight: FontWeight.w700,
                        ),
                      ),
                      onPressed: _openEdit,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit transaction'),
                    ),
                  ],
                  const SizedBox(height: AppSpace.xl),
                  attachments.when(
                    loading: () => const SizedBox.shrink(),
                    error: (_, __) => _ReceiptSection(
                      attachments: const [],
                      attaching: _attaching,
                      onAdd: _addReceipt,
                      onOpen: _openAttachment,
                      onDelete: _deleteAttachment,
                    ),
                    data: (items) => _ReceiptSection(
                      attachments: items,
                      attaching: _attaching,
                      onAdd: _addReceipt,
                      onOpen: _openAttachment,
                      onDelete: _deleteAttachment,
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  // Design 18's two action rows, both now backed by real routes:
                  // PATCH /transactions/:id/note and PUT /transactions/:id/splits.
                  AccountTile(
                    icon: Icons.edit_note_rounded,
                    label: (_note == null || _note!.isEmpty)
                        ? 'Add a note'
                        : 'Edit note',
                    onTap: _showNoteSheet,
                  ),
                  const SizedBox(height: AppSpace.sm),
                  AccountTile(
                    icon: Icons.call_split_rounded,
                    label: _savingSplits
                        ? 'Saving split…'
                        : _splits.isEmpty
                        ? 'Split this expense'
                        : 'Split across ${_splits.length} ${_splits.length == 1 ? 'share' : 'shares'}',
                    onTap: _showSplitSheet,
                  ),
                  if (_localSplit?.pending == true) ...[
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      _localSplit!.error ??
                          'Saved on this device — waiting to sync.',
                      style: BambooFonts.ui(
                        12,
                        color: _localSplit!.blocked
                            ? BambooInk.clayInk
                            : BambooInk.ink500,
                      ),
                    ),
                    if (_localSplit!.blocked)
                      Wrap(
                        children: [
                          TextButton(
                            onPressed: () => _resolveSplit(true),
                            child: const Text('Keep my split'),
                          ),
                          TextButton(
                            onPressed: () => _resolveSplit(false),
                            child: const Text('Use server split'),
                          ),
                        ],
                      ),
                  ],
                  if (_loadingSplits) ...[
                    const SizedBox(height: AppSpace.sm),
                    const LinearProgressIndicator(minHeight: 2),
                  ] else if (_splitLoadError != null) ...[
                    const SizedBox(height: AppSpace.xs),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Could not load split details: $_splitLoadError',
                            style: BambooFonts.ui(12, color: BambooInk.clayInk),
                          ),
                        ),
                        TextButton(
                          onPressed: _loadSplits,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ] else if (_splits.isNotEmpty) ...[
                    const SizedBox(height: AppSpace.sm),
                    _SplitSummary(splits: _splits, total: widget.entry.amount),
                  ],
                  const SizedBox(height: AppSpace.sm),
                  // Design 18's third row, landing on design 26 with this payment
                  // already attached — not the catalogue-correction screen (C7) and
                  // not the general feedback inbox (H9).
                  AccountTile(
                    icon: Icons.flag_outlined,
                    label: 'Report an issue',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ReportTransactionScreen(entry: widget.entry),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.xl),
                ],
              ),
            ),
          ),
        ),
        if (isActive)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.sm,
                AppSpace.lg,
                AppSpace.lg,
              ),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: BambooInk.ink900,
                  side: const BorderSide(color: BambooInk.hairlineOnPaper),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
                ),
                onPressed: _ignoring ? null : _showIgnoreSheet,
                icon: _ignoring
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.visibility_off_outlined),
                label: const Text(
                  'Mark as ignored (refund / reversal / transfer)',
                ),
              ),
            ),
          ),
      ],
    );
  }

  static String _mimeFor(String extension) => switch (extension.toLowerCase()) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'pdf' => 'application/pdf',
    _ => 'application/octet-stream',
  };

  static String _railLabel(TxnRail rail) => switch (rail) {
    TxnRail.upiQr => 'UPI QR',
    TxnRail.swipe => 'Swipe',
    TxnRail.online => 'Online',
    TxnRail.contactless => 'Contactless',
    TxnRail.atm => 'ATM',
    TxnRail.emi => 'EMI',
    TxnRail.unknown => 'Unknown',
  };

  static String _sourceLabel(String source) => switch (source) {
    'manual' => 'Entered manually',
    'sms' => 'SMS',
    'email' => 'Email',
    'statement' => 'Statement import',
    'sms_bulk' => 'SMS backup import',
    'imported' => 'Imported',
    _ => source,
  };

  static String _verificationLabel(TransactionEntry entry) {
    final sources = entry.observations
        .map((observation) => observation.source)
        .toSet();
    final hasSms = sources.contains('sms') || sources.contains('sms_bulk');
    if (hasSms && sources.length > 1)
      return 'Matched to SMS and another source';
    if (hasSms) return 'Matched to SMS';
    if (sources.length > 1) return 'Matched to multiple sources';
    if (sources.isNotEmpty) return 'Single source report';
    return 'No verification evidence';
  }

  static String _smsReceivedLabel(TransactionEntry entry) {
    final sms = entry.observations.firstWhere(
      (observation) =>
          observation.source == 'sms' || observation.source == 'sms_bulk',
    );
    final received = sms.observedAt?.toLocal();
    if (received == null) return 'Available';
    return received.toString().split('.').first;
  }

  static String _cardOrPaymentLabel(TransactionEntry entry) {
    if (entry.cardDisplayName != null && entry.cardDisplayName!.isNotEmpty) {
      return entry.cardDisplayName!;
    }
    // A UPI bank debit is intentionally cardless. It is not a missing card
    // and must not be displayed as a blank field or attached to a random
    // saved credit card.
    if (entry.instrument == TxnInstrument.upiBank ||
        (!entry.instrumentKnown && entry.rail == TxnRail.upiQr)) {
      final accountLast4 = entry.accountLast4;
      return accountLast4 == null || accountLast4.isEmpty
          ? 'UPI / bank account'
          : 'Bank account ending $accountLast4';
    }
    if (entry.instrument == TxnInstrument.debitCard) {
      return 'Debit card (unmatched)';
    }
    if (entry.instrument == TxnInstrument.creditCard && entry.instrumentKnown) {
      final last4 = entry.cardLast4;
      return last4 == null || last4.isEmpty
          ? 'Credit card (unmatched)'
          : 'Credit card ending $last4';
    }
    if (entry.instrument == TxnInstrument.wallet) return 'Wallet';
    if (entry.instrument == TxnInstrument.cash) return 'Cash';
    return 'Payment method not matched';
  }
}

enum _ReceiptPickOption { camera, gallery, file }

bool _isImageAttachment(TransactionAttachment attachment) {
  if (attachment.mimeType?.startsWith('image/') == true) return true;
  return RegExp(
    r'\.(jpe?g|png|webp|gif|heic)$',
    caseSensitive: false,
  ).hasMatch(attachment.fileName);
}

class _ReceiptSection extends StatelessWidget {
  final List<TransactionAttachment> attachments;
  final bool attaching;
  final VoidCallback onAdd;
  final ValueChanged<TransactionAttachment> onOpen;
  final ValueChanged<TransactionAttachment> onDelete;

  const _ReceiptSection({
    required this.attachments,
    required this.attaching,
    required this.onAdd,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return CardSummaryPanel(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_outlined, color: BambooInk.ink500),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Receipts & proof',
                      style: BambooFonts.ui(
                        14,
                        weight: FontWeight.w700,
                        color: BambooInk.ink900,
                      ),
                    ),
                    Text(
                      'Keep bills, warranties, and claim documents with this payment',
                      style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (attachments.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            for (final attachment in attachments)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(
                  _isImageAttachment(attachment)
                      ? Icons.image_outlined
                      : Icons.insert_drive_file_outlined,
                  color: BambooInk.ink500,
                ),
                title: Text(
                  attachment.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(12.5, color: BambooInk.ink900),
                ),
                subtitle: const Text('Tap to open'),
                onTap: () => onOpen(attachment),
                trailing: IconButton(
                  tooltip: 'Remove attachment',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => onDelete(attachment),
                ),
              ),
          ],
          const SizedBox(height: AppSpace.sm),
          OutlinedButton.icon(
            onPressed: attaching ? null : onAdd,
            icon: attaching
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.attach_file_rounded),
            label: Text(attaching ? 'Adding…' : 'Attach receipt or file'),
          ),
          const SizedBox(height: 2),
          Text(
            'Stored privately on this device',
            style: BambooFonts.ui(10.5, color: BambooInk.ink500),
          ),
        ],
      ),
    );
  }
}

class _SmsEvidenceSection extends ConsumerWidget {
  final TransactionEntry entry;

  const _SmsEvidenceSection({required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final smsEvidence = entry.observations
        .where(
          (observation) =>
              observation.source == 'sms' || observation.source == 'sms_bulk',
        )
        .toList();
    final sms = smsEvidence.isEmpty ? null : smsEvidence.first;
    final captured = sms?.sourceKey == null
        ? null
        : ref.watch(_capturedSmsProvider(sms!.sourceKey!)).valueOrNull;
    final received = sms?.observedAt?.toLocal();
    final receivedLabel = received == null
        ? 'Received time unavailable'
        : received.toString().split('.').first;

    return CardSummaryPanel(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpace.md,
            0,
            AppSpace.md,
            AppSpace.md,
          ),
          leading: const Icon(Icons.sms_outlined, color: BambooInk.ink500),
          title: Text(
            'SMS evidence',
            style: BambooFonts.ui(
              14,
              weight: FontWeight.w700,
              color: BambooInk.ink900,
            ),
          ),
          subtitle: Text(
            'Detected from the bank SMS · $receivedLabel',
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
          children: [
            _EvidenceLine(
              label: 'Amount detected',
              value: entry.amount.format(),
            ),
            _EvidenceLine(
              label: 'Merchant detected',
              value: entry.merchantName ?? 'Not provided by SMS',
            ),
            _EvidenceLine(
              label: 'Date detected',
              value: entry.occurredAt.toLocal().toString().split('.').first,
            ),
            _EvidenceLine(
              label: 'Payment rail',
              value: _DetailBodyState._railLabel(entry.rail),
            ),
            if (entry.cardLast4?.isNotEmpty == true)
              _EvidenceLine(
                label: 'Card detected',
                value: '•••• ${entry.cardLast4}',
              ),
            if (entry.accountLast4?.isNotEmpty == true)
              _EvidenceLine(
                label: 'Account detected',
                value: 'Bank account ending ${entry.accountLast4}',
              ),
            if (sms?.reference?.isNotEmpty == true)
              _EvidenceLine(label: 'Bank reference', value: sms!.reference!),
            if (captured != null) ...[
              const SizedBox(height: AppSpace.sm),
              _EvidenceLine(label: 'Sender', value: captured.message.sender),
              Text(
                'Original SMS captured on this device',
                style: BambooFonts.ui(
                  11.5,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
              const SizedBox(height: AppSpace.xs),
              SelectableText(
                _maskSmsText(captured.message.body),
                style: BambooFonts.ui(12, color: BambooInk.ink900),
              ),
            ],
            const SizedBox(height: AppSpace.sm),
            Text(
              captured != null
                  ? 'This message is stored locally for cross-checking and is not uploaded as transaction evidence.'
                  : sms == null
                  ? 'This transaction is marked as SMS sourced, but the original evidence is not available on this device. Attach a screenshot in “Receipts & proof” to keep it with this payment.'
                  : 'Raw SMS text stays on this device and is not uploaded as transaction evidence. Attach a screenshot in “Receipts & proof” if you want to keep the original message with this payment.',
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
          ],
        ),
      ),
    );
  }
}

String _maskSmsText(String text) {
  return text.replaceAllMapped(RegExp(r'\b\d{8,}\b'), (match) {
    final value = match.group(0)!;
    return '•••• ${value.substring(value.length - 4)}';
  });
}

class _EvidenceLine extends StatelessWidget {
  final String label;
  final String value;

  const _EvidenceLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: BambooFonts.ui(12.5, color: BambooInk.ink900),
            ),
          ),
        ],
      ),
    );
  }
}

/// Design 18 "Split this expense" — who owed what out of one payment.
///
/// Deliberately does **not** re-run any reward arithmetic. The parent
/// transaction's caps, milestones and points were computed once, on the
/// card it was actually paid with; a split records a claim between people,
/// not a second payment. The sheet says so, because "split" in a payments
/// app could reasonably be read as "charge this to two cards".
///
/// Shares are allowed to total less than the payment — partially splitting
/// a bill is a real thing ("₹400 of this ₹1,000 was Priya's") and the
/// remainder is simply yours. Totalling *more* is always a mistake and is
/// blocked here as well as server-side.
class _SplitSummary extends StatelessWidget {
  final List<TransactionSplit> splits;
  final Money total;

  const _SplitSummary({required this.splits, required this.total});

  @override
  Widget build(BuildContext context) {
    final splitTotal = splits.fold(
      const Money.zero(),
      (sum, split) => sum + split.amount,
    );
    final remaining = total - splitTotal;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Split details',
            style: BambooFonts.ui(
              12.5,
              weight: FontWeight.w700,
              color: BambooInk.ink900,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          for (final split in splits)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      split.note?.trim().isNotEmpty == true
                          ? split.note!.trim()
                          : 'Unlabelled share',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(13, color: BambooInk.ink500),
                    ),
                  ),
                  MoneyText(
                    split.amount,
                    confidence: Confidence.confirmed,
                    style: BambooFonts.money(14, color: BambooInk.ink900),
                  ),
                ],
              ),
            ),
          const Divider(height: AppSpace.md),
          Text(
            'Your share: ${remaining.format(hidePaise: false)}',
            style: BambooFonts.ui(
              12,
              weight: FontWeight.w600,
              color: BambooInk.ink500,
            ),
          ),
        ],
      ),
    );
  }
}

class _SplitSheet extends StatefulWidget {
  final Money total;
  final List<TransactionSplit> initial;
  const _SplitSheet({required this.total, required this.initial});

  @override
  State<_SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends State<_SplitSheet> {
  late final List<TextEditingController> _amounts;
  late final List<TextEditingController> _notes;
  final _originalShares = <TextEditingController, TransactionSplit>{};

  @override
  void initState() {
    super.initState();
    final seed = widget.initial.isEmpty
        ? [const TransactionSplit(amount: Money.zero())]
        : widget.initial;
    _amounts = [
      for (final s in seed)
        TextEditingController(
          text: s.amount.isZero ? '' : s.amount.rupees.toStringAsFixed(2),
        ),
    ];
    _notes = [for (final s in seed) TextEditingController(text: s.note ?? '')];
    for (var i = 0; i < seed.length; i++) {
      _originalShares[_amounts[i]] = seed[i];
    }
  }

  @override
  void dispose() {
    for (final c in _amounts) {
      c.dispose();
    }
    for (final c in _notes) {
      c.dispose();
    }
    super.dispose();
  }

  Money _amount(TextEditingController controller) {
    final parsed = double.tryParse(controller.text.trim());
    return parsed == null || !parsed.isFinite || parsed <= 0
        ? const Money.zero()
        : Money.fromRupees(parsed);
  }

  int get _enteredPaise =>
      _amounts.fold(0, (sum, controller) => sum + _amount(controller).paise);

  bool get _overAllocated => _enteredPaise > widget.total.paise;

  bool get _hasShares =>
      _amounts.any((controller) => !_amount(controller).isZero);

  // An existing split can be cleared intentionally by removing every row.
  // A brand-new split still needs at least one positive share.
  bool get _canSave =>
      !_overAllocated &&
      !_hasInvalidAmounts &&
      (_hasShares || widget.initial.isNotEmpty);

  bool get _hasInvalidAmounts => _amounts.any((controller) {
    final text = controller.text.trim();
    return text.isNotEmpty &&
        (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(text) ||
            _amount(controller).isZero);
  });

  void _addShare() {
    setState(() {
      _amounts.add(TextEditingController());
      _notes.add(TextEditingController());
    });
  }

  void _removeShare(int index) {
    setState(() {
      _originalShares.remove(_amounts[index]);
      _amounts.removeAt(index).dispose();
      _notes.removeAt(index).dispose();
    });
  }

  void _save() {
    if (!_canSave) return;
    final splits = <TransactionSplit>[];
    for (var i = 0; i < _amounts.length; i++) {
      final amount = _amount(_amounts[i]);
      if (amount.isZero) continue; // a blank row is not an error, just skipped
      final note = _notes[i].text.trim();
      splits.add(
        TransactionSplit(
          amount: amount,
          note: note.isEmpty ? null : note,
          userCardId: _originalShares[_amounts[i]]?.userCardId,
          categoryId: _originalShares[_amounts[i]]?.categoryId,
        ),
      );
    }
    if (splits.isEmpty && widget.initial.isEmpty) return;
    Navigator.of(context).pop(splits);
  }

  @override
  Widget build(BuildContext context) {
    final remaining = Money.fromPaise(widget.total.paise - _enteredPaise);
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpace.lg,
        right: AppSpace.lg,
        top: AppSpace.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Split details',
              style: BambooFonts.heading(18, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Who owed what out of ${widget.total.format()}. This does not change which '
              'card was charged, or what it earned.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.lg),
            for (var i = 0; i < _amounts.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _amounts[i],
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => setState(() {}),
                        style: BambooFonts.money(15, color: BambooInk.ink900),
                        decoration: const InputDecoration(
                          prefixText: '₹ ',
                          hintText: '0',
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: TextField(
                        controller: _notes[i],
                        maxLength: 2000,
                        style: BambooFonts.ui(14, color: BambooInk.ink900),
                        decoration: const InputDecoration(
                          hintText: 'Who / what for',
                          counterText: '',
                        ),
                      ),
                    ),
                    if (_amounts.length > 1)
                      IconButton(
                        tooltip: 'Remove this share',
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: BambooInk.ink500,
                        ),
                        onPressed: () => _removeShare(i),
                      ),
                  ],
                ),
              ),
            TextButton.icon(
              onPressed: _amounts.length >= 20 ? null : _addShare,
              style: TextButton.styleFrom(
                foregroundColor: BambooInk.ink900,
                minimumSize: const Size(44, 44),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add a share'),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              _hasInvalidAmounts
                  ? 'Enter a positive amount with at most two decimal places for each share.'
                  : _overAllocated
                  ? 'That is ${(-remaining).format()} more than the payment.'
                  : 'Unallocated: ${remaining.format()} — still yours.',
              style: BambooFonts.ui(
                12.5,
                weight: FontWeight.w600,
                color: _overAllocated ? BambooInk.clayInk : BambooInk.ink500,
              ),
            ),
            const SizedBox(height: AppSpace.md),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.onSlate,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: _canSave ? _save : null,
              child: Text('Save split'),
            ),
            if (widget.initial.isNotEmpty) ...[
              const SizedBox(height: AppSpace.xs),
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(const <TransactionSplit>[]),
                child: const Text('Clear split'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: BambooFonts.ui(13.5, color: BambooInk.ink900),
            ),
          ),
        ],
      ),
    );
  }
}
