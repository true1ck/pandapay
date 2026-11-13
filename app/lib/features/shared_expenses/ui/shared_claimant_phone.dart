import 'dart:async';
import 'package:flutter/material.dart';
import '../../../app/design/app_theme.dart';
import '../data/shared_directory.dart';
import '../data/shared_phone_display.dart';
import '../data/shared_transport.dart';

/// Phone details on an owner's join request card: consent chip, masked
/// number, optional "look alike" full number, and an audited "Show full
/// number". A revealed number lives only in this widget's state, hides after
/// 60 seconds or when the app is backgrounded, and is never logged or stored.
class SharedClaimantPhoneView extends StatefulWidget {
  final SharedJoinRequest request;

  /// Other pending requests of the same owner, to underline differing digits.
  final List<SharedJoinRequest> siblings;
  final Future<SharedRevealedPhone> Function() onReveal;
  final Duration autoHide;
  const SharedClaimantPhoneView({
    super.key,
    required this.request,
    required this.onReveal,
    this.siblings = const [],
    this.autoHide = const Duration(seconds: 60),
  });
  @override
  State<SharedClaimantPhoneView> createState() => _ViewState();
}

class _ViewState extends State<SharedClaimantPhoneView>
    with WidgetsBindingObserver {
  SharedRevealedPhone? _revealed;
  Timer? _timer;
  bool _loading = false, _copied = false, _lookalikeSecure = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.request.claimantPhone?.fullNumber != null) {
      _lookalikeSecure = true;
      unawaited(SharedSecureScreen.acquire());
    }
  }

  @override
  void didUpdateWidget(covariant SharedClaimantPhoneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refresh can make a row a look-alike (or stop being one) after it was
    // first drawn; the screen-capture block must follow.
    final now = widget.request.claimantPhone?.fullNumber != null;
    if (now && !_lookalikeSecure) {
      _lookalikeSecure = true;
      unawaited(SharedSecureScreen.acquire());
    } else if (!now && _lookalikeSecure) {
      _lookalikeSecure = false;
      unawaited(SharedSecureScreen.release());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    if (_revealed != null) unawaited(SharedSecureScreen.release());
    if (_lookalikeSecure) unawaited(SharedSecureScreen.release());
    _revealed = null;
    unawaited(SharedClipboardGuard.clearNow());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive covers the app switcher and permission/system overlays. The
    // shown number is hidden at once, but a number the owner just copied stays
    // on the clipboard until its own 60 s timer: wiping it as they switched to
    // WhatsApp to paste it made Copy useless.
    if (state != AppLifecycleState.resumed) _hide(keepClipboard: true);
  }

  void _hide({bool keepClipboard = false}) {
    _timer?.cancel();
    if (!keepClipboard) unawaited(SharedClipboardGuard.clearNow());
    if (_revealed != null) unawaited(SharedSecureScreen.release());
    if (mounted && (_revealed != null || _copied)) {
      setState(() {
        _revealed = null;
        _copied = false;
      });
    } else {
      _revealed = null;
    }
  }

  static String _message(Object error) {
    if (error is SharedTransportException) {
      if (error.code == 'owner_phone_required') {
        return 'Add and verify your own phone number to view numbers.';
      }
      if (error.statusCode == 429 || error.code == 'reveal_rate_limited') {
        return 'You have viewed several numbers recently. Please try again later.';
      }
      if (error.statusCode == 409 || error.code == 'phone_not_available') {
        return 'This number is no longer available to view.';
      }
      if (error.statusCode == 403 || error.code == 'context_not_authorized') {
        return 'Only the owner of this split can view the number.';
      }
      if (error.code == 'network_unavailable') {
        return 'No connection. Try again when online.';
      }
    }
    return 'Could not show the number. Please try again.';
  }

  Future<void> _reveal() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.onReveal();
      if (!mounted) return;
      _timer?.cancel();
      _timer = Timer(widget.autoHide, _hide);
      // Not awaited: the number must never wait on the native call.
      unawaited(SharedSecureScreen.acquire());
      setState(() {
        _revealed = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _message(error);
      });
    }
  }

  Future<void> _copy() async {
    final value = _revealed?.copyText;
    if (value == null) return;
    await SharedClipboardGuard.copyTemporarily(value);
    if (!mounted) return;
    setState(() => _copied = true);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Number copied. It clears in a minute.')),
    );
  }

  String _consentChip(SharedClaimantPhone p) {
    if (p.unavailableReason == 'claimed_before_update') {
      return 'Details not available for this older request';
    }
    return switch (p.consent) {
      'shared' => 'Shared a number',
      'declined' => 'Did not share a number',
      'none' => 'Number not verified',
      _ => 'Details not available for this older request',
    };
  }

  /// Digits as one LTR run, differing ones underlined.
  Widget _digits(String text, Set<int> differing, TextStyle style) {
    final spans = <InlineSpan>[];
    var digit = 0;
    for (final ch in text.split('')) {
      final isDigit = RegExp(r'[0-9]').hasMatch(ch);
      final bad = isDigit && differing.contains(digit);
      if (isDigit) digit++;
      spans.add(
        TextSpan(
          text: ch,
          style: bad
              ? const TextStyle(
                  decoration: TextDecoration.underline,
                  fontWeight: FontWeight.w800,
                )
              : null,
        ),
      );
    }
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text.rich(TextSpan(children: spans, style: style)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = widget.request.claimantPhone;
    if (phone == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final small = BambooFonts.ui(12, color: scheme.onSurfaceVariant);
    final numberStyle = BambooFonts.ui(
      14,
      weight: FontWeight.w700,
      color: scheme.onSurface,
    ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final full = _revealed?.e164 ?? phone.fullNumber;
    final others = [
      for (final s in widget.siblings)
        if (s.invitationId.toLowerCase() !=
                widget.request.invitationId.toLowerCase() &&
            s.claimantPhone?.mask == phone.mask &&
            s.claimantPhone?.fullNumber != null)
          s.claimantPhone!.fullNumber!,
    ];
    final differing = phone.lookalike && phone.fullNumber != null
        ? sharedDifferingDigits(phone.fullNumber!, others)
        : <int>{};
    final shown = full != null
        ? sharedFormatE164(full, countryCode: phone.countryCode)
        : phone.mask?.replaceAll(' ', ' ');
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _consentChip(phone),
            key: const Key('consent-chip'),
            style: small,
          ),
          if (shown != null && phone.consent == 'shared')
            Semantics(
              label: full != null
                  ? 'Phone number ${sharedSpokenDigits(full)}'
                  : phone.last4 == null
                  ? 'Phone number partly hidden'
                  : 'Phone number ending ${phone.last4!.split('').join(' ')}, partly hidden',
              excludeSemantics: true,
              child: _digits(shown, differing, numberStyle),
            ),
          if (phone.lookalike && phone.fullNumber == null && _revealed == null)
            Text(
              'Full number not shown here. Tap to show.',
              key: const Key('lookalike-tap-to-show'),
              style: small,
            ),
          if (phone.lookalike)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'These two look alike. Check the full numbers.',
                key: const Key('lookalike-warning'),
                style: BambooFonts.ui(12.5, color: scheme.error),
              ),
            ),
          if (phone.duplicateOf.isNotEmpty)
            Text(
              'Same number as another request.',
              style: BambooFonts.ui(12.5, color: scheme.error),
            ),
          if (phone.numberStatus == 'moved')
            Text(
              'This number now belongs to a different account.',
              key: const Key('number-moved'),
              style: BambooFonts.ui(12.5, color: scheme.error),
            ),
          if (_error != null)
            Text(
              _error!,
              key: const Key('reveal-error'),
              style: BambooFonts.ui(12.5, color: scheme.error),
            ),
          if (phone.canReveal)
            Wrap(
              children: [
                if (_revealed == null)
                  TextButton(
                    key: const Key('reveal-phone'),
                    onPressed: _loading ? null : _reveal,
                    child: Text(
                      _loading ? 'Loading…' : 'Show full number',
                      style: BambooFonts.ui(13),
                    ),
                  )
                else ...[
                  TextButton(
                    key: const Key('copy-phone'),
                    onPressed: _copy,
                    child: Text(
                      _copied ? 'Copied' : 'Copy',
                      style: BambooFonts.ui(13),
                    ),
                  ),
                  TextButton(
                    key: const Key('hide-phone'),
                    onPressed: _hide,
                    child: Text('Hide', style: BambooFonts.ui(13)),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}
