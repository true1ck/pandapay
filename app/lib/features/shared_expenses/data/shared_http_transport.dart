import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOException;
import 'dart:isolate' show Isolate, RemoteError;

import 'package:http/http.dart' as http;

import '../../../data/api_exception.dart';
import '../../../data/authenticated_http_client.dart';
import 'shared_commands.dart';
import 'shared_directory.dart';
import 'shared_invitations.dart';
import 'shared_phone_display.dart';
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
            _base.scheme == 'http' && _isLocalDevelopmentHost(_base.host)) ||
        !namespace.startsWith('user:') ||
        !sharedUuid(namespace.substring(5))) {
      throw ArgumentError('Invalid shared API configuration');
    }
  }

  /// Plain http only for a developer's own machine or private network (the
  /// Android emulator alias, localhost, a Mac's LAN address for an iPhone).
  /// Release builds already refuse local origins in `Env`.
  static bool _isLocalDevelopmentHost(String host) {
    if ({'localhost', '127.0.0.1', '::1', '10.0.2.2'}.contains(host)) {
      return true;
    }
    if (host.endsWith('.local') || host.endsWith('.localhost')) return true;
    final m = RegExp(
      r'^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$',
    ).firstMatch(host);
    if (m == null) return false;
    final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
    return a == 10 || a == 192 && b == 168 || a == 172 && b >= 16 && b <= 31;
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
          existingContextId: sharedUuid(result['existingContextId'])
              ? result['existingContextId'] as String
              : null,
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
    } on IOException {
      // TLS handshake, reset connection, DNS: the network, not the server.
      throw const SharedTransportException(code: 'network_unavailable');
    }
  }

  List<SharedProjection> _records(Object? value) => _sharedRecords(value);

  // Static: a closure made in an instance method would capture `this` (the
  // HTTP client), which cannot be sent to another isolate.
  static Future<List<SharedProjection>> _parseInIsolate(List<Object?> value) =>
      Isolate.run(() => _sharedRecords(value));

  /// A change page can hold 100 records, each validated and canonicalised
  /// (measured 16-115 ms per page on a desktop, several times that on a
  /// phone). That is UI-isolate work, so a big page is parsed in a short-lived
  /// isolate; the result is plain data and is copied back.
  Future<List<SharedProjection>> _recordsOffThread(Object? value) async {
    if (value is List<Object?> && value.length > 8) {
      try {
        return await _parseInIsolate(value);
      } on FormatException {
        rethrow;
      } on TypeError {
        rethrow;
      } on RemoteError {
        throw const FormatException('Invalid projection page');
      }
    }
    return _sharedRecords(value);
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
        records: await _recordsOffThread(result['records']),
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

  /// Creates (or idempotently re-reads) the one outstanding invite link for an
  /// unclaimed member. The optional phone number is only sent so the server can
  /// bind the link to that verified number; it is never stored in clear text.
  Future<SharedInviteLink> createInvitation({
    required String invitationId,
    required String contextId,
    required String memberId,
    String? phoneNumber,
  }) async {
    for (final id in [invitationId, contextId, memberId]) {
      if (!sharedUuid(id)) throw ArgumentError('Invalid identifier');
    }
    final value = (await _request(
      'POST',
      '/shared-expenses/invitations',
      body: jsonEncode({
        'invitationId': invitationId,
        'contextId': contextId,
        'memberId': memberId,
        if (phoneNumber != null && phoneNumber.isNotEmpty)
          'phoneNumber': phoneNumber,
      }),
    ))!;
    final url = value['joinUrl'];
    final token = url is String
        ? sharedInviteTokenFromUri(Uri.tryParse(url))
        : null;
    if (token == null || value['invitationId'] != invitationId) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return SharedInviteLink(
      invitationId: invitationId,
      token: token,
      url: sharedInviteUrl(token),
    );
  }

  Future<SharedInvitePreview> previewInvitation(String token) async {
    final value = (await _request(
      'POST',
      '/shared-expenses/invitations/preview',
      body: jsonEncode({'token': token}),
    ))!;
    return SharedInvitePreview.fromJson(value);
  }

  Future<String> claimInvitation({
    required String token,
    required String operationId,
    bool? sharePhone,
  }) async {
    if (!sharedUuid(operationId)) throw ArgumentError('Invalid operation ID');
    final value = (await _request(
      'POST',
      '/shared-expenses/invitations/claim',
      body: jsonEncode({
        'token': token,
        'operationId': operationId,
        'sharePhone': ?sharePhone,
      }),
    ))!;
    final status = value['status'];
    if (status is! String || status.length > 32) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return status;
  }

  /// One picked number. The server rate-limits this and never reveals whether
  /// a person who opted out of discovery is registered.
  Future<SharedPhoneLookup> lookupPhone(String phoneNumber) async {
    final value = (await _request(
      'POST',
      '/shared-expenses/directory/lookup',
      body: jsonEncode({'phoneNumber': phoneNumber}),
    ))!;
    return SharedPhoneLookup.fromJson(value);
  }

  Future<List<SharedInboxInvite>> fetchInviteInbox() async {
    final value = (await _request(
      'GET',
      '/shared-expenses/invitations/inbox',
    ))!;
    final items = value['items'];
    if (items is! List || items.length > 50) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return [
      for (final item in items)
        SharedInboxInvite.fromJson(
          item is Map
              ? Map<String, Object?>.from(item)
              : throw const SharedTransportException(code: 'invalid_response'),
        ),
    ];
  }

  /// Joins (accept) or declines an inbox invitation. Returns the new status.
  Future<String> respondToInboxInvite({
    required String invitationId,
    required String operationId,
    required bool accept,
  }) async {
    if (!sharedUuid(invitationId) || !sharedUuid(operationId)) {
      throw ArgumentError('Invalid identifier');
    }
    final value = (await _request(
      'POST',
      '/shared-expenses/invitations/${accept ? 'accept' : 'decline'}',
      body: jsonEncode({
        'invitationId': invitationId,
        'operationId': operationId,
      }),
    ))!;
    final status = value['status'];
    if (status is! String || status.length > 32) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return status;
  }

  /// Whether other PandaPay users may find this account by phone number.
  Future<({bool phoneVerified, bool discoverable})> fetchDiscoverable() async {
    final value = (await _request('GET', '/shared-expenses/directory'))!;
    if (value['phoneVerified'] is! bool || value['discoverable'] is! bool) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return (
      phoneVerified: value['phoneVerified'] as bool,
      discoverable: value['discoverable'] as bool,
    );
  }

  Future<bool> setDiscoverable(bool discoverable) async {
    final value = (await _request(
      'POST',
      '/shared-expenses/directory',
      body: jsonEncode({'discoverable': discoverable}),
    ))!;
    if (value['discoverable'] is! bool) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return value['discoverable'] as bool;
  }

  Future<List<SharedOwnerInvitation>> fetchContextInvitations(
    String contextId,
  ) async {
    if (!sharedUuid(contextId)) throw ArgumentError('Invalid identifier');
    final value = (await _request(
      'GET',
      '/shared-expenses/contexts/$contextId/invitations',
    ))!;
    final items = value['items'];
    if (items is! List || items.length > 50) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return [
      for (final item in items)
        SharedOwnerInvitation.fromJson(
          item is Map
              ? Map<String, Object?>.from(item)
              : throw const SharedTransportException(code: 'invalid_response'),
        ),
    ];
  }

  /// Owner-only: creates (or, with a new [linkId], replaces) the group's
  /// shared join link. The previous link stops working immediately.
  Future<SharedInviteLink> createGroupLink({
    required String contextId,
    required String linkId,
  }) async {
    if (!sharedUuid(contextId) || !sharedUuid(linkId)) {
      throw ArgumentError('Invalid identifier');
    }
    final value = (await _request(
      'POST',
      '/shared-expenses/groups/link',
      body: jsonEncode({'contextId': contextId, 'linkId': linkId}),
    ))!;
    final url = value['joinUrl'];
    final token = url is String
        ? sharedInviteTokenFromUri(Uri.tryParse(url))
        : null;
    if (token == null) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return SharedInviteLink(
      invitationId: linkId,
      token: token,
      url: sharedInviteUrl(token),
    );
  }

  Future<void> removeMember({
    required String contextId,
    required String memberId,
    required String operationId,
  }) async {
    for (final id in [contextId, memberId, operationId]) {
      if (!sharedUuid(id)) throw ArgumentError('Invalid identifier');
    }
    await _request(
      'POST',
      '/shared-expenses/members/remove',
      body: jsonEncode({
        'contextId': contextId,
        'memberId': memberId,
        'operationId': operationId,
      }),
    );
  }

  Future<void> transferOwner({
    required String contextId,
    required String memberId,
    required String operationId,
  }) async {
    for (final id in [contextId, memberId, operationId]) {
      if (!sharedUuid(id)) throw ArgumentError('Invalid identifier');
    }
    await _request(
      'POST',
      '/shared-expenses/members/transfer-owner',
      body: jsonEncode({
        'contextId': contextId,
        'memberId': memberId,
        'operationId': operationId,
      }),
    );
  }

  Future<void> takeOverOwnership({
    required String contextId,
    required String operationId,
  }) async {
    if (!sharedUuid(contextId) || !sharedUuid(operationId)) {
      throw ArgumentError('Invalid identifier');
    }
    await _request(
      'POST',
      '/shared-expenses/contexts/take-over',
      body: jsonEncode({'contextId': contextId, 'operationId': operationId}),
    );
  }

  Future<void> leaveContext({
    required String contextId,
    required String operationId,
  }) async {
    if (!sharedUuid(contextId) || !sharedUuid(operationId)) {
      throw ArgumentError('Invalid identifier');
    }
    await _request(
      'POST',
      '/shared-expenses/contexts/leave',
      body: jsonEncode({'contextId': contextId, 'operationId': operationId}),
    );
  }

  Future<SharedGroupLinkStatus> fetchGroupLinkStatus(String contextId) async {
    if (!sharedUuid(contextId)) throw ArgumentError('Invalid identifier');
    final value = (await _request(
      'GET',
      '/shared-expenses/groups/$contextId/link',
    ))!;
    return SharedGroupLinkStatus.fromJson(value);
  }

  Future<void> revokeGroupLink({
    required String contextId,
    required String operationId,
  }) async {
    if (!sharedUuid(contextId) || !sharedUuid(operationId)) {
      throw ArgumentError('Invalid identifier');
    }
    await _request(
      'POST',
      '/shared-expenses/groups/link/revoke',
      body: jsonEncode({'contextId': contextId, 'operationId': operationId}),
    );
  }

  Future<List<SharedJoinRequest>> fetchJoinRequests() async {
    Future<List<SharedJoinRequest>> load({required bool withFull}) async {
      final value = (await _request(
        'GET',
        '/shared-expenses/invitations/requests',
        query: withFull ? {'withLookalikeFull': '1'} : null,
      ))!;
      final items = value['items'];
      if (items is! List || items.length > 50) {
        throw const SharedTransportException(code: 'invalid_response');
      }
      return [
        for (final item in items)
          SharedJoinRequest.fromJson(
            item is Map
                ? Map<String, Object?>.from(item)
                : throw const SharedTransportException(
                    code: 'invalid_response',
                  ),
          ),
      ];
    }

    // Plain request first so an older or rolled-back API never sees a
    // parameter it may reject. Only when the server itself flags look-alikes
    // do we ask once more for their full numbers; any refusal keeps the
    // first answer.
    final plain = await load(withFull: false);
    final needsFull = plain.any(
      (r) =>
          r.claimantPhone != null &&
          r.claimantPhone!.lookalike &&
          r.claimantPhone!.fullNumber == null,
    );
    if (!needsFull) return plain;
    try {
      return await load(withFull: true);
    } on SharedTransportException catch (error) {
      if (error.code == 'network_unavailable' || error.statusCode == 401) {
        rethrow;
      }
      return plain;
    }
  }

  /// Owner-only, audited and rate limited: the full number of one pending
  /// request. The result must stay in memory only.
  Future<SharedRevealedPhone> revealClaimantPhone({
    required String invitationId,
    required String operationId,
  }) async {
    if (!sharedUuid(invitationId) || !sharedUuid(operationId)) {
      throw ArgumentError('Invalid identifier');
    }
    final value = (await _request(
      'POST',
      '/shared-expenses/invitations/reveal-phone',
      body: jsonEncode({
        'invitationId': invitationId,
        'operationId': operationId,
      }),
    ))!;
    final e164 = value['e164'];
    if ((value['invitationId'] as String?)?.toLowerCase() !=
            invitationId.toLowerCase() ||
        e164 is! String ||
        !RegExp(r'^\+[0-9]{7,15}$').hasMatch(e164)) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return SharedRevealedPhone(e164);
  }

  /// Owner approves or declines someone who joined through a shared link.
  Future<String> respondToJoinRequest({
    required String invitationId,
    required String operationId,
    required bool approve,
  }) async {
    if (!sharedUuid(invitationId) || !sharedUuid(operationId)) {
      throw ArgumentError('Invalid identifier');
    }
    final value = (await _request(
      'POST',
      '/shared-expenses/invitations/respond',
      body: jsonEncode({
        'invitationId': invitationId,
        'operationId': operationId,
        'approve': approve,
      }),
    ))!;
    final status = value['status'];
    if (status is! String || status.length > 32) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return status;
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

  Future<Map<String, Object?>> fetchOverview() async =>
      _validateOverview((await _request('GET', '/shared-expenses/overview'))!);

  Map<String, Object?> _validateOverview(Map<String, Object?> value) {
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

  Future<Map<String, Object?>> fetchTotals(String contextId) async =>
      _validateTotals(
        await _contextRead(
          contextId,
          '/shared-expenses/contexts/$contextId/totals',
        ),
      );

  Map<String, Object?> _validateTotals(Map<String, Object?> value) {
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
    return _validateList(
      value,
      limit: limit,
      after: after,
      contextId: contextId,
    );
  }

  Map<String, Object?> _validateList(
    Object? raw, {
    required int limit,
    String? after,
    String? contextId,
  }) {
    try {
      if (raw is! Map) throw const FormatException();
      final value = Map<String, Object?>.from(raw);
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

  /// Everything the Splits hub shows, in one request (one server connection)
  /// instead of four. Each section passes the same strict checks as its own
  /// route. Throws `hub_unsupported` on a server that does not have the route.
  Future<Map<String, Object?>> fetchHub({
    String? friendsAfter,
    String? groupsAfter,
    String? activityAfter,
    String? friendsSearch,
    String? groupsSearch,
    String? activitySearch,
  }) async {
    for (final cursor in [friendsAfter, groupsAfter, activityAfter]) {
      if (cursor != null && (cursor.isEmpty || cursor.length > 1024)) {
        throw ArgumentError('Invalid shared page query');
      }
    }
    for (final term in [friendsSearch, groupsSearch, activitySearch]) {
      if (term != null &&
          (term.length > 128 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(term))) {
        throw ArgumentError('Invalid filter');
      }
    }
    final value = await _combined('/shared-expenses/hub', {
      'friendsAfter': ?friendsAfter,
      'groupsAfter': ?groupsAfter,
      'activityAfter': ?activityAfter,
      if (friendsSearch != null && friendsSearch.isNotEmpty)
        'friendsSearch': friendsSearch,
      if (groupsSearch != null && groupsSearch.isNotEmpty)
        'groupsSearch': groupsSearch,
      if (activitySearch != null && activitySearch.isNotEmpty)
        'activitySearch': activitySearch,
    });
    if (value.length != 4 ||
        !value.keys.toSet().containsAll({
          'friends',
          'groups',
          'overview',
          'activity',
        }) ||
        value['overview'] is! Map) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return {
      'friends': _validateList(
        value['friends'],
        limit: 50,
        after: friendsAfter,
      ),
      'groups': _validateList(value['groups'], limit: 50, after: groupsAfter),
      'overview': _validateOverview(
        Map<String, Object?>.from(value['overview'] as Map),
      ),
      'activity': _validateList(
        value['activity'],
        limit: 50,
        after: activityAfter,
      ),
    };
  }

  /// One split's whole screen in one request; see [fetchHub].
  Future<Map<String, Object?>> fetchGroupScreen(
    String contextId, {
    String? expenseAfter,
    String? balanceAfter,
  }) async {
    for (final cursor in [expenseAfter, balanceAfter]) {
      if (cursor != null && (cursor.isEmpty || cursor.length > 1024)) {
        throw ArgumentError('Invalid shared page query');
      }
    }
    final value = await _contextRead(
      contextId,
      '/shared-expenses/contexts/$contextId/screen',
      query: {'expenseAfter': ?expenseAfter, 'balanceAfter': ?balanceAfter},
    );
    if (value.length != 5 ||
        !value.keys.toSet().containsAll({
          'context',
          'members',
          'expenses',
          'balances',
          'totals',
        }) ||
        value['context'] is! Map ||
        value['totals'] is! Map) {
      throw const SharedTransportException(code: 'invalid_response');
    }
    return {
      'context': _validateContext(
        contextId,
        Map<String, Object?>.from(value['context'] as Map),
      ),
      'members': _validateList(
        value['members'],
        limit: 50,
        contextId: contextId,
      ),
      'expenses': _validateList(
        value['expenses'],
        limit: 50,
        after: expenseAfter,
        contextId: contextId,
      ),
      'balances': _validateList(
        value['balances'],
        limit: 50,
        after: balanceAfter,
        contextId: contextId,
      ),
      'totals': _validateTotals(
        Map<String, Object?>.from(value['totals'] as Map),
      ),
    };
  }

  Future<Map<String, Object?>> _combined(
    String path,
    Map<String, String> query,
  ) async {
    try {
      return (await _request(
        'GET',
        path,
        query: query.isEmpty ? null : query,
      ))!;
    } on SharedTransportException catch (error) {
      // An older server has no such route: an HTML/other 404 with no JSON code.
      if (error.statusCode == 404 && error.code == 'invalid_response') {
        throw const SharedTransportException(code: 'hub_unsupported');
      }
      rethrow;
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
  Future<Map<String, Object?>> fetchContext(String contextId) async =>
      _validateContext(
        contextId,
        await _contextRead(contextId, '/shared-expenses/contexts/$contextId'),
      );

  Map<String, Object?> _validateContext(
    String contextId,
    Map<String, Object?> value,
  ) {
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

// Top level on purpose: runs inside Isolate.run for large change pages.
final _revisionPattern = RegExp(r'^(0|[1-9][0-9]*)$');
SharedProjection _sharedRecord(Object? value) {
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
      _revisionPattern.firstMatch(raw)?.group(0) == raw &&
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

List<SharedProjection> _sharedRecords(Object? value) {
  if (value is! List || value.length > 100) {
    throw const FormatException('Invalid projection page');
  }
  return value.map(_sharedRecord).toList(growable: false);
}
