import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_exception.dart';

const appProductTermsVersion = '2026-08-07';

/// The public admission policy used to decide whether an invitation is
/// required. Unknown values intentionally fail closed in the activation UI.
class ProductAccessPolicy {
  const ProductAccessPolicy({
    required this.admissionMode,
    this.minimumClientCapability,
    this.revision,
    this.campaign,
  });

  final String admissionMode;
  final String? minimumClientCapability;
  final int? revision;
  final Map<String, dynamic>? campaign;

  bool get isOpen => admissionMode == 'open';
  bool get isInviteOnly => admissionMode == 'invite_only';
  bool get isPaused => admissionMode == 'paused_new';

  factory ProductAccessPolicy.fromJson(Map<String, dynamic> json) {
    final campaign = json['campaign'];
    return ProductAccessPolicy(
      admissionMode: json['admissionMode'] is String
          ? json['admissionMode'] as String
          : 'unavailable',
      minimumClientCapability: json['minimumClientCapability'] as String?,
      revision: json['revision'] is int ? json['revision'] as int : null,
      campaign: campaign is Map
          ? Map<String, dynamic>.from(campaign)
          : null,
    );
  }
}

class ProductAccessState {
  const ProductAccessState({required this.state, this.nextAction});

  final String state;
  final String? nextAction;

  bool get isActive => state == 'active';
  bool get requiresInvitation => state == 'requires_invite';
  bool get isPaused => state == 'paused';

  factory ProductAccessState.fromJson(Map<String, dynamic> json) =>
      ProductAccessState(
        state: json['state'] is String ? json['state'] as String : 'unknown',
        nextAction: json['nextAction'] as String?,
      );
}

class InvitationPreview {
  const InvitationPreview({
    required this.code,
    required this.previewToken,
    required this.termsVersion,
    required this.rewardAvailable,
    this.campaignVersion,
    this.requiredConsecutiveDays,
    this.qualificationWindowDays,
  });

  final String code;
  final String previewToken;
  final String termsVersion;
  final bool rewardAvailable;
  final String? campaignVersion;
  final int? requiredConsecutiveDays;
  final int? qualificationWindowDays;

  factory InvitationPreview.fromJson(Map<String, dynamic> json) {
    final token = json['previewToken'];
    final code = PendingInvitationStore.normalizeCode(json['code']);
    final termsVersion = json['termsVersion'];
    if (json['valid'] != true ||
        code == null ||
        token is! String ||
        token.isEmpty ||
        termsVersion is! String ||
        termsVersion.isEmpty) {
      throw const FormatException('Invitation preview is incomplete.');
    }
    return InvitationPreview(
      code: code,
      previewToken: token,
      termsVersion: termsVersion,
      rewardAvailable: json['rewardAvailable'] == true,
      campaignVersion: json['campaignVersion'] as String?,
      requiredConsecutiveDays: _optionalInt(json['requiredConsecutiveDays']),
      qualificationWindowDays: _optionalInt(json['qualificationWindowDays']),
    );
  }
}

int? _optionalInt(Object? value) => value is int ? value : null;

abstract interface class ProductAccessRepository {
  Future<ProductAccessPolicy> loadPolicy();
  Future<ProductAccessState> loadAccess();
  Future<InvitationPreview?> validateInvitation(String code);
  Future<Map<String, dynamic>> activate({
    String? invitationCode,
    String? invitationPreviewToken,
    bool? acceptRewardTerms,
    bool? acceptAccessOnly,
    bool? acceptProductTerms,
    String? productTermsVersion,
  });
  Future<void> completeOnboarding();
}

class ProductAccessApi implements ProductAccessRepository {
  ProductAccessApi({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  @override
  Future<ProductAccessPolicy> loadPolicy() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/access-policy'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /access-policy failed: ${response.statusCode} ${response.body}',
      );
    }
    return ProductAccessPolicy.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  @override
  Future<ProductAccessState> loadAccess() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/access'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /access failed: ${response.statusCode} ${response.body}',
      );
    }
    return ProductAccessState.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  @override
  Future<InvitationPreview?> validateInvitation(String code) async {
    final normalized = PendingInvitationStore.normalizeCode(code);
    if (normalized == null) return null;
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/invitations/validate'),
      headers: _headers,
      body: jsonEncode({'code': normalized}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /invitations/validate failed: '
        '${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['valid'] != true) return null;
    return InvitationPreview.fromJson(body);
  }

  @override
  Future<Map<String, dynamic>> activate({
    String? invitationCode,
    String? invitationPreviewToken,
    bool? acceptRewardTerms,
    bool? acceptAccessOnly,
    bool? acceptProductTerms,
    String? productTermsVersion,
  }) async {
    final normalizedCode = invitationCode == null
        ? null
        : PendingInvitationStore.normalizeCode(invitationCode);
    if (invitationCode != null && normalizedCode == null) {
      throw const FormatException('Enter a valid invitation code.');
    }
    if ((normalizedCode == null) != (invitationPreviewToken == null)) {
      throw const FormatException(
        'Check the invitation before activating the account.',
      );
    }
    final body = <String, dynamic>{};
    if (normalizedCode != null) body['invitationCode'] = normalizedCode;
    if (invitationPreviewToken != null) {
      body['invitationPreviewToken'] = invitationPreviewToken;
    }
    if (acceptRewardTerms == true) body['acceptRewardTerms'] = true;
    if (acceptAccessOnly == true) body['acceptAccessOnly'] = true;
    if (acceptProductTerms == true) {
      body['acceptProductTerms'] = true;
      if (productTermsVersion != null && productTermsVersion.isNotEmpty) {
        body['productTermsVersion'] = productTermsVersion;
      }
    }

    final response = await _client.post(
      Uri.parse('$apiBaseUrl/profile'),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /profile activation failed: '
        '${response.statusCode} ${response.body}',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  @override
  Future<void> completeOnboarding() async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/onboarding/complete'),
      headers: _headers,
      body: '{}',
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /onboarding/complete failed: '
        '${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['completed'] != true) {
      throw ApiException(
        'POST /onboarding/complete returned no server acknowledgement',
        userMessage: 'We couldn’t finish setup yet. Please try again.',
      );
    }
  }
}

enum InvitationCaptureStatus { stored, alreadyStored, conflict }

class InvitationCaptureResult {
  const InvitationCaptureResult({
    required this.status,
    required this.code,
    this.existingCode,
  });

  final InvitationCaptureStatus status;
  final String code;
  final String? existingCode;
}

/// Durable, install-local invite capture. A new incoming code never replaces
/// an existing one without an explicit call to [replace].
class PendingInvitationStore {
  PendingInvitationStore({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const storageKey = 'pandapay_app.pending_invitation_v1';
  final Future<SharedPreferences> Function() _loadPreferences;

  static String? normalizeCode(Object? raw) {
    if (raw is! String) return null;
    final value = raw.trim().toUpperCase();
    if (value.length < 6 || value.length > 32) return null;
    if (!RegExp(r'^[A-Z0-9]+(?:-[A-Z0-9]+)*$').hasMatch(value)) return null;
    return value;
  }

  Future<String?> read() async =>
      normalizeCode((await _loadPreferences()).getString(storageKey));

  Future<InvitationCaptureResult?> capture(Object? raw) async {
    final code = normalizeCode(raw);
    if (code == null) return null;
    final preferences = await _loadPreferences();
    final existing = normalizeCode(preferences.getString(storageKey));
    if (existing == code) {
      return InvitationCaptureResult(
        status: InvitationCaptureStatus.alreadyStored,
        code: code,
        existingCode: existing,
      );
    }
    if (existing != null) {
      return InvitationCaptureResult(
        status: InvitationCaptureStatus.conflict,
        code: code,
        existingCode: existing,
      );
    }
    await preferences.setString(storageKey, code);
    return InvitationCaptureResult(
      status: InvitationCaptureStatus.stored,
      code: code,
    );
  }

  Future<String?> replace(Object? raw) async {
    final code = normalizeCode(raw);
    if (code == null) return null;
    await (await _loadPreferences()).setString(storageKey, code);
    return code;
  }

  Future<bool> clearIfMatches(String code) async {
    final preferences = await _loadPreferences();
    if (normalizeCode(preferences.getString(storageKey)) !=
        normalizeCode(code)) {
      return false;
    }
    await preferences.remove(storageKey);
    return true;
  }
}

/// Parses only PandaPay invitation links. Other app/assistant URLs are not
/// interpreted as invitation codes.
String? invitationCodeFromUri(Uri uri) {
  final segments = uri.pathSegments;
  if (uri.scheme == 'https' &&
      uri.host.toLowerCase() == 'pandapay.app' &&
      segments.length == 2 &&
      segments.first.toLowerCase() == 'i') {
    return PendingInvitationStore.normalizeCode(segments[1]);
  }
  if (uri.scheme == 'pandapay' && uri.host.toLowerCase() == 'i' &&
      segments.length == 1) {
    return PendingInvitationStore.normalizeCode(segments.first);
  }
  if (uri.scheme == 'pandapay' && uri.host.isEmpty &&
      segments.length == 2 &&
      segments.first.toLowerCase() == 'i') {
    return PendingInvitationStore.normalizeCode(segments[1]);
  }
  return null;
}

class PendingSignupChoices {
  const PendingSignupChoices({
    required this.acceptProductTerms,
    required this.productTermsVersion,
    required this.optInCrowdsource,
    required this.optInMarketing,
    this.recordedPurposes = const {},
  });

  final bool acceptProductTerms;
  final String productTermsVersion;
  final bool optInCrowdsource;
  final bool optInMarketing;
  final Set<String> recordedPurposes;

  PendingSignupChoices withRecordedPurpose(String purpose) =>
      PendingSignupChoices(
        acceptProductTerms: acceptProductTerms,
        productTermsVersion: productTermsVersion,
        optInCrowdsource: optInCrowdsource,
        optInMarketing: optInMarketing,
        recordedPurposes: {...recordedPurposes, purpose},
      );

  Map<String, dynamic> toJson() => {
    'acceptProductTerms': acceptProductTerms,
    'productTermsVersion': productTermsVersion,
    'optInCrowdsource': optInCrowdsource,
    'optInMarketing': optInMarketing,
    'recordedPurposes': recordedPurposes.toList(),
  };

  factory PendingSignupChoices.fromJson(Map<String, dynamic> json) {
    final purposes = json['recordedPurposes'];
    return PendingSignupChoices(
      acceptProductTerms: json['acceptProductTerms'] == true,
      productTermsVersion: json['productTermsVersion'] is String
          ? json['productTermsVersion'] as String
          : appProductTermsVersion,
      optInCrowdsource: json['optInCrowdsource'] == true,
      optInMarketing: json['optInMarketing'] == true,
      recordedPurposes: purposes is List
          ? purposes.whereType<String>().toSet()
          : const {},
    );
  }
}

/// Stores A4 choices briefly across the OTP -> activation handoff (including
/// process death). They are removed only after all three A4 consent writes
/// have received their server acknowledgements.
class PendingSignupChoicesStore {
  PendingSignupChoicesStore({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const storageKey = 'pandapay_app.pending_signup_choices_v1';
  final Future<SharedPreferences> Function() _loadPreferences;

  Future<PendingSignupChoices?> read() async {
    final raw = (await _loadPreferences()).getString(storageKey);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      return PendingSignupChoices.fromJson(Map<String, dynamic>.from(json));
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> save(PendingSignupChoices choices) async {
    await (await _loadPreferences()).setString(
      storageKey,
      jsonEncode(choices.toJson()),
    );
  }

  Future<void> markPurposeRecorded(String purpose) async {
    final choices = await read();
    if (choices == null) return;
    await save(choices.withRecordedPurpose(purpose));
  }

  Future<void> clear() async => (await _loadPreferences()).remove(storageKey);
}
