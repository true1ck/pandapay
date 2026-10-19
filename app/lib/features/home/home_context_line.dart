import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../geofence/nearby_merchants_repository.dart';
import 'home_screen.dart' show HomeScreen;

enum _ContextState { locating, searching, found, noPermission, noMatch, offlineOrError }

/// ui-spec B1.1 context line — *"You're at DMart Powai"* / *"Near Indian
/// Oil"* / *"Pick a category"* — a thin presentation layer over the SAME
/// foreground one-shot location read + matching machinery
/// app/lib/features/geofence/nearby_merchants_screen.dart already built
/// (`nearbyMerchantsRepositoryProvider`, `findNearbyMerchants`). See that
/// file's header comment for the explicit "not always-on background
/// geofencing" scope note, which applies here identically — this widget
/// does not add a new location-permission flow, it triggers the same kind
/// of one-shot read from `initState` instead of a button tap.
///
/// The merchant category is also passed to the existing card-ranking engine.
/// When the catalogue has enough evidence, this line shows the card and rate
/// immediately; if the merchant is uncategorized or ranking is still loading,
/// it only shows the location and never invents a recommendation.
///
/// IMPORTANT — permission-nag fix (post-review): Home's route is a plain
/// `ShellRoute`/`GoRoute` (see `app/lib/app/router.dart`), not a
/// `StatefulShellRoute.indexedStack`, so `HomeScreen` — and this widget —
/// is disposed and rebuilt on every navigation back to the Home tab.
/// That means `initState` fires again on every Home → other tab → Home
/// round trip. If the automatic mount ever called
/// `Geolocator.requestPermission()` while permission is Android's
/// "denied" (not yet "don't ask again"), the OS permission dialog would
/// resurface on ordinary tab navigation — a real system nag, not just an
/// in-app one, and a direct violation of ui-spec B1 States' "no location
/// permission -> chips primary, no nag". So `_locate` takes an `auto`
/// flag: an automatic mount only ever calls `Geolocator.checkPermission()`
/// (read-only, never shows a dialog) and falls back to the noPermission
/// state without prompting if it isn't already granted. Only an explicit
/// user tap (`auto: false`) is allowed to call `requestPermission()` —
/// matching `nearby_merchants_screen.dart`'s own pattern exactly, where
/// the whole location flow (including the request) only ever runs from
/// a button's `onPressed`.
class HomeContextLine extends ConsumerStatefulWidget {
  const HomeContextLine({super.key});

  @override
  ConsumerState<HomeContextLine> createState() => _HomeContextLineState();
}

class _HomeContextLineState extends ConsumerState<HomeContextLine> {
  _ContextState _state = _ContextState.locating;
  NearbyMerchantMatch? _closest;

  @override
  void initState() {
    super.initState();
    _locate(auto: true);
  }

  Future<void> _locate({required bool auto}) async {
    if (mounted) setState(() => _state = _ContextState.locating);
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _closest = null;
            _state = _ContextState.noPermission;
          });
        }
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        if (auto) {
          // Never prompt on an automatic mount — checkPermission() alone
          // never surfaces a system dialog, but requestPermission() does,
          // and an automatic mount must stay silent per ui-spec B1 States.
          if (mounted) {
            setState(() {
              _closest = null;
              _state = _ContextState.noPermission;
            });
          }
          return;
        }
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _closest = null;
            _state = _ContextState.noPermission;
          });
        }
        return;
      }

      final position = await _readCurrentLocationOnce();
      if (mounted) setState(() => _state = _ContextState.searching);
      final repo = ref.read(nearbyMerchantsRepositoryProvider);
      final candidates = await repo.fetchNearby(
        lat: position.latitude,
        lng: position.longitude,
        radiusM: nearbyMerchantSearchRadiusMeters,
      );
      final matches = findNearbyMerchants(
        origin: GeoPoint(lat: position.latitude, lng: position.longitude),
        candidates: candidates,
        radiusMeters: nearbyMerchantSearchRadiusMeters,
      );
      if (!mounted) return;
      if (matches.isEmpty) {
        setState(() {
          _closest = null;
          _state = _ContextState.noMatch;
        });
      } else {
        final nearestCategory = matches.first.candidate.categoryId;
        if (nearestCategory != null && HomeScreen.categoryLabelFor(nearestCategory) != null) {
          ref.read(selectedCategoryProvider.notifier).state = nearestCategory;
        }
        setState(() {
          _closest = matches.first;
          _state = _ContextState.found;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _closest = null;
          _state = _ContextState.offlineOrError;
        });
      }
    }
  }

  /// Android may already have a recent fused/network fix while a request for
  /// a new high-accuracy GPS fix waits indefinitely (common indoors and on a
  /// stationary test handset). Prefer a fresh cached fix, then make one
  /// bounded current-position request; never leave Home in `locating`.
  Future<Position> _readCurrentLocationOnce() async {
    final lastKnown = await Geolocator.getLastKnownPosition();
    if (lastKnown != null &&
        DateTime.now().difference(lastKnown.timestamp).abs() <=
            const Duration(minutes: 2) &&
        lastKnown.accuracy <= 150) {
      return lastKnown;
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    ).timeout(const Duration(seconds: 18));
  }

  @override
  Widget build(BuildContext context) {
    if (_state != _ContextState.found || _closest == null) {
      return const SizedBox.shrink();
    }

    final recommendation = _closest!.candidate.categoryId == null
        ? null
        : ref.watch(bestCardForMerchantProvider(_closest!.candidate.categoryId)).valueOrNull;

    return Padding(
      // B5 (Task 14): this widget's own leading padding is now owned by
      // home_screen.dart's wrapping Row/Padding, which places a search
      // IconButton alongside it — this must stay EdgeInsets.zero to avoid
      // doubled spacing at that call site.
      padding: EdgeInsets.zero,
      child: ConstrainedBox(
        // Tappable to correct/re-trigger location per ui-spec B1.1 — retries
        // the same one-shot read this widget already triggers from
        // initState, so a stale/wrong guess (or an earlier permission
        // denial the user has since fixed in Settings) isn't stuck until
        // the next full Home rebuild. Padded out to the 48x48dp minimum
        // touch target, matching the lesson from Task 5's review, even
        // though the visual row is a single compact line.
        constraints: const BoxConstraints(minHeight: 48),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => _locate(auto: false),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.place_rounded, size: 16, color: BambooInk.ink500),
                  const SizedBox(width: AppSpace.xs),
                  Flexible(
                    child: Text(
                      "You're near ${_closest!.candidate.displayName ?? 'a known merchant'}",
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                  ),
                ],
              ),
              if (recommendation != null) ...[
                const SizedBox(height: 2),
                Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: Text(
                    _recommendationText(recommendation),
                    style: BambooFonts.ui(12, weight: FontWeight.w600, color: BambooInk.jade),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _recommendationText(Recommendation recommendation) {
    final rate = recommendation.effectiveRatePerRupee;
    if (rate != null && rate > 0) {
      final percent = rate * 100;
      final formatted = percent == percent.roundToDouble()
          ? percent.toStringAsFixed(0)
          : percent.toStringAsFixed(1);
      return 'Use ${recommendation.card.name} · $formatted% reward';
    }
    return 'Use ${recommendation.card.name} · about ${recommendation.expectedValue.format(hidePaise: true)} back';
  }
}
