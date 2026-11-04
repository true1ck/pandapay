import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../data/api_exception.dart';
import '../../../data/authenticated_http_client.dart';
import 'shared_commands.dart';
import 'shared_transport.dart';
import 'package:pandapay_domain/shared_expenses.dart';

/// Uses the app's injected authenticated HTTP owner, including its refresh,
/// deadline and recovery tracking. Never owns/closes another client or logs
/// credentials, raw financial payloads or arbitrary server errors.
final class SharedExpensesHttpTransport implements SharedExpensesTransport {
  final Uri _base;
  final String namespace;
  final AuthenticatedHttpClient client;
  final String? Function() accessToken;
  final bool Function() isCurrent;
  final Future<void> Function(String contextId)? onContextRevoked;
  static const maxResponseBytes = 2 * 1024 * 1024;
  SharedExpensesHttpTransport({
    required String apiBaseUrl,
    required this.namespace,
    required this.client,
    required this.accessToken,
    required this.isCurrent,
    this.onContextRevoked,
  }) : _base = Uri.parse(apiBaseUrl) {
    if (_base.userInfo.isNotEmpty ||
        _base.hasQuery ||
        _base.hasFragment ||
        _base.host.isEmpty ||
        !(_base.scheme == 'https' ||
            _base.scheme == 'http' &&
                {
                  'localhost',
                  '127.0.0.1',
                  '::1',
                  '10.0.2.2',
                }.contains(_base.host)) ||
        !namespace.startsWith('user:') ||
        !sharedUuid(namespace.substring(5))) {
      throw ArgumentError('Invalid shared API configuration');
    }
  }
  String _token() {
    if (!isCurrent()) {
      throw const SharedTransportException(code: 'account_changed');
    }
    final token = accessToken();
    if (token == null || token.isEmpty || token.contains(RegExp(r'\s'))) {
      throw const SharedTransportException(statusCode: 401);
    }
    try {
      final pieces = token.split('.');
      if (pieces.length != 3) throw const FormatException();
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(pieces[1]))),
      );
      if (claims is! Map || 'user:${claims['sub']}' != namespace) {
        throw const FormatException();
      }
    } catch (_) {
      throw const SharedTransportException(code: 'account_changed');
    }
    return token;
  }

  Future<Map<String, Object?>?> _request(
    String method,
    String path, {
    String? body,
    Map<String, String>? query,
    bool operationLookup = false,
  }) async {
    final token = _token();
    final uri = _base.replace(
      path: '${_base.path.replaceFirst(RegExp(r'/$'), '')}$path',
      queryParameters: query,
    );
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store',
      });
    if (body != null) request.body = body;
    try {
      final response = await client.send(request);
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxResponseBytes) {
          throw const SharedTransportException(code: 'response_too_large');
        }
        bytes.addAll(chunk);
      }
      if (!isCurrent()) {
        throw const SharedTransportException(code: 'account_changed');
      }
      final contentType = response.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (contentType != 'application/json') {
        throw SharedTransportException(
          statusCode: response.statusCode >= 300 ? response.statusCode : null,
          code: 'invalid_response',
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map) {
        throw const SharedTransportException(code: 'invalid_response');
      }
      final result = Map<String, Object?>.from(decoded);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (operationLookup &&
            response.statusCode == 404 &&
            result['error'] == 'operation_not_found') {
          return null;
        }
        final error = result['error'];
        throw SharedTransportException(
          statusCode: response.statusCode,
          code:
              error is String &&
                  RegExp(r'^[a-z][a-z_]{0,63}$').firstMatch(error)?.group(0) ==
                      error
              ? error
              : null,
          retryable: result['retryable'] == true,
        );
      }
      return result;
    } on SharedTransportException {
      rethrow;
    } on ApiException catch (error) {
      throw SharedTransportException(statusCode: error.statusCode);
    } on TimeoutException {
      throw const SharedTransportException(code: 'network_unavailable');
    } on FormatException {
      throw const SharedTransportException(code: 'invalid_response');
    } on http.ClientException {
      throw const SharedTransportException(code: 'network_unavailable');
    }
  }

  SharedProjection _record(Object? value) {
    if (value is! Map ||
        value.length != 6 ||
        !value.keys.toSet().containsAll({
          'entity',
          'id',
          'contextId',
          'revision',
          'payload',
          'deleted',
        }) ||
        value['entity'] is! String ||
        value['id'] is! String ||
        value['contextId'] is! String ||
        value['deleted'] is! bool) {
      throw const FormatException('Invalid projection');
    }
    final raw = value['revision'];
    final int revision;
    if (raw is int && raw >= 0 && raw <= 9007199254740991) {
      revision = raw;
    } else if (raw is String &&
        raw.length <= 16 &&
        RegExp(r'^(0|[1-9][0-9]*)$').firstMatch(raw)?.group(0) == raw &&
        BigInt.parse(raw) <= BigInt.parse('9007199254740991')) {
      revision = BigInt.parse(raw).toInt();
    } else {
      throw const FormatException('Invalid projection version');
    }
    return SharedProjection(
      entity: value['entity'] as String,
      id: value['id'] as String,
      contextId: value['contextId'] as String,
      revision: revision,
      payload: value['payload'],
      deleted: value['deleted'] as bool,
    );
  }

  List<SharedProjection> _records(Object? value) {
    if (value is! List || value.length > 100) {
      throw const FormatException('Invalid projection page');
    }
    return value.map(_record).toList(growable: false);
  }

  SharedCommitResponse _commit(
    Map<String, Object?> value, {
    String? operationId,
    SharedCommand? command,
  }) {
    try {
      if (!value.containsKey('receipt') ||
          value.keys.any((key) => !{'receipt', 'records'}.contains(key))) {
        throw const FormatException('Invalid receipt wrapper');
      }
      final receipt = SharedOperationReceipt.fromJson(value['receipt']);
      if (operationId != null && receipt.operationId != operationId ||
          command != null &&
              (receipt.operationId != command.operationId ||
                  receipt.kind != command.kind ||
                  receipt.requestHash != command.requestHash ||
                  receipt.contextId != command.contextId)) {
        throw const FormatException('Receipt scope mismatch');
      }
      final records = _records(value['records'] ?? const []);
      if (records.any((row) => row.contextId != receipt.contextId)) {
        throw const FormatException('Projection scope mismatch');
      }
      return SharedCommitResponse(receipt: receipt, records: records);
    } on FormatException {
      throw const SharedTransportException(code: 'invalid_response');
    } on TypeError {
      throw const SharedTransportException(code: 'invalid_response');
    }
  }

  @override
  Future<SharedCommitResponse> execute(SharedCommand command) async => _commit(
    (await _request(
      'POST',
      '/shared-expenses/commands',
      body: command.canonicalJson,
    ))!,
    command: command,
  );
  @override
  Future<SharedCommitResponse?> lookupOperation(String operationId) async {
    if (!sharedUuid(operationId)) throw ArgumentError('Invalid operation ID');
    final result = await _request(
      'GET',
      '/shared-expenses/operations/$operationId',
      operationLookup: true,
    );
    return result == null ? null : _commit(result, operationId: operationId);
  }

  @override
  Future<SharedChangePage> pull({String? cursor, int limit = 100}) async {
    if (limit < 1 ||
        limit > 100 ||
        cursor != null && (cursor.isEmpty || cursor.length > 1024)) {
      throw ArgumentError('Invalid change query');
    }
    final result = (await _request(
      'GET',
      '/shared-expenses/changes',
      query: {'limit': '$limit', 'after': ?cursor},
    ))!;
    try {
      if (!result.keys.toSet().containsAll({
            'records',
            'nextCursor',
            'hasMore',
            'revokedContextIds',
          }) ||
          result.keys.any(
            (key) => !{
              'records',
              'nextCursor',
              'hasMore',
              'revokedContextIds',
              'grantedContextIds',
            }.contains(key),
          ) ||
          result['hasMore'] is! bool ||
          result['nextCursor'] != null && result['nextCursor'] is! String ||
          result['revokedContextIds'] is! List ||
          result['grantedContextIds'] != null &&
              result['grantedContextIds'] is! List) {
        throw const FormatException('Invalid changes');
      }
      final page = SharedChangePage(
        records: _records(result['records']),
        nextCursor: result['nextCursor'] as String?,
        hasMore: result['hasMore'] as bool,
        revokedContextIds: (result['revokedContextIds'] as List).cast<String>(),
        grantedContextIds: (result['grantedContextIds'] as List? ?? const [])
            .cast<String>(),
      );
      if (page.hasMore && page.nextCursor == cursor) {
        throw const FormatException('Cursor not advancing');
      }
      return page;
    } on FormatException {
      throw const SharedTransportException(code: 'invalid_response');
    } on TypeError {
      throw const SharedTransportException(code: 'invalid_response');
    }
  }

  Future<Map<String, Object?>> fetchCapabilities() async {
    final value = (await _request('GET', '/shared-expenses/capabilities'))!;
    const flags = {
      'available',
      'reads',
      'proposals',
      'acceptedWrites',
      'settlements',
      'sourceFunding',
    };
    if (value.length != flags.length + 1 ||
        value['schemaVersion'] != 1 ||
        flags.any((key) => value[key] is! bool)) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return value;
  }

  Future<Map<String, Object?>> fetchOverview() async {
    final value = (await _request('GET', '/shared-expenses/overview'))!;
    const keys = {
      'currency',
      'owedMinor',
      'owingMinor',
      'netMinor',
      'contextCount',
      'expenseCount',
    };
    if (value.length != keys.length ||
        !value.keys.toSet().containsAll(keys) ||
        value['currency'] != 'INR') {
      throw const SharedTransportException(code: 'invalid_response');
    }
    try {
      for (final key in [
        'owedMinor',
        'owingMinor',
        'contextCount',
        'expenseCount',
      ]) {
        sharedMoneyFromMinor(value[key]);
      }
      if (value['netMinor'] !=
          (BigInt.parse(value['owedMinor'] as String) -
                  BigInt.parse(value['owingMinor'] as String))
              .toString()) {
        throw const FormatException('Balance mismatch');
      }
    } catch (_) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return value;
  }

  Future<Map<String, Object?>> fetchTotals(String contextId) async {
    final value = await _contextRead(
      contextId,
      '/shared-expenses/contexts/$contextId/totals',
    );
    const keys = {
      'contextId',
      'currency',
      'sharedTotalMinor',
      'yourPaidMinor',
      'yourShareMinor',
      'expenseCount',
      'memberId',
    };
    if (value.length != keys.length ||
        !value.keys.toSet().containsAll(keys) ||
        value['currency'] != 'INR' ||
        !sharedUuid(value['memberId'])) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    try {
      for (final key in [
        'sharedTotalMinor',
        'yourPaidMinor',
        'yourShareMinor',
        'expenseCount',
      ]) {
        sharedMoneyFromMinor(value[key]);
      }
    } catch (_) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return value;
  }

  void _id(String id) {
    if (!sharedUuid(id)) throw ArgumentError('Invalid shared identity');
  }

  Future<Map<String, Object?>> _contextRead(
    String contextId,
    String path, {
    Map<String, String>? query,
  }) async {
    _id(contextId);
    try {
      return (await _request('GET', path, query: query))!;
    } on SharedTransportException catch (error) {
      if ((error.statusCode == 403 && error.code == 'context_not_authorized' ||
              error.statusCode == 404 && error.code == 'context_not_found') &&
          isCurrent()) {
        await onContextRevoked?.call(contextId);
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> _list(
    String path, {
    String? contextId,
    String? after,
    int limit = 50,
    String? kind,
    String? search,
  }) async {
    if (limit < 1 ||
        limit > 100 ||
        after != null && (after.isEmpty || after.length > 1024)) {
      throw ArgumentError('Invalid shared page query');
    }
    if (kind != null && !{'direct', 'group'}.contains(kind) ||
        search != null &&
            (search.length > 128 ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(search))) {
      throw ArgumentError('Invalid filter');
    }
    final query = {
      'limit': '$limit',
      'after': ?after,
      'kind': ?kind,
      'q': ?search,
    };
    final value = contextId == null
        ? (await _request('GET', path, query: query))!
        : await _contextRead(contextId, path, query: query);
    try {
      if (value.length != 3 ||
          !value.keys.toSet().containsAll({'items', 'nextCursor', 'hasMore'}) ||
          value['items'] is! List ||
          value['hasMore'] is! bool ||
          value['nextCursor'] != null && value['nextCursor'] is! String) {
        throw const FormatException();
      }
      final items = value['items'] as List,
          next = value['nextCursor'] as String?;
      if (items.length > limit ||
          next != null && (next.isEmpty || next.length > 1024) ||
          value['hasMore'] == true && (next == null || next == after)) {
        throw const FormatException();
      }
      for (final item in items) {
        if (item is! Map ||
            contextId != null && item['contextId'] != contextId) {
          throw const FormatException();
        }
        sharedCanonicalJson(item, maxBytes: 262144);
      }
      return value;
    } on FormatException {
      throw const SharedTransportException(code: 'invalid_response');
    } on TypeError {
      throw const SharedTransportException(code: 'invalid_response');
    }
  }

  Future<Map<String, Object?>> fetchContexts({
    String? after,
    int limit = 50,
    String? kind,
    String? search,
  }) => _list(
    '/shared-expenses/contexts',
    after: after,
    limit: limit,
    kind: kind,
    search: search,
  );
  Future<Map<String, Object?>> fetchPersonalActivity({
    String? after,
    int limit = 50,
    String? search,
  }) => _list(
    '/shared-expenses/activity',
    after: after,
    limit: limit,
    search: search,
  );
  Future<Map<String, Object?>> fetchContext(String contextId) async {
    final value = await _contextRead(
      contextId,
      '/shared-expenses/contexts/$contextId',
    );
    const keys = {
      'contextId',
      'kind',
      'name',
      'currency',
      'state',
      'membershipState',
      'committedSequence',
      'createdAt',
    };
    if (value.keys.toSet().difference(keys).isNotEmpty ||
        !value.keys.toSet().containsAll(keys) ||
        value['contextId'] != contextId) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    try {
      sharedCanonicalJson(value);
    } on FormatException {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return value;
  }

  Future<Map<String, Object?>> fetchMembers(
    String contextId, {
    String? after,
    int limit = 50,
  }) => _list(
    '/shared-expenses/contexts/$contextId/members',
    contextId: contextId,
    after: after,
    limit: limit,
  );
  Future<Map<String, Object?>> fetchExpenses(
    String contextId, {
    String? after,
    int limit = 50,
  }) => _list(
    '/shared-expenses/contexts/$contextId/expenses',
    contextId: contextId,
    after: after,
    limit: limit,
  );
  Future<Map<String, Object?>> fetchBalances(
    String contextId, {
    String? after,
    int limit = 50,
  }) => _list(
    '/shared-expenses/contexts/$contextId/balances',
    contextId: contextId,
    after: after,
    limit: limit,
  );
  Future<Map<String, Object?>> fetchActivity(
    String contextId, {
    String? after,
    int limit = 50,
  }) => _list(
    '/shared-expenses/contexts/$contextId/activity',
    contextId: contextId,
    after: after,
    limit: limit,
  );
  Future<Map<String, Object?>> fetchSettlements(
    String contextId, {
    String? after,
    int limit = 50,
  }) => _list(
    '/shared-expenses/contexts/$contextId/settlements',
    contextId: contextId,
    after: after,
    limit: limit,
  );
  Future<Map<String, Object?>> fetchExpense(
    String contextId,
    String expenseId,
  ) async {
    _id(expenseId);
    final value = await _contextRead(
      contextId,
      '/shared-expenses/contexts/$contextId/expenses/$expenseId',
    );
    const keys = {
      'contextId',
      'expenseId',
      'createdBy',
      'acceptedRevisionId',
      'headVersion',
    };
    if (value.keys.toSet().difference(keys).isNotEmpty ||
        !value.keys.toSet().containsAll(keys) ||
        value['contextId'] != contextId ||
        value['expenseId'] != expenseId) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    try {
      sharedCanonicalJson(value);
    } on FormatException {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return value;
  }

  Future<Map<String, Object?>> fetchExpenseRevisions(
    String contextId,
    String expenseId, {
    String? after,
    int limit = 50,
  }) {
    _id(expenseId);
    return _list(
      '/shared-expenses/contexts/$contextId/expenses/$expenseId/revisions',
      contextId: contextId,
      after: after,
      limit: limit,
    );
  }
}
