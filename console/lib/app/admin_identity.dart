import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/private_admin_auth.dart';
import 'admin_design.dart';
import 'providers.dart';

/// Which backend the console is talking to, as reported by the gateway's
/// `ADMIN_ENVIRONMENT`. Local and production both serve on localhost:8443
/// (production through the SSH tunnel), so the UI must never let them blur.
enum AdminEnvironment { local, staging, production, unknown }

AdminEnvironment parseAdminEnvironment(String? value) {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'local':
    case 'development':
    case 'dev':
      return AdminEnvironment.local;
    case 'staging':
      return AdminEnvironment.staging;
    case 'production':
    case 'prod':
      return AdminEnvironment.production;
    default:
      return AdminEnvironment.unknown;
  }
}

extension AdminEnvironmentLook on AdminEnvironment {
  String get label => switch (this) {
    AdminEnvironment.local => 'Local',
    AdminEnvironment.staging => 'Staging',
    AdminEnvironment.production => 'Production',
    AdminEnvironment.unknown => 'Unverified environment',
  };

  /// Production is clay (danger), staging amber, local jade, unknown amber.
  Color get tone => switch (this) {
    AdminEnvironment.local => AdminColors.jade,
    AdminEnvironment.staging => AdminColors.amber,
    AdminEnvironment.production => AdminColors.clay,
    AdminEnvironment.unknown => AdminColors.amber,
  };

  /// Shown as a persistent strip on every screen. Local needs no strip.
  String? get bannerMessage => switch (this) {
    AdminEnvironment.local => null,
    AdminEnvironment.staging =>
      'STAGING · Changes affect the staging database, not live users.',
    AdminEnvironment.production =>
      'PRODUCTION · Changes here affect live PandaPay users.',
    AdminEnvironment.unknown =>
      'The gateway did not report its environment. Treat this as production.',
  };
}

/// Read permission each console screen needs, mirroring the API route
/// manifest (`api/src/admin/route_manifest.js`). Used to hide screens and
/// overview tiles the role cannot open; the server still enforces access.
const kDestinationPermissions = <String, String>{
  'Catalogue': 'catalogue.read',
  'Card Requests': 'operations.read',
  'Error Reports': 'support.evidence.read',
  'Support Tickets': 'support.evidence.read',
  'Policy Alerts': 'operations.read',
  'Merchants': 'catalogue.read',
  'Conflicts': 'operations.read',
  'Acceptance & Rates': 'catalogue.read',
  'System Status': 'operations.read',
  'Data Quality': 'operations.read',
  'Anonymization Audit': 'admin.audit.read',
  'Parser Patterns': 'catalogue.read',
  'SMS Rule Approvals': 'learning.read',
  'SMS Pipeline Rules': 'learning.read',
  'Sources': 'operations.read',
  'Scrape Diff Review': 'operations.read',
  'Referral Operations': 'referrals.read',
};

/// The signed-in administrator as reported by the private gateway session.
///
/// The server checks every permission on every request; this class only
/// decides what to show. `permissions == null` means the console could not
/// read them (native/legacy mode), so nothing is hidden and the server's
/// refusal remains the source of truth.
class AdminIdentity {
  const AdminIdentity({
    required this.role,
    required this.environment,
    this.email,
    this.permissions,
  });

  final String? email;
  final String role;
  final AdminEnvironment environment;
  final Set<String>? permissions;

  bool can(String? permission) =>
      permission == null ||
      permissions == null ||
      permissions!.contains(permission);

  static AdminIdentity fromSession(Map<String, dynamic>? admin) {
    final rawPermissions = admin?['permissions'];
    return AdminIdentity(
      email: admin?['email'] as String?,
      role: (admin?['role'] ?? 'admin').toString(),
      environment: admin == null
          ? AdminEnvironment.unknown
          : parseAdminEnvironment(admin['environment']?.toString()),
      permissions: rawPermissions is List
          ? rawPermissions.map((p) => p.toString()).toSet()
          : null,
    );
  }
}

/// Recomputed whenever the session changes (sign-in, resume, sign-out).
final adminIdentityProvider = Provider<AdminIdentity>((ref) {
  ref.watch(accessTokenProvider);
  final auth = ref.watch(authApiProvider);
  return AdminIdentity.fromSession(
    auth is PrivateAdminAuthApi ? auth.administrator : null,
  );
});

/// Persistent strip under the top bar for every non-local environment.
class EnvironmentBanner extends StatelessWidget {
  const EnvironmentBanner({required this.environment, super.key});

  final AdminEnvironment environment;

  @override
  Widget build(BuildContext context) {
    final message = environment.bannerMessage;
    if (message == null) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      label: message,
      child: Container(
        width: double.infinity,
        color: environment.tone,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Colors.white,
              size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
