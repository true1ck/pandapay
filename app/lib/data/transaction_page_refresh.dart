import 'dart:async';

import 'local/financial_store.dart';
import 'user_cards_repository.dart';

class TransactionRefreshSlice {
  final int pages;
  final int rowsApplied;
  final bool hasMore;
  final String? nextCursor;

  const TransactionRefreshSlice({
    required this.pages,
    required this.rowsApplied,
    required this.hasMore,
    required this.nextCursor,
  });
}

/// One account/session/query owner of bounded history catch-up. Callers reuse
/// this instance to share requests and call [refresh] again when the result's
/// [TransactionRefreshSlice.hasMore] is
/// true. Each pass yields between pages and persists progress after applying
/// rows. Aggregate/full-query readers retain their authoritative refresh path.
class TransactionPageRefresh {
  final String namespace;
  final String sessionGeneration;
  final TransactionQuery query;
  final UserCardsRepository repository;
  final FinancialStore store;
  final bool Function() isCurrent;
  final int maxPagesPerPass;
  final int pageSize;
  Future<TransactionRefreshSlice>? _active;

  TransactionPageRefresh({
    required this.namespace,
    required this.sessionGeneration,
    required this.query,
    required this.repository,
    required this.store,
    required this.isCurrent,
    this.maxPagesPerPass = 2,
    this.pageSize = 200,
  }) {
    if (maxPagesPerPass < 1 || pageSize < 1 || pageSize > 500) {
      throw ArgumentError('Invalid transaction refresh bounds');
    }
  }

  Future<TransactionRefreshSlice> refresh({bool restart = false}) {
    final active = _active;
    if (active != null) return active;
    final work = _refresh(restart: restart);
    _active = work;
    work.whenComplete(() {
      if (identical(_active, work)) _active = null;
    }).ignore();
    return work;
  }

  void _checkCurrent() {
    if (!isCurrent()) throw StateError('Transaction refresh session changed');
  }

  Future<TransactionRefreshSlice> _refresh({required bool restart}) async {
    _checkCurrent();
    final progress = store.transactionPageProgress(namespace, query);
    final resumes =
        !restart &&
        progress != null &&
        progress.sessionGeneration == sessionGeneration;
    if (resumes && progress.exhausted) {
      return const TransactionRefreshSlice(
        pages: 0,
        rowsApplied: 0,
        hasMore: false,
        nextCursor: null,
      );
    }
    var cursor = resumes ? progress.nextCursor : null;
    var count = 0;
    var pages = 0;
    var hasMore = true;
    while (pages < maxPagesPerPass && hasMore) {
      _checkCurrent();
      final requestedAt = DateTime.now();
      final page = await repository.fetchTransactionPage(
        pageSize: pageSize,
        cursor: cursor,
        from: query.from,
        to: query.to,
        cardId: query.cardId,
        categoryId: query.categoryId,
        userCategoryId: query.userCategoryId,
        source: query.source,
        query: query.query,
      );
      _checkCurrent();
      if (page.hasMore && page.nextCursor == cursor) {
        throw const FormatException('Transaction page cursor did not advance');
      }
      store.applyTransactionPage(
        namespace,
        query,
        page,
        sessionGeneration: sessionGeneration,
        requestedCursor: cursor,
        at: requestedAt,
      );
      count += page.rows.length;
      pages++;
      cursor = page.nextCursor;
      hasMore = page.hasMore;
      if (hasMore && pages < maxPagesPerPass) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return TransactionRefreshSlice(
      pages: pages,
      rowsApplied: count,
      hasMore: hasMore,
      nextCursor: cursor,
    );
  }
}
