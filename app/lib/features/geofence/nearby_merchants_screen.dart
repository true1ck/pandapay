import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;
import 'nearby_merchants_repository.dart';

/// UA-8.1/8.3: "Nearby merchants" — the original foreground-triggered,
/// one-shot check (button tap -> one location read -> `GET
/// /merchants/nearby` -> rank via the same `rankedRecommendationsProvider`/
/// engine machinery Home uses), plus a toggle for real background
/// monitoring (GeofenceMonitorService) added in a later pass — see that
/// service's doc-comment for exactly what "background" does and doesn't
/// mean here (app-process-alive background, not survives-a-reboot
/// tracking).
class NearbyMerchantsScreen extends ConsumerStatefulWidget {
  const NearbyMerchantsScreen({super.key});

  @override
  ConsumerState<NearbyMerchantsScreen> createState() =>
      _NearbyMerchantsScreenState();
}

enum _LoadState { idle, locating, fetching, done, error }

class _NearbyMerchantsScreenState extends ConsumerState<NearbyMerchantsScreen> {
  _LoadState _state = _LoadState.idle;
  String? _errorMessage;
  String? _discoveryNotice;
  List<NearbyMerchantMatch> _matches = const [];
  bool _refreshing = false;
  bool _showingCached = false;
  bool _backgroundToggleBusy = false;
  String? _backgroundError;
  final _placeController = TextEditingController();
  List<NearbyMerchantCandidate>? _placeResults;
  bool _placeSearching = false;
  String? _placeSearchError;
  Position? _lastPosition;

  @override
  void dispose() {
    _placeController.dispose();
    super.dispose();
  }

  Future<void> _toggleBackgroundMonitoring(bool enable) async {
    setState(() {
      _backgroundToggleBusy = true;
      _backgroundError = null;
    });
    try {
      final service = ref.read(geofenceMonitorServiceProvider);
      if (enable) {
        final granted = await service.requestPermissions();
        if (!granted) {
          if (mounted) {
            setState(
              () => _backgroundError =
                  'Background location and notification permissions are needed for this — '
                  'set location access to "Allow all the time" and enable notifications in Settings.',
            );
          }
          return;
        }
        await service.start();
      } else {
        await service.stop();
      }
      ref.read(geofenceMonitoringEnabledProvider.notifier).state = enable;
    } catch (e) {
      // Anything the permission/stream/plugin path throws is contained here —
      // the toggle stays in its previous state and the user sees why, rather
      // than the app going down.
      if (mounted) setState(() => _backgroundError = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _backgroundToggleBusy = false);
    }
  }

  Future<void> _checkNearby() async {
    setState(() {
      _state = _LoadState.locating;
      _errorMessage = null;
      _discoveryNotice = null;
      _refreshing = false;
      _showingCached = false;
      _placeResults = null;
    });

    try {
      final position = await _readCurrentLocationOnce();
      if (!mounted) return;
      _lastPosition = position;

      final repo = ref.read(nearbyMerchantsRepositoryProvider);
      final NearbyMerchantCacheRepository? cacheRepo =
          repo is NearbyMerchantCacheRepository
          ? repo as NearbyMerchantCacheRepository
          : null;
      final cached = await cacheRepo?.readCachedNearby(
        lat: position.latitude,
        lng: position.longitude,
        radiusM: nearbyMerchantSearchRadiusMeters,
      );

      if (cached != null) {
        final cachedMatches = findNearbyMerchants(
          origin: GeoPoint(lat: position.latitude, lng: position.longitude),
          candidates: cached.candidates,
          radiusMeters: nearbyMerchantSearchRadiusMeters,
        );
        setState(() {
          _matches = cachedMatches;
          _state = _LoadState.done;
          _refreshing = true;
          _showingCached = true;
        });
      } else {
        setState(() => _state = _LoadState.fetching);
      }

      List<NearbyMerchantCandidate> candidates = const [];
      Object? publishedError;
      try {
        candidates = await repo.fetchNearby(
          lat: position.latitude,
          lng: position.longitude,
          radiusM: nearbyMerchantSearchRadiusMeters,
        );
      } catch (err) {
        publishedError = err;
      }

      var matches = findNearbyMerchants(
        origin: GeoPoint(lat: position.latitude, lng: position.longitude),
        candidates: candidates,
        radiusMeters: nearbyMerchantSearchRadiusMeters,
      );

      // Keep the published PandaPay lookup authoritative when it has a match,
      // but still try the read-only map provider when the directory is empty
      // OR temporarily unavailable. A backend hiccup must not suppress the
      // only useful result the user can receive at that moment.
      if (matches.isEmpty && repo is NearbyMerchantDiscoveryRepository) {
        try {
          final discovered = await repo.discoverNearby(
            lat: position.latitude,
            lng: position.longitude,
            radiusM: nearbyMerchantSearchRadiusMeters,
          );
          matches = findNearbyMerchants(
            origin: GeoPoint(
              lat: position.latitude,
              lng: position.longitude,
            ),
            candidates: discovered,
            radiusMeters: nearbyMerchantSearchRadiusMeters,
          );
        } catch (_) {
          _discoveryNotice =
              'Map discovery is temporarily unavailable. You can retry or search for a place below.';
        }
      }

      if (publishedError != null && matches.isEmpty && cached == null) {
        // No source produced a result, so preserve the original actionable
        // network error rather than pretending the area has no merchants.
        throw publishedError;
      }

      if (!mounted) return;
      setState(() {
        _matches = matches;
        _state = _LoadState.done;
        _refreshing = false;
        _showingCached = cached != null && matches.isEmpty;
      });
      if (cached != null && matches.isEmpty) {
        // The live request failed, but the cache is still useful. Keep it
        // visible rather than replacing it with an error screen.
        final cachedMatches = findNearbyMerchants(
          origin: GeoPoint(lat: position.latitude, lng: position.longitude),
          candidates: cached.candidates,
          radiusMeters: nearbyMerchantSearchRadiusMeters,
        );
        setState(() => _matches = cachedMatches);
      }
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _errorMessage = userFacingErrorMessage(err);
        _state = _LoadState.error;
      });
    }
  }

  Future<void> _searchPlace() async {
    final query = _placeController.text.trim();
    if (query.length < 2) {
      setState(() => _placeSearchError = 'Enter at least 2 characters.');
      return;
    }
    setState(() {
      _placeSearching = true;
      _placeSearchError = null;
      _placeResults = null;
    });
    try {
      final position = _lastPosition;
      final results = await ref
          .read(nearbyPlaceSearchRepositoryProvider)
          .searchPlaces(
            query: query,
            lat: position?.latitude,
            lng: position?.longitude,
          );
      if (mounted) setState(() => _placeResults = results);
    } catch (err) {
      if (mounted) setState(() => _placeSearchError = userFacingErrorMessage(err));
    } finally {
      if (mounted) setState(() => _placeSearching = false);
    }
  }

  /// A single, foreground, one-shot read — not a subscription/stream, and
  /// no background mode requested. Permission handling is the minimum
  /// needed to make one honest request-and-check, not a full retry/settings-
  /// deeplink flow — flagged in PROGRESS.md as unverified on a real device.
  Future<Position> _readCurrentLocationOnce() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw StateError('Location services are turned off on this device.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError(
        'Location permission was denied — enable it in Settings to use this.',
      );
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final backgroundEnabled = ref.watch(geofenceMonitoringEnabledProvider);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Nearby merchants',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Checks your current location and looks for merchants you or '
                'other PandaPay users have transacted at nearby, then suggests '
                'which of your cards to use.',
                style: BambooFonts.ui(13, color: BambooInk.ink500),
              ),
              const SizedBox(height: 12),
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: BambooInk.glassFillOnPaper,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: BambooInk.hairlineOnPaper),
                ),
                // SwitchListTile paints its background/ink on the nearest
                // Material ancestor; without this wrapper it asserts because
                // the DecoratedBox above would hide those effects.
                child: Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    title: Text(
                      'Background alerts',
                      style: BambooFonts.ui(
                        14.5,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
                    subtitle: Text(
                      backgroundEnabled
                          ? 'On — you\'ll get a notification when you\'re near a known merchant, '
                                'even with the app closed. A persistent notification shows while this is active.'
                          : 'Off — checks only run when you tap the button below.',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                    activeTrackColor: BambooInk.jade,
                    activeThumbColor: BambooInk.lime,
                    value: backgroundEnabled,
                    onChanged: _backgroundToggleBusy
                        ? null
                        : _toggleBackgroundMonitoring,
                  ),
                ),
              ),
              if (_backgroundError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Text(
                    _backgroundError!,
                    style: BambooFonts.ui(12, color: BambooInk.clay),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
                ),
                onPressed:
                    _state == _LoadState.locating ||
                        _state == _LoadState.fetching ||
                        _refreshing
                    ? null
                    : _checkNearby,
                icon: const Icon(Icons.my_location),
                label: Text(switch (_state) {
                  _LoadState.locating => 'Getting your location…',
                  _LoadState.fetching => 'Finding nearby merchants…',
                  _ when _refreshing => 'Refreshing nearby merchants…',
                  _ => 'Check nearby merchants',
                }),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                decoration: BoxDecoration(
                  color: BambooInk.glassFillOnPaper,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: BambooInk.hairlineOnPaper),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _placeController,
                        textInputAction: TextInputAction.search,
                        style: BambooFonts.ui(14, color: BambooInk.ink900),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: 'Test a place or petrol pump',
                          hintStyle: BambooFonts.ui(14, color: BambooInk.ink500),
                        ),
                        onSubmitted: (_) => _searchPlace(),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Search place',
                      onPressed: _placeSearching ? null : _searchPlace,
                      icon: _placeSearching
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search_rounded),
                    ),
                  ],
                ),
              ),
              if (_placeSearchError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _placeSearchError!,
                    style: BambooFonts.ui(12, color: BambooInk.clay),
                  ),
                ),
              if (_placeResults != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Manual results are map candidates for testing, not verified PandaPay merchants.',
                    style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                  ),
                ),
              if (_refreshing || _showingCached)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _refreshing
                        ? 'Showing saved places while checking for updates…'
                        : 'Showing saved nearby places.',
                    textAlign: TextAlign.center,
                    style: BambooFonts.ui(12, color: BambooInk.ink500),
                  ),
                ),
              const SizedBox(height: 16),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final placeResults = _placeResults;
    if (placeResults != null) {
      if (placeResults.isEmpty) {
        return Center(
          child: Text(
            'No map place found for this search.',
            textAlign: TextAlign.center,
            style: BambooFonts.ui(13.5, color: BambooInk.ink500),
          ),
        );
      }
      return ListView.builder(
        itemCount: placeResults.length,
        itemBuilder: (context, index) => _ManualPlaceTile(placeResults[index]),
      );
    }
    if (_state == _LoadState.error) {
      return Center(
        child: Text(
          _errorMessage ?? 'Something went wrong.',
          style: BambooFonts.ui(13.5, color: BambooInk.clay),
        ),
      );
    }
    if (_state == _LoadState.idle) {
      return Center(
        child: Text(
          'Tap the button above to check.',
          style: BambooFonts.ui(13.5, color: BambooInk.ink500),
        ),
      );
    }
    if (_state == _LoadState.locating || _state == _LoadState.fetching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_matches.isEmpty) {
      return Center(
        child: Text(
          _discoveryNotice ??
              'No nearby merchants found yet. Try again closer to the store.',
          textAlign: TextAlign.center,
          style: BambooFonts.ui(13.5, color: BambooInk.ink500),
        ),
      );
    }
    return ListView.builder(
      itemCount: _matches.length,
      itemBuilder: (context, index) => _NearbyMerchantTile(_matches[index]),
    );
  }
}

class _ManualPlaceTile extends ConsumerWidget {
  final NearbyMerchantCandidate candidate;

  const _ManualPlaceTile(this.candidate);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final best = ref.watch(bestCardForMerchantProvider(candidate.categoryId));
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            candidate.displayName ?? 'Unnamed place',
            style: BambooFonts.heading(15, color: BambooInk.ink900),
          ),
          const SizedBox(height: 3),
          Text(
            'Map candidate · ${candidate.categoryId ?? 'other'}',
            style: BambooFonts.ui(12, color: BambooInk.ink500),
          ),
          const SizedBox(height: 7),
          best.when(
            loading: () => const LinearProgressIndicator(),
            error: (err, _) => Text(
              'Could not rank cards: $err',
              style: BambooFonts.ui(12.5, color: BambooInk.clay),
            ),
            data: (rec) => Text(
              rec == null
                  ? 'No usable card for this place yet.'
                  : 'Suggested card: ${rec.card.name}',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
        ],
      ),
    );
  }
}

class _NearbyMerchantTile extends ConsumerWidget {
  final NearbyMerchantMatch match;
  const _NearbyMerchantTile(this.match);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final best = ref.watch(
      bestCardForMerchantProvider(match.candidate.categoryId),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            match.candidate.displayName ?? 'Unnamed merchant',
            style: BambooFonts.heading(15, color: BambooInk.ink900),
          ),
          Text(
            '${match.distanceMeters.toStringAsFixed(0)}m away',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          if (match.candidate.source == 'osm_candidate')
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'Nearby place · not yet verified by PandaPay · © OpenStreetMap contributors',
                style: BambooFonts.ui(11.5, color: BambooInk.clay),
              ),
            ),
          const SizedBox(height: 6),
          best.when(
            loading: () => const LinearProgressIndicator(),
            error: (err, _) => Text(
              'Could not rank cards: $err',
              style: BambooFonts.ui(12.5, color: BambooInk.clay),
            ),
            data: (rec) {
              if (rec == null) {
                return Text(
                  'No usable card for this spot.',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                );
              }
              return Row(
                children: [
                  const Icon(
                    Icons.credit_card,
                    size: 18,
                    color: BambooInk.ink900,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Use ${rec.card.name}',
                          style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                        ),
                        if (rec.effectiveRatePerRupee != null &&
                            rec.effectiveRatePerRupee! > 0)
                          Text(
                            '${_rateLabel(rec.effectiveRatePerRupee!)} reward rate',
                            style: BambooFonts.ui(11.5, color: BambooInk.jade),
                          ),
                      ],
                    ),
                  ),
                  MoneyText(
                    rec.expectedValue,
                    confidence: rec.confidence,
                    style: BambooFonts.money(14, color: BambooInk.ink900),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  String _rateLabel(double rate) {
    final percent = rate * 100;
    return percent == percent.roundToDouble()
        ? '${percent.toStringAsFixed(0)}%'
        : '${percent.toStringAsFixed(1)}%';
  }
}
