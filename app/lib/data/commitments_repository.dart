import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/design/app_theme.dart';
import 'local/app_database.dart';

enum CommitmentCategory {
  utility,
  telecom,
  insurance,
  loanOrEmi,
  rent,
  education,
  tax,
  subscription,
  other;

  String get label => switch (this) {
    CommitmentCategory.utility => 'Utility',
    CommitmentCategory.telecom => 'Telecom & Broadband',
    CommitmentCategory.insurance => 'Insurance / Policy',
    CommitmentCategory.loanOrEmi => 'Loan / EMI',
    CommitmentCategory.rent => 'Rent & Maintenance',
    CommitmentCategory.education => 'Education',
    CommitmentCategory.tax => 'Tax & Government',
    CommitmentCategory.subscription => 'Subscription',
    CommitmentCategory.other => 'Other',
  };

  IconData get icon => switch (this) {
    CommitmentCategory.utility => Icons.bolt_rounded,
    CommitmentCategory.telecom => Icons.wifi_rounded,
    CommitmentCategory.insurance => Icons.health_and_safety_outlined,
    CommitmentCategory.loanOrEmi => Icons.account_balance_wallet_outlined,
    CommitmentCategory.rent => Icons.home_work_outlined,
    CommitmentCategory.education => Icons.school_outlined,
    CommitmentCategory.tax => Icons.account_balance_outlined,
    CommitmentCategory.subscription => Icons.autorenew_rounded,
    CommitmentCategory.other => Icons.receipt_outlined,
  };

  Color get iconBg => switch (this) {
    CommitmentCategory.utility => const Color(0xFFFFF3E0),
    CommitmentCategory.telecom => const Color(0xFFE3F2FD),
    CommitmentCategory.insurance => const Color(0xFFE8F5E9),
    CommitmentCategory.loanOrEmi => const Color(0xFFF3E5F5),
    CommitmentCategory.rent => const Color(0xFFEFEBE9),
    CommitmentCategory.education => const Color(0xFFFFFDE7),
    CommitmentCategory.tax => const Color(0xFFECEFF1),
    CommitmentCategory.subscription => BambooInk.rankBadgeBg,
    CommitmentCategory.other => BambooInk.paperMuted,
  };

  Color get iconColor => switch (this) {
    CommitmentCategory.utility => const Color(0xFFE65100),
    CommitmentCategory.telecom => const Color(0xFF1565C0),
    CommitmentCategory.insurance => BambooInk.jade,
    CommitmentCategory.loanOrEmi => const Color(0xFF7B1FA2),
    CommitmentCategory.rent => const Color(0xFF5D4037),
    CommitmentCategory.education => const Color(0xFFF57F17),
    CommitmentCategory.tax => const Color(0xFF455A64),
    CommitmentCategory.subscription => BambooInk.rankBadgeInk,
    CommitmentCategory.other => BambooInk.ink700,
  };

  static CommitmentCategory fromSender(String sender) {
    return fromText(sender);
  }

  static CommitmentCategory fromText(String text) {
    final s = text.toUpperCase();
    bool has(String token) => RegExp(
      r'(?<![A-Z0-9])' + RegExp.escape(token) + r'(?![A-Z0-9])',
    ).hasMatch(s);
    if (has('LIC') ||
        has('INSURANCE') ||
        has('INSURER') ||
        has('MAXLIFE') ||
        has('LICIND') ||
        has('HDFCLIFE') ||
        has('ICICIPRU') ||
        has('STARHEALTH') ||
        has('LOMBARD') ||
        has('BAJAJ ALLIANZ') ||
        has('TATA AIG') ||
        has('SBI GENERAL') ||
        has('NEW INDIA') ||
        has('POLICY')) {
      return CommitmentCategory.insurance;
    }
    if (has('SUBSCRIPTION') ||
        has('MEMBERSHIP') ||
        has('GOOGLE PLAY') ||
        has('NETFLIX') ||
        has('SPOTIFY') ||
        has('APPLE.COM') ||
        has('AMAZON PRIME') ||
        has('OPENAI')) {
      return CommitmentCategory.subscription;
    }
    if (has('AIRTEL') ||
        has('JIO') ||
        has('VODAFONE') ||
        has('IDEA') ||
        has('BSNL') ||
        has('ACT') ||
        has('FIBER') ||
        has('BROADBAND') ||
        has('ALEGRA') ||
        has('TNBPAY')) {
      return CommitmentCategory.telecom;
    }
    if (has('BESCOM') ||
        has('TNEB') ||
        has('MSEDCL') ||
        has('ELECTRIC') ||
        has('POWER') ||
        has('GAS') ||
        has('WATER') ||
        has('BWSSB') ||
        has('ELECTRICITY')) {
      return CommitmentCategory.utility;
    }
    if (has('LOAN') || has('EMI') || has('FINANCE')) {
      return CommitmentCategory.loanOrEmi;
    }
    if (has('RENT') || has('MYGATE') || has('NOBROKER')) {
      return CommitmentCategory.rent;
    }
    if (has('PENSION') || has('YOJANA') || has('TAX') || has('GOVT')) {
      return CommitmentCategory.tax;
    }
    return CommitmentCategory.other;
  }
}

enum CommitmentCadence {
  oneTime,
  monthly,
  quarterly,
  halfYearly,
  annual;

  String get label => switch (this) {
    CommitmentCadence.oneTime => 'One-time',
    CommitmentCadence.monthly => 'Monthly',
    CommitmentCadence.quarterly => 'Quarterly',
    CommitmentCadence.halfYearly => 'Half-yearly',
    CommitmentCadence.annual => 'Annual',
  };
}

enum CommitmentStatus {
  due,
  inGracePeriod,
  paymentNotDetected,
  paid,
  needsConfirmation,
  dismissed,
}

enum CommitmentSource { sms, manual, statement }

/// Durable model for household bills, renewals, and recurring commitments.
/// Uses [Money] integer paise representation to eliminate floating-point drift.
class Commitment {
  final String id;
  final String title;
  final CommitmentCategory category;
  final Money? amount;
  final DateTime dueOn;
  final String? identifier; // Masked policy #, consumer ID, or account #
  final CommitmentCadence cadence;
  final int? anchorDay;
  final int? gracePeriodDays; // Policy-specific evidence only; never assumed
  final DateTime? renewalDate;
  final CommitmentStatus status;
  final CommitmentSource source;
  final DateTime? paidOn;
  final String? linkedTransactionId;
  final bool isUserConfirmed;
  final double confidence;

  const Commitment({
    required this.id,
    required this.title,
    required this.category,
    this.amount,
    required this.dueOn,
    this.identifier,
    this.cadence = CommitmentCadence.monthly,
    this.anchorDay,
    this.gracePeriodDays,
    this.renewalDate,
    this.status = CommitmentStatus.due,
    this.source = CommitmentSource.sms,
    this.paidOn,
    this.linkedTransactionId,
    this.isUserConfirmed = false,
    this.confidence = 1.0,
  });

  Commitment copyWith({
    String? id,
    String? title,
    CommitmentCategory? category,
    Money? amount,
    DateTime? dueOn,
    String? identifier,
    CommitmentCadence? cadence,
    int? anchorDay,
    int? gracePeriodDays,
    DateTime? renewalDate,
    CommitmentStatus? status,
    CommitmentSource? source,
    DateTime? paidOn,
    String? linkedTransactionId,
    bool? isUserConfirmed,
    double? confidence,
  }) {
    return Commitment(
      id: id ?? this.id,
      title: title ?? this.title,
      category: category ?? this.category,
      amount: amount ?? this.amount,
      dueOn: dueOn ?? this.dueOn,
      identifier: identifier ?? this.identifier,
      cadence: cadence ?? this.cadence,
      anchorDay: anchorDay ?? this.anchorDay,
      gracePeriodDays: gracePeriodDays ?? this.gracePeriodDays,
      renewalDate: renewalDate ?? this.renewalDate,
      status: status ?? this.status,
      source: source ?? this.source,
      paidOn: paidOn ?? this.paidOn,
      linkedTransactionId: linkedTransactionId ?? this.linkedTransactionId,
      isUserConfirmed: isUserConfirmed ?? this.isUserConfirmed,
      confidence: confidence ?? this.confidence,
    );
  }

  // ---------------------------------------------------------------------------
  // Dynamic computed fields (calculated against Clock / now — zero stored drift)
  // ---------------------------------------------------------------------------

  int daysUntilDue(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(dueOn.year, dueOn.month, dueOn.day);
    return target.difference(today).inDays;
  }

  bool isDueToday(DateTime now) => daysUntilDue(now) == 0;

  DateTime? get gracePeriodEndsOn {
    if (gracePeriodDays == null || gracePeriodDays! <= 0) return null;
    return dueOn.add(Duration(days: gracePeriodDays!));
  }

  bool isWithinGracePeriod(DateTime now) {
    final graceEnd = gracePeriodEndsOn;
    if (graceEnd == null) return false;
    final today = DateTime(now.year, now.month, now.day);
    return today.isAfter(dueOn) && !today.isAfter(graceEnd);
  }

  int? daysRemainingInGrace(DateTime now) {
    final graceEnd = gracePeriodEndsOn;
    if (graceEnd == null) return null;
    final today = DateTime(now.year, now.month, now.day);
    return graceEnd.difference(today).inDays;
  }

  bool isPastGrace(DateTime now) {
    final graceEnd = gracePeriodEndsOn;
    if (graceEnd == null) return daysUntilDue(now) < 0;
    final today = DateTime(now.year, now.month, now.day);
    return today.isAfter(graceEnd);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'category': category.name,
    'amount_paise': amount?.paise,
    'due_on': dueOn.toIso8601String(),
    'identifier': identifier,
    'cadence': cadence.name,
    'anchor_day': anchorDay,
    'grace_period_days': gracePeriodDays,
    'renewal_date': renewalDate?.toIso8601String(),
    'status': status.name,
    'source': source.name,
    'paid_on': paidOn?.toIso8601String(),
    'linked_transaction_id': linkedTransactionId,
    'is_user_confirmed': isUserConfirmed,
    'confidence': confidence,
  };

  factory Commitment.fromJson(Map<String, dynamic> json) {
    return Commitment(
      id: json['id'] as String,
      title: json['title'] as String,
      category: CommitmentCategory.values.firstWhere(
        (c) => c.name == json['category'],
        orElse: () => CommitmentCategory.other,
      ),
      amount: json['amount_paise'] != null
          ? Money.fromPaise((json['amount_paise'] as num).toInt())
          : null,
      dueOn: DateTime.parse(json['due_on'] as String),
      identifier: json['identifier'] as String?,
      cadence: CommitmentCadence.values.firstWhere(
        (c) => c.name == json['cadence'],
        orElse: () => CommitmentCadence.monthly,
      ),
      anchorDay: (json['anchor_day'] as num?)?.toInt(),
      gracePeriodDays: (json['grace_period_days'] as num?)?.toInt(),
      renewalDate: json['renewal_date'] != null
          ? DateTime.parse(json['renewal_date'] as String)
          : null,
      status: CommitmentStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => CommitmentStatus.due,
      ),
      source: CommitmentSource.values.firstWhere(
        (s) => s.name == json['source'],
        orElse: () => CommitmentSource.sms,
      ),
      paidOn: json['paid_on'] != null
          ? DateTime.parse(json['paid_on'] as String)
          : null,
      linkedTransactionId: json['linked_transaction_id'] as String?,
      isUserConfirmed: json['is_user_confirmed'] as bool? ?? false,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

const _commitmentsStorageKey = 'pandapay_app.commitments_v1';

/// Offline-first repository for bills and commitments.
/// Saves to durable on-device storage so commitments survive app reboots.
class CommitmentsRepository {
  final String namespace;
  final Future<AppDatabase> Function()? loadDatabase;

  CommitmentsRepository({this.namespace = 'legacy', this.loadDatabase});

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  String get _storageKey => '$_commitmentsStorageKey:$namespace';

  Future<AppDatabase?> _database() async {
    if (loadDatabase == null) return null;
    final db = await loadDatabase!();
    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_commitments ('
      'namespace TEXT NOT NULL, '
      'id TEXT NOT NULL, '
      'payload TEXT NOT NULL, '
      'PRIMARY KEY (namespace, id)'
      ')',
    );
    final prefs = await _prefs;
    final raw = prefs.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          final c = Commitment.fromJson(item as Map<String, dynamic>);
          db.db.execute(
            'INSERT OR REPLACE INTO local_commitments VALUES (?, ?, ?)',
            [namespace, c.id, jsonEncode(c.toJson())],
          );
        }
        await prefs.remove(_storageKey);
      } catch (_) {}
    }
    return db;
  }

  Future<List<Commitment>> fetchAll() async {
    if (loadDatabase != null) {
      final db = await _database();
      if (db != null) {
        final rows = db.db.select(
          'SELECT payload FROM local_commitments WHERE namespace = ?',
          [namespace],
        );
        return rows
            .map(
              (r) => Commitment.fromJson(
                jsonDecode(r['payload'] as String) as Map<String, dynamic>,
              ),
            )
            .toList();
      }
    }
    final prefs = await _prefs;
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((item) => Commitment.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(Commitment commitment) async {
    final list = await fetchAll();
    final index = list.indexWhere((c) => c.id == commitment.id);
    final updated = List<Commitment>.from(list);
    if (index >= 0) {
      updated[index] = commitment;
    } else {
      updated.add(commitment);
    }
    await _persist(updated);
  }

  /// Marks a commitment as paid, recording paidOn and advancing recurring cycle.
  Future<void> markAsPaid(
    String id, {
    DateTime? paidOn,
    String? linkedTxnId,
    Commitment? detectedCommitment,
  }) async {
    final list = await fetchAll();
    final index = list.indexWhere((c) => c.id == id);
    final target = index < 0 ? detectedCommitment : list[index];
    if (target == null) return;
    final paymentDate = paidOn ?? DateTime.now();

    final updated = List<Commitment>.from(list);

    if (target.cadence == CommitmentCadence.oneTime) {
      final paid = target.copyWith(
        status: CommitmentStatus.paid,
        paidOn: paymentDate,
        linkedTransactionId: linkedTxnId,
      );
      if (index < 0) {
        updated.add(paid);
      } else {
        updated[index] = paid;
      }
    } else {
      // Advance to next recurring period so recurring commitment lives on
      var nextDue = _advanceCadence(
        target.dueOn,
        target.cadence,
        target.anchorDay,
      );
      final paidDay = DateTime(
        paymentDate.year,
        paymentDate.month,
        paymentDate.day,
      );
      // An old reminder may be marked paid much later. Never leave its
      // next cycle in the past after the user's confirmation.
      while (!nextDue.isAfter(paidDay)) {
        nextDue = _advanceCadence(nextDue, target.cadence, target.anchorDay);
      }
      final rolledForward = target.copyWith(
        dueOn: nextDue,
        anchorDay: target.anchorDay ?? target.dueOn.day,
        status: CommitmentStatus.due,
        paidOn: paymentDate,
        linkedTransactionId: linkedTxnId,
      );
      if (index < 0) {
        updated.add(rolledForward);
      } else {
        updated[index] = rolledForward;
      }
    }

    await _persist(updated);
  }

  Future<void> delete(String id) async {
    if (loadDatabase != null) {
      final db = await _database();
      if (db != null) {
        db.db.execute(
          'DELETE FROM local_commitments WHERE namespace = ? AND id = ?',
          [namespace, id],
        );
        return;
      }
    }
    final list = await fetchAll();
    final updated = list.where((c) => c.id != id).toList();
    await _persist(updated);
  }

  /// Keeps a durable tombstone for an automatically detected commitment so
  /// the same SMS evidence does not recreate it on the next provider refresh.
  Future<void> dismiss(String id) async {
    final list = await fetchAll();
    final index = list.indexWhere((c) => c.id == id);
    if (index < 0) return;
    final updated = List<Commitment>.from(list);
    updated[index] = updated[index].copyWith(
      status: CommitmentStatus.dismissed,
    );
    await _persist(updated);
  }

  Future<void> _persist(List<Commitment> items) async {
    if (loadDatabase != null) {
      final db = await _database();
      if (db != null) {
        db.db.execute(
          'DELETE FROM local_commitments WHERE namespace = ?',
          [namespace],
        );
        for (final item in items) {
          db.db.execute(
            'INSERT OR REPLACE INTO local_commitments VALUES (?, ?, ?)',
            [namespace, item.id, jsonEncode(item.toJson())],
          );
        }
        return;
      }
    }
    final prefs = await _prefs;
    final encoded = jsonEncode(items.map((i) => i.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
  }

  DateTime _advanceCadence(
    DateTime from,
    CommitmentCadence cadence,
    int? anchorDay,
  ) {
    final day = anchorDay ?? from.day;
    return switch (cadence) {
      CommitmentCadence.monthly => _clampMonth(from.year, from.month + 1, day),
      CommitmentCadence.quarterly => _clampMonth(
        from.year,
        from.month + 3,
        day,
      ),
      CommitmentCadence.halfYearly => _clampMonth(
        from.year,
        from.month + 6,
        day,
      ),
      CommitmentCadence.annual => _clampMonth(from.year + 1, from.month, day),
      CommitmentCadence.oneTime => from,
    };
  }

  DateTime _clampMonth(int year, int month, int day) {
    final lastDay = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, day > lastDay ? lastDay : day);
  }
}
