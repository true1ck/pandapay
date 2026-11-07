import 'dart:async';
import 'package:flutter/services.dart';

/// What the owner may know about the phone number of someone who asked to
/// join. The default view is only a mask; a full number appears solely for
/// "look-alike" requests (server decides) or after an explicit, audited reveal.
///
/// Never log or persist an instance: [toString] is redacted on purpose, and
/// nothing in this library writes numbers to storage.
final class SharedClaimantPhone {
  final String source, consent;
  final String? countryCode, last4, mask, unavailableReason, numberStatus;
  final bool available, lookalike;
  final List<String> duplicateOf;
  final bool? matchesTyped;
  final String? _fullNumber;
  const SharedClaimantPhone._({
    required this.source,
    required this.consent,
    required this.available,
    required this.lookalike,
    required this.duplicateOf,
    this.countryCode,
    this.last4,
    this.mask,
    this.unavailableReason,
    this.numberStatus,
    this.matchesTyped,
    String? fullNumber,
    // ignore: prefer_initializing_formals
  }) : _fullNumber = fullNumber;

  /// Only present for look-alike items the server chose to expand.
  String? get fullNumber => _fullNumber;

  static const _consents = {'shared', 'declined', 'not_asked', 'none'};

  /// Returns null when the key is missing or malformed so the card falls back
  /// to the older suffix view instead of failing.
  static SharedClaimantPhone? tryParse(Object? value) {
    if (value is! Map) return null;
    try {
      final consent = value['consent'], source = value['source'];
      if (consent is! String ||
          !_consents.contains(consent) ||
          source is! String ||
          value['available'] is! bool) {
        return null;
      }
      String? text(String key, {int max = 40}) {
        final v = value[key];
        return v is String && v.isNotEmpty && v.length <= max ? v : null;
      }

      final last4 = text('last4', max: 4);
      final dup = value['duplicateOf'];
      final full = value['fullNumber'];
      final typed = value['matchesTyped'];
      return SharedClaimantPhone._(
        source: source,
        consent: consent,
        available: value['available'] as bool,
        lookalike: value['lookalike'] == true,
        duplicateOf: dup is List
            ? [
                for (final d in dup.take(20))
                  if (d is String) d,
              ]
            : const [],
        countryCode: text('countryCode', max: 6),
        last4: last4 != null && RegExp(r'^[0-9]{4}$').hasMatch(last4)
            ? last4
            : null,
        mask: text('mask'),
        unavailableReason: text('unavailableReason'),
        numberStatus: text('numberStatus', max: 16),
        matchesTyped: typed is bool ? typed : null,
        fullNumber: value['lookalike'] == true && full is String
            ? (RegExp(r'^\+[0-9]{7,15}$').hasMatch(full) ? full : null)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// A reveal is only offered for a number the claimant agreed to share.
  bool get canReveal => consent == 'shared' && available && !lookalike;

  @override
  String toString() => 'SharedClaimantPhone(redacted)';
}

/// The result of an explicit reveal. Lives only in widget state.
final class SharedRevealedPhone {
  final String _e164;
  const SharedRevealedPhone(this._e164);
  String get e164 => _e164;

  /// Digits with the leading +, for copying.
  String get copyText => _e164;
  @override
  String toString() => 'SharedRevealedPhone(redacted)';
}

const _nbsp = ' ';

/// "+91 72345 12345" with non-breaking spaces. [countryCode] (like "+91")
/// is used to split the number; without it the first digits are grouped.
String sharedFormatE164(String e164, {String? countryCode}) {
  if (!RegExp(r'^\+[0-9]{7,15}$').hasMatch(e164)) return e164;
  var cc = countryCode != null && e164.startsWith(countryCode)
      ? countryCode
      : e164.substring(0, 3);
  final national = e164.substring(cc.length);
  final groups = <String>[];
  if (national.length == 10) {
    groups
      ..add(national.substring(0, 5))
      ..add(national.substring(5));
  } else {
    for (var i = 0; i < national.length; i += 4) {
      groups.add(national.substring(i, (i + 4).clamp(0, national.length)));
    }
  }
  return [cc, ...groups].join(_nbsp);
}

/// Spoken form for screen readers: every digit on its own.
String sharedSpokenDigits(String text) => text
    .replaceAll(RegExp(r'[^0-9+]'), '')
    .split('')
    .map((c) {
      return c == '+' ? 'plus' : c;
    })
    .join(' ');

/// Positions (in the digits-only string of [full]) that differ from any of
/// [others] at the same position. Used to underline look-alike numbers.
Set<int> sharedDifferingDigits(String full, Iterable<String> others) {
  final mine = full.replaceAll(RegExp(r'[^0-9]'), '');
  final out = <int>{};
  for (final other in others) {
    final theirs = other.replaceAll(RegExp(r'[^0-9]'), '');
    for (var i = 0; i < mine.length; i++) {
      if (i >= theirs.length || mine[i] != theirs[i]) out.add(i);
    }
  }
  return out;
}

/// Copies a number and wipes the clipboard after [clearAfter] if it still holds
/// that value. The timer outlives any widget so leaving the screen cannot
/// leave the number on the clipboard.
class SharedClipboardGuard {
  static Timer? _timer;
  static Future<void> copyTemporarily(
    String value, {
    Duration clearAfter = const Duration(seconds: 60),
  }) async {
    await Clipboard.setData(ClipboardData(text: value));
    _timer?.cancel();
    _timer = Timer(clearAfter, () async {
      try {
        final now = await Clipboard.getData(Clipboard.kTextPlain);
        if (now?.text == value) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      } catch (_) {}
    });
  }
}
