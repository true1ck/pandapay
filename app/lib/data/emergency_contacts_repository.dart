import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_exception.dart';

/// G4 Emergency Card Info — one row from `issuer_emergency_contacts`
/// (0002_reference_data.sql), joined to its issuer. Public data, no
/// per-user fields, by design (see GET /issuer-emergency-contacts'
/// doc-comment in api/src/index.js).
class IssuerEmergencyContact {
  final String id;
  final String issuerName;
  final String issuerSlug;
  final String label;
  final String phone;
  final bool isInternational;
  final bool isCollectCall;
  final String? blockProcedure;
  final int sortOrder;

  const IssuerEmergencyContact({
    required this.id,
    required this.issuerName,
    required this.issuerSlug,
    required this.label,
    required this.phone,
    required this.isInternational,
    required this.isCollectCall,
    this.blockProcedure,
    required this.sortOrder,
  });

  factory IssuerEmergencyContact.fromJson(Map<String, dynamic> json) {
    return IssuerEmergencyContact(
      id: json['id'] as String,
      issuerName: json['issuer_name'] as String,
      issuerSlug: json['issuer_slug'] as String,
      label: json['label'] as String,
      phone: json['phone'] as String,
      isInternational: json['is_international'] as bool? ?? false,
      isCollectCall: json['is_collect_call'] as bool? ?? false,
      blockProcedure: json['block_procedure'] as String?,
      sortOrder: json['sort_order'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toCacheJson() => {
        'id': id,
        'issuer_name': issuerName,
        'issuer_slug': issuerSlug,
        'label': label,
        'phone': phone,
        'is_international': isInternational,
        'is_collect_call': isCollectCall,
        'block_procedure': blockProcedure,
        'sort_order': sortOrder,
      };
}

abstract class EmergencyContactsRepository {
  Future<List<IssuerEmergencyContact>> fetch();
}

class HttpEmergencyContactsRepository implements EmergencyContactsRepository {
  final String baseUrl;
  final http.Client _client;

  HttpEmergencyContactsRepository({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  @override
  Future<List<IssuerEmergencyContact>> fetch() async {
    // Short timeout: this is exactly the "cold-started, airplane mode" path
    // G4 must survive — a hung request here must not leave the screen stuck
    // loading forever instead of falling back to cache/bundled data.
    final response = await _client
        .get(Uri.parse('$baseUrl/issuer-emergency-contacts'))
        .timeout(const Duration(seconds: 6));
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /issuer-emergency-contacts failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['contacts'] as List)
        .cast<Map<String, dynamic>>()
        .map(IssuerEmergencyContact.fromJson)
        .toList();
  }
}

/// Where G4's data actually came from for this render — surfaced in the UI
/// (data-honesty cross-cutting rule: never show a figure without saying how
/// fresh it is). [bundled] is the safety-net path: a fresh install, never
/// synced, with no network right now — the one case every other Insights
/// screen in this codebase is allowed to show ErrorState for, but G4 is
/// explicitly not.
enum EmergencyContactsSource { live, cached, bundled }

class EmergencyContactsResult {
  final List<IssuerEmergencyContact> contacts;
  final EmergencyContactsSource source;
  final DateTime? lastSyncedAt; // null only when source == bundled

  const EmergencyContactsResult({
    required this.contacts,
    required this.source,
    this.lastSyncedAt,
  });
}

/// Persists the last successfully-fetched contact list to on-device storage
/// via SharedPreferences — the same mechanism this app already uses for
/// every other local-only persistence need (onboarding flag, due-date
/// reminders — see providers.dart). Note this is NOT a reuse of an existing
/// catalogue-offline-cache: catalogue_repository.dart's own doc-comment
/// says plainly "there is currently no offline path" for the catalogue
/// today. G4's zero-network requirement is real and non-negotiable in a way
/// nothing else in this app is yet, so this builds the first genuine
/// on-device cache in the app rather than pointing at a cache that doesn't
/// exist — flagged as a judgment call, not silently copied from a pattern
/// that isn't actually there.
class EmergencyContactsCache {
  static const _dataKey = 'pandapay_app.emergency_contacts_cache_v1';
  static const _syncedAtKey = 'pandapay_app.emergency_contacts_synced_at_v1';

  Future<void> save(List<IssuerEmergencyContact> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(contacts.map((c) => c.toCacheJson()).toList());
    await prefs.setString(_dataKey, json);
    await prefs.setString(_syncedAtKey, DateTime.now().toIso8601String());
  }

  Future<(List<IssuerEmergencyContact>, DateTime)?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_dataKey);
    final syncedAtRaw = prefs.getString(_syncedAtKey);
    if (raw == null || syncedAtRaw == null) return null;
    final list = (jsonDecode(raw) as List)
        .cast<Map<String, dynamic>>()
        .map(IssuerEmergencyContact.fromJson)
        .toList();
    if (list.isEmpty) return null;
    return (list, DateTime.parse(syncedAtRaw));
  }
}

/// Judgment call (flagged explicitly per the task brief): `issuer_emergency_
/// contacts` is a real table with zero seed rows anywhere in this repo's
/// migrations — there is no verified real per-issuer hotline number this
/// codebase can honestly bundle. Fabricating a specific bank's "lost card"
/// number would be actively dangerous in a safety-critical screen if it
/// were wrong. The bundled fallback below therefore does NOT claim to be
/// issuer-specific data — it's the one thing that's true regardless of
/// which card someone holds (call the number on the back of the card first)
/// plus the card NETWORKS' own long-published global assistance lines
/// (Visa/Mastercard/RuPay), clearly labelled as general/network-level, not
/// this user's specific bank. This only ever shows when there's truly
/// nothing else (first run, offline, before any real sync) — the screen's
/// own banner says so explicitly rather than presenting this as equivalent
/// to live issuer data.
List<IssuerEmergencyContact> bundledEmergencyContactsFallback() {
  return const [
    IssuerEmergencyContact(
      id: 'bundled-generic-1',
      issuerName: 'Any issuer — first step',
      issuerSlug: 'generic',
      label: 'Call the number on the back of your card',
      phone: '',
      isInternational: false,
      isCollectCall: false,
      blockProcedure:
          'The fastest, most reliable way to block a lost/stolen card is always the number '
          'printed on the back of the physical card itself, or your bank\'s official app/'
          'website — this app has not yet downloaded your specific issuers\' hotline numbers.',
      sortOrder: 0,
    ),
    IssuerEmergencyContact(
      id: 'bundled-visa',
      issuerName: 'Visa (network-level, not your bank)',
      issuerSlug: 'visa-network',
      label: 'Visa Global Customer Assistance (collect call)',
      phone: '+1-303-967-1096',
      isInternational: true,
      isCollectCall: true,
      blockProcedure:
          'Visa can help locate your bank\'s emergency number or provide emergency cash/card '
          'replacement abroad, but cannot block your card directly — verify this number '
          'independently before relying on it; it is bundled general guidance, not confirmed '
          'live data.',
      sortOrder: 1,
    ),
    IssuerEmergencyContact(
      id: 'bundled-mastercard',
      issuerName: 'Mastercard (network-level, not your bank)',
      issuerSlug: 'mastercard-network',
      label: 'Mastercard Global Service (collect call)',
      phone: '+1-636-722-7111',
      isInternational: true,
      isCollectCall: true,
      blockProcedure:
          'Mastercard can help locate your bank\'s emergency number, but cannot block your '
          'card directly — verify this number independently before relying on it; it is '
          'bundled general guidance, not confirmed live data.',
      sortOrder: 2,
    ),
  ];
}

/// Orchestrates the "never blank, never network-dependent-at-the-moment-of-
/// need" contract G4 requires: try a live fetch (short timeout) and cache it
/// on success; on any failure fall back to whatever was last cached; if
/// nothing was ever cached (first run, offline, cold start — the hardest
/// case this whole group's plan calls out), fall back to the bundled
/// dataset above. This never throws — G4's provider is a FutureProvider
/// that always resolves to real content, so the screen's own ErrorState
/// path is reserved for genuine bugs, not "no network," which is the
/// expected, handled case here.
class EmergencyContactsService {
  final EmergencyContactsRepository repository;
  final EmergencyContactsCache cache;

  const EmergencyContactsService({required this.repository, required this.cache});

  Future<EmergencyContactsResult> load() async {
    try {
      final fresh = await repository.fetch();
      if (fresh.isNotEmpty) {
        await cache.save(fresh);
        return EmergencyContactsResult(
          contacts: fresh,
          source: EmergencyContactsSource.live,
          lastSyncedAt: DateTime.now(),
        );
      }
      // A real 200 with zero rows (nothing seeded server-side yet) is
      // distinct from a network failure — still worth falling through to
      // cache/bundled rather than showing an empty live result.
    } catch (_) {
      // Offline, timed out, or the server's unreachable — expected, not
      // exceptional. Fall through to cache/bundled below.
    }

    final cached = await cache.load();
    if (cached != null) {
      final (contacts, syncedAt) = cached;
      return EmergencyContactsResult(
        contacts: contacts,
        source: EmergencyContactsSource.cached,
        lastSyncedAt: syncedAt,
      );
    }

    return EmergencyContactsResult(
      contacts: bundledEmergencyContactsFallback(),
      source: EmergencyContactsSource.bundled,
      lastSyncedAt: null,
    );
  }
}
