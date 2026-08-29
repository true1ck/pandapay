import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

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
  ConsumerState<NearbyMerchantsScreen> createState() => _NearbyMerchantsScreenState();
}

enum _LoadState { idle, locating, fetching, done, error }

class _NearbyMerchantsScreenState extends ConsumerState<NearbyMerchantsScreen> {
  _LoadState _state = _LoadState.idle;
  String? _errorMessage;
  List<NearbyMerchantMatch> _matches = const [];
  bool _backgroundToggleBusy = false;
  String? _backgroundError;

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
    });

    try {
      final position = await _readCurrentLocationOnce();
      setState(() => _state = _LoadState.fetching);

      final repo = ref.read(nearbyMerchantsRepositoryProvider);
      final candidates = await repo.fetchNearby(
        lat: position.latitude,
        lng: position.longitude,
        radiusM: 2000,
      );
      final matches = findNearbyMerchants(
        origin: GeoPoint(lat: position.latitude, lng: position.longitude),
        candidates: candidates,
        radiusMeters: 2000,
      );

      setState(() {
        _matches = matches;
        _state = _LoadState.done;
      });
    } catch (err) {
      setState(() {
        _errorMessage = userFacingErrorMessage(err);
        _state = _LoadState.error;
      });
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
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw StateError('Location permission was denied — enable it in Settings to use this.');
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
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
        title: Text('Nearby merchants', style: BambooFonts.heading(17, color: BambooInk.ink900)),
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
                    style: BambooFonts.ui(14.5, weight: FontWeight.w600, color: BambooInk.ink900),
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
                  onChanged: _backgroundToggleBusy ? null : _toggleBackgroundMonitoring,
                  ),
                ),
              ),
              if (_backgroundError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Text(_backgroundError!, style: BambooFonts.ui(12, color: BambooInk.clay)),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
                ),
                onPressed: _state == _LoadState.locating || _state == _LoadState.fetching
                    ? null
                    : _checkNearby,
                icon: const Icon(Icons.my_location),
                label: Text(switch (_state) {
                  _LoadState.locating => 'Getting your location…',
                  _LoadState.fetching => 'Checking nearby merchants…',
                  _ => 'Check nearby merchants',
                }),
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
        child: Text(
          _errorMessage ?? 'Something went wrong.',
          style: BambooFonts.ui(13.5, color: BambooInk.clay),
        ),
      );
    }
    if (_state == _LoadState.idle) {
      return Center(
        child: Text('Tap the button above to check.', style: BambooFonts.ui(13.5, color: BambooInk.ink500)),
      );
    }
    if (_state == _LoadState.locating || _state == _LoadState.fetching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_matches.isEmpty) {
      return Center(
        child: Text('No known merchants within 2km.', style: BambooFonts.ui(13.5, color: BambooInk.ink500)),
      );
    }
    return ListView.builder(
      itemCount: _matches.length,
      itemBuilder: (context, index) => _NearbyMerchantTile(_matches[index]),
    );
  }
}

class _NearbyMerchantTile extends ConsumerWidget {
  final NearbyMerchantMatch match;
  const _NearbyMerchantTile(this.match);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final best = ref.watch(bestCardForMerchantProvider(match.candidate.categoryId));

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
          const SizedBox(height: 6),
          best.when(
            loading: () => const LinearProgressIndicator(),
            error: (err, _) =>
                Text('Could not rank cards: $err', style: BambooFonts.ui(12.5, color: BambooInk.clay)),
            data: (rec) {
              if (rec == null) {
                return Text(
                  'No usable card for this spot.',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                );
              }
              return Row(
                children: [
                  const Icon(Icons.credit_card, size: 18, color: BambooInk.ink900),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Use ${rec.card.name}', style: BambooFonts.ui(13.5, color: BambooInk.ink900)),
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
}
