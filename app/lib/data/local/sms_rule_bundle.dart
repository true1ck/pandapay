import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;

enum SmsRuleFamily {
  postedMovement,
  balanceSnapshot,
  billObligation,
  mandateLifecycle,
  ignoreNoise,
}

extension SmsRuleFamilyWire on SmsRuleFamily {
  static SmsRuleFamily? fromWire(String value) => switch (value) {
    'posted_movement' => SmsRuleFamily.postedMovement,
    'balance_snapshot' => SmsRuleFamily.balanceSnapshot,
    'bill_obligation' => SmsRuleFamily.billObligation,
    'mandate_lifecycle' => SmsRuleFamily.mandateLifecycle,
    'ignore_noise' => SmsRuleFamily.ignoreNoise,
    _ => null,
  };

  String get wireValue => switch (this) {
    SmsRuleFamily.postedMovement => 'posted_movement',
    SmsRuleFamily.balanceSnapshot => 'balance_snapshot',
    SmsRuleFamily.billObligation => 'bill_obligation',
    SmsRuleFamily.mandateLifecycle => 'mandate_lifecycle',
    SmsRuleFamily.ignoreNoise => 'ignore_noise',
  };
}

class RestrictedSmsRule {
  final String id;
  final SmsRuleFamily family;
  final String senderPattern;
  final String regexPattern;
  final Map<String, int> fieldMap;
  final Map<String, dynamic> defaultFields;
  final double confidence;
  final RegExp regExp;

  RestrictedSmsRule._({
    required this.id,
    required this.family,
    required this.senderPattern,
    required this.regexPattern,
    required this.fieldMap,
    required this.defaultFields,
    required this.confidence,
    required this.regExp,
  });

  static RestrictedSmsRule? fromJson(Map<String, dynamic> json) {
    try {
      final id = json['id'] as String?;
      if (id == null || id.length < 3 || id.length > 64) return null;
      final family = SmsRuleFamilyWire.fromWire(json['family'] as String? ?? '');
      if (family == null) return null;
      final senderPattern = (json['senderPattern'] as String?)?.trim();
      if (senderPattern == null || senderPattern.isEmpty || senderPattern.length > 100) return null;
      final regexPattern = json['regex'] as String?;
      if (regexPattern == null || regexPattern.isEmpty || regexPattern.length > 250) return null;

      // ReDoS checks
      if (RegExp(r'[+*?]\s*[+*?]').hasMatch(regexPattern)) return null;
      if (RegExp(r'\([^)]*[+*]\)[+*]').hasMatch(regexPattern)) return null;
      if (RegExp(r'\(\?:[^)]*[+*]\)[+*]').hasMatch(regexPattern)) return null;
      if (RegExp(r'\.\*.*?\.\*').hasMatch(regexPattern)) return null;

      // Safety check: ignore_noise must NEVER match financial keywords
      if (family == SmsRuleFamily.ignoreNoise) {
        final financialCheck = RegExp(
          r'\b(?:debited|credited|paid|spent|transferred|withdrawn|received|due date|amount due|available bal|avail bal)\b',
          caseSensitive: false,
        );
        if (financialCheck.hasMatch(regexPattern)) return null;
      }

      final regExp = RegExp(regexPattern, caseSensitive: false);
      // Dart's RegExp API does not expose the number of capture groups. Count
      // only ordinary capturing parentheses so a downloaded rule cannot ask
      // the parser for a group that does not exist. This is part of the
      // client-side bundle trust boundary; malformed rules are rejected as a
      // whole before they can run against an SMS.
      final captureGroups = _captureGroupCount(regexPattern);

      final rawFieldMap = json['fieldMap'];
      final fieldMap = <String, int>{};
      if (family != SmsRuleFamily.ignoreNoise) {
        if (rawFieldMap is! Map || rawFieldMap.isEmpty) return null;
        for (final entry in rawFieldMap.entries) {
          final val = entry.value;
          if (val is int && val > 0) {
            if (val > captureGroups) return null;
            fieldMap[entry.key.toString()] = val;
          } else {
            return null;
          }
        }
      }

      final defaultFields = (json['defaultFields'] as Map?)?.cast<String, dynamic>() ?? const {};
      final confidence = (json['confidence'] as num?)?.toDouble() ?? 0.98;

      return RestrictedSmsRule._(
        id: id,
        family: family,
        senderPattern: senderPattern,
        regexPattern: regexPattern,
        fieldMap: fieldMap,
        defaultFields: defaultFields,
        confidence: confidence.clamp(0.5, 1.0),
        regExp: regExp,
      );
    } catch (_) {
      return null;
    }
  }

  bool matchesSender(String sender) {
    final upperSender = sender.toUpperCase();
    final upperPattern = senderPattern.toUpperCase();
    if (upperSender.contains(upperPattern)) return true;
    try {
      return RegExp(senderPattern, caseSensitive: false).hasMatch(sender);
    } catch (_) {
      return false;
    }
  }

  static int _captureGroupCount(String pattern) {
    var count = 0;
    var escaped = false;
    var inClass = false;
    for (var i = 0; i < pattern.length; i++) {
      final code = pattern.codeUnitAt(i);
      final ch = String.fromCharCode(code);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == '\\') {
        escaped = true;
        continue;
      }
      if (ch == '[' && !inClass) {
        inClass = true;
        continue;
      }
      if (ch == ']' && inClass) {
        inClass = false;
        continue;
      }
      if (inClass || ch != '(') continue;
      // (?:...), (?=...), (?!...), (?<=...), (?<!...), and named/flagged
      // groups beginning with (? are non-capturing for this DSL. Dart does
      // not support every PCRE form, but treating unknown (? forms as
      // non-capturing makes validation fail closed.
      final next = i + 1 < pattern.length ? pattern[i + 1] : '';
      if (next != '?') count++;
    }
    return count;
  }
}

class SmsRuleBundle {
  final int bundleVersion;
  final String sha256;
  final DateTime publishedAt;
  final String minClientVersion;
  final List<RestrictedSmsRule> rules;

  const SmsRuleBundle({
    required this.bundleVersion,
    required this.sha256,
    required this.publishedAt,
    required this.minClientVersion,
    required this.rules,
  });

  static String computeSha256({
    required int bundleVersion,
    required String minClientVersion,
    required List<Map<String, dynamic>> rawRules,
  }) {
    final normalized = rawRules.map((r) => {
      'id': r['id'].toString(),
      'family': r['family'].toString(),
      'senderPattern': r['senderPattern'].toString().trim(),
      'regex': r['regex'].toString(),
      'fieldMap': (r['fieldMap'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
      'defaultFields': (r['defaultFields'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
      'confidence': (r['confidence'] as num?)?.toDouble() ?? 0.98,
    }).toList()
      ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));

    final canonical = jsonEncode({
      'bundleVersion': bundleVersion,
      'minClientVersion': minClientVersion,
      'rules': normalized,
    });
    return crypto.sha256.convert(utf8.encode(canonical)).toString();
  }

  static SmsRuleBundle? fromJson(Map<String, dynamic> json, {bool verifySha = true}) {
    try {
      final bundleVersion = json['bundleVersion'] as int?;
      if (bundleVersion == null || bundleVersion < 1) return null;
      final expectedSha = (json['sha256'] as String?)?.toLowerCase().trim();
      if (expectedSha == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSha)) return null;

      final rawRules = json['rules'] as List?;
      if (rawRules == null) return null;

      final minClientVersion = (json['minClientVersion'] as String?) ?? '1.0.0';
      if (!RegExp(r'^\d+(?:\.\d+){0,3}$').hasMatch(minClientVersion)) return null;

      if (verifySha) {
        final rawMapList = rawRules.map((r) => Map<String, dynamic>.from(r as Map)).toList();
        final computedSha = computeSha256(
          bundleVersion: bundleVersion,
          minClientVersion: minClientVersion,
          rawRules: rawMapList,
        );
        if (computedSha != expectedSha) {
          return null; // Cryptographic integrity check failed!
        }
      }

      final rules = <RestrictedSmsRule>[];
      for (final r in rawRules) {
        if (r is Map<String, dynamic>) {
          final rule = RestrictedSmsRule.fromJson(r);
          if (rule == null) return null; // Reject entire bundle if any rule is invalid
          rules.add(rule);
        } else if (r is Map) {
          final rule = RestrictedSmsRule.fromJson(r.cast<String, dynamic>());
          if (rule == null) return null;
          rules.add(rule);
        } else {
          return null;
        }
      }

      final publishedAtStr = json['publishedAt'] as String?;
      final publishedAt = publishedAtStr != null
          ? (DateTime.tryParse(publishedAtStr) ?? DateTime.now())
          : DateTime.now();

      return SmsRuleBundle(
        bundleVersion: bundleVersion,
        sha256: expectedSha,
        publishedAt: publishedAt,
        minClientVersion: minClientVersion,
        rules: List.unmodifiable(rules),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A server-assigned candidate rule. Shadow candidates are evaluated locally
/// for comparison only; limited/expanded candidates may supply the primary
/// classification for the assigned cohort.
class SmsCandidateRuleBundle {
  final String candidateId;
  final String stage;
  final String mode;
  /// Server-issued assignment identity. It lets delayed offline exposure
  /// events be verified against the assignment that was actually delivered.
  final String? assignmentId;
  final int stageVersion;
  final SmsRuleBundle bundle;

  const SmsCandidateRuleBundle({
    required this.candidateId,
    required this.stage,
    required this.mode,
    this.assignmentId,
    this.stageVersion = 1,
    required this.bundle,
  });

  static SmsCandidateRuleBundle? fromJson(Map<String, dynamic> json) {
    try {
      final id = json['candidateId'] as String?;
      final stage = json['stage'] as String?;
      final mode = json['mode'] as String?;
      if (id == null || stage == null || mode == null) return null;
      if (!const {'shadow', 'limited', 'expanded', 'active'}.contains(stage)) return null;
      if (!const {'shadow', 'apply'}.contains(mode)) return null;
      final stageVersion = (json['stageVersion'] ?? json['stage_version'] ?? 1) as int?;
      if (stageVersion == null || stageVersion < 1) return null;
      final assignmentId = json['assignmentId'] as String? ?? json['assignment_id'] as String?;
      if (assignmentId != null && (assignmentId.isEmpty || assignmentId.length > 80)) return null;
      final bundle = SmsRuleBundle.fromJson(json, verifySha: true);
      if (bundle == null || bundle.rules.isEmpty) return null;
      return SmsCandidateRuleBundle(
        candidateId: id,
        stage: stage,
        mode: mode,
        assignmentId: assignmentId,
        stageVersion: stageVersion,
        bundle: bundle,
      );
    } catch (_) {
      return null;
    }
  }
}
