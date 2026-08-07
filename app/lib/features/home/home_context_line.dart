import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';

enum _ContextState { locating, found, noPermission, noMatch, offlineOrError }

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
        if (mounted) setState(() => _state = _ContextState.noPermission);
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        if (auto) {
          // Never prompt on an automatic mount — checkPermission() alone
          // never surfaces a system dialog, but requestPermission() does,
          // and an automatic mount must stay silent per ui-spec B1 States.
          if (mounted) setState(() => _state = _ContextState.noPermission);
          return;
        }
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        if (mounted) setState(() => _state = _ContextState.noPermission);
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      final repo = ref.read(nearbyMerchantsRepositoryProvider);
      final candidates = await repo.fetchNearby(lat: position.latitude, lng: position.longitude, radiusM: 500);
      final matches = findNearbyMerchants(
        origin: GeoPoint(lat: position.latitude, lng: position.longitude),
        candidates: candidates,
        radiusMeters: 500,
      );
      if (!mounted) return;
      if (matches.isEmpty) {
        setState(() => _state = _ContextState.noMatch);
      } else {
        setState(() {
          _closest = matches.first;
          _state = _ContextState.found;
        });
        // A found merchant is the same "geofence guess" ui-spec B1.5 says a
        // category-chip tap can override (see selectedCategoryProvider
        // below) — but that provider holds a category *slug* while this
        // repository only carries a category UUID, and resolving that
        // mismatch would mean duplicating a slug<->id lookup out of
        // providers.dart's categoriesProvider that this widget has no
        // other reason to own. So the context line surfaces the merchant
        // name for display only in this task; it does not push a re-rank.
        // Stated scope reduction, not a silent gap.
      }
    } catch (_) {
      if (mounted) setState(() => _state = _ContextState.offlineOrError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (_state) {
      _ContextState.locating => (Icons.my_location_rounded, 'Finding where you are…'),
      _ContextState.found => (
          Icons.place_rounded,
          "You're near ${_closest!.candidate.displayName ?? 'a known merchant'}",
        ),
      _ContextState.noMatch => (Icons.explore_off_rounded, 'Not sure where you are — scan or pick a category.'),
      // ui-spec B1 States: "No location permission -> chips primary, no
      // nag" — this line stays factual and unobtrusive, never a permission
      // prompt/nag of its own.
      _ContextState.noPermission => (Icons.explore_off_rounded, 'Pick a category below.'),
      _ContextState.offlineOrError => (Icons.wifi_off_rounded, 'Offline — pick a category below.'),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, 0),
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
          onTap: _state == _ContextState.locating ? null : () => _locate(auto: false),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: AppColors.ink500),
                const SizedBox(width: AppSpace.xs),
                Flexible(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
