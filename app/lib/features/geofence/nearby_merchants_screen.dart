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
import 'geofence_monitor_service.dart';

/// UA-8.1/8.3: "Nearby merchants" — the original foreground-triggered,
/// one-shot check (button tap -> one location read -> `GET
/// /merchants/nearby/discover` -> rank via the same recommendation engine
/// machinery Home uses), plus a toggle for real background
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
  List<NearbyMerchantMatch> _matches = const [];
  bool _refreshing = false;
  bool _showingCached = false;
  bool _cacheRefreshFailed = false;

  @override
  void initState() {
    super.initState();
    // Opening the list should show current nearby results without requiring
    // an extra tap, but must not trigger an OS permission dialog by itself.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final permission = await Geolocator.checkPermission();
      if (!mounted) return;
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        _checkNearby(auto: true);
      }
    });
  }

  Future<void> _toggleBackgroundMonitoring(bool enable) async {
    await ref.read(backgroundAlertsControllerProvider).setEnabled(enable);
  }

  Future<void> _checkNearby({bool auto = false}) async {
    setState(() {
      _state = _LoadState.locating;
      _errorMessage = null;
      _refreshing = false;
      _showingCached = false;
      _cacheRefreshFailed = false;
    });

    try {
      final position = await _readCurrentLocationOnce(auto: auto);
      if (!mounted) return;

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

      final candidates = await repo.fetchNearby(
        lat: position.latitude,
        lng: position.longitude,
        radiusM: nearbyMerchantSearchRadiusMeters,
        // A user-initiated check is an explicit refresh. Automatic screen
        // entry remains cache-first and only revalidates once the client
        // freshness window has elapsed.
        forceRefresh: !auto,
      );

      var matches = findNearbyMerchants(
        origin: GeoPoint(lat: position.latitude, lng: position.longitude),
        candidates: candidates,
        radiusMeters: nearbyMerchantSearchRadiusMeters,
      );

      if (!mounted) return;
      setState(() {
        _matches = matches;
        _state = _LoadState.done;
        _refreshing = false;
        _showingCached = false;
        _cacheRefreshFailed = false;
      });
    } catch (err) {
      if (!mounted) return;
      if (_showingCached) {
        setState(() {
          _refreshing = false;
          _cacheRefreshFailed = true;
        });
      } else {
        setState(() {
          _errorMessage = userFacingErrorMessage(err);
          _state = _LoadState.error;
        });
      }
    }
  }

  /// A single, foreground, one-shot read — not a subscription/stream.
  Future<Position> _readCurrentLocationOnce({required bool auto}) async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw StateError('Location services are turned off on this device.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      if (auto) {
        throw StateError(
          'Location permission is needed to find nearby merchants. Tap Check nearby merchants to allow it.',
        );
      }
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError(
        'Location permission was denied — enable it in Settings to use this.',
      );
    }

    Position? lastKnown;
    try {
      lastKnown = await Geolocator.getLastKnownPosition();
    } catch (_) {
      // A last-known fix is only an optimization; continue to a live fix.
    }
    if (lastKnown != null &&
        DateTime.now().difference(lastKnown.timestamp).abs() <=
            const Duration(seconds: 45) &&
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
    final background = ref.watch(backgroundAlertsControllerProvider);
    final notificationPrefs = ref.watch(notificationPreferencesProvider);
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
                'Checks your current location for nearby businesses and '
                'suggests which of your cards to use. Map places may not be '
                'verified PandaPay merchants.',
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
                      background.description,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                    activeTrackColor: BambooInk.jade,
                    activeThumbColor: BambooInk.lime,
                    value: background.enabled,
                    onChanged: background.busy
                        ? null
                        : _toggleBackgroundMonitoring,
                  ),
                ),
              ),
              if (background.enabled)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Works while PandaPay runs in the background, with a persistent notification. '
                    'Force-stopping the app or restarting the phone stops monitoring until you reopen PandaPay. '
                    'Your choice stays saved.',
                    style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                  ),
                ),
              if (background.enabled &&
                  !background.busy &&
                  (background.status != GeofenceMonitorStatus.monitoring ||
                      background.error != null))
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: background.restore,
                      child: const Text('Retry monitoring'),
                    ),
                    if (background.status ==
                            GeofenceMonitorStatus.locationOff ||
                        background.status ==
                            GeofenceMonitorStatus.permissionRequired ||
                        background.status ==
                            GeofenceMonitorStatus.notificationsOff)
                      TextButton(
                        onPressed: () async {
                          if (background.status ==
                              GeofenceMonitorStatus.locationOff) {
                            await Geolocator.openLocationSettings();
                          } else {
                            await Geolocator.openAppSettings();
                          }
                        },
                        child: const Text('Open Settings'),
                      ),
                  ],
                ),
              if (background.enabled &&
                  notificationPrefs.valueOrNull?.categoryLocation == false)
                Text(
                  'Merchant notifications are muted. Enable location alerts in You → Notifications. '
                  'Quiet hours and daily notification limits also apply.',
                  style: BambooFonts.ui(11.5, color: BambooInk.clay),
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
                    : () => _checkNearby(),
                icon: const Icon(Icons.my_location),
                label: Text(switch (_state) {
                  _LoadState.locating => 'Getting your location…',
                  _LoadState.fetching => 'Finding nearby merchants…',
                  _ when _refreshing => 'Refreshing nearby merchants…',
                  _ => 'Check nearby merchants',
                }),
              ),
              if (_refreshing || _showingCached)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _refreshing
                        ? 'Showing saved places while checking for updates…'
                        : _cacheRefreshFailed
                        ? 'Could not refresh. Showing saved nearby places.'
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
    if (_state == _LoadState.error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _errorMessage ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: BambooFonts.ui(13.5, color: BambooInk.clay),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => _checkNearby(),
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
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
          'No nearby places found within 2 km. Try again.',
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

String _placeDisplayName(NearbyMerchantCandidate candidate) {
  final name = candidate.displayName?.trim();
  if (name == null || name.isEmpty) return 'Business name unavailable';
  final isMapCandidate = candidate.source?.contains('candidate') ?? false;
  final generic = RegExp(
    r'^(petrol\s*pump|petrol\s*(station|bunk)|fuel(\s*station)?|gas\s*station|shop|store|supermarket|restaurant|cafe|pharmacy)$',
    caseSensitive: false,
  );
  return isMapCandidate && generic.hasMatch(name)
      ? '$name · business name unavailable'
      : name;
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
            _placeDisplayName(match.candidate),
            style: BambooFonts.heading(15, color: BambooInk.ink900),
          ),
          Text(
            '${match.distanceMeters.toStringAsFixed(0)}m away',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          if (match.candidate.address?.trim().isNotEmpty ?? false)
            Text(
              match.candidate.address!,
              style: BambooFonts.ui(12, color: BambooInk.ink500),
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
