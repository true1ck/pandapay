import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/providers.dart';
import '../../main.dart' show MoneyText;

/// UA-8.1/8.3: "Nearby merchants" — the foreground-triggered, one-shot
/// version of geofencing this chunk actually built. Explicitly NOT
/// always-on background geofence monitoring (see PROGRESS.md for the
/// stated scope reduction) — this screen only reads the device's current
/// location when the user taps the button, sends it to
/// `GET /merchants/nearby`, and for each match reuses the *exact same*
/// `rankedRecommendationsProvider`/engine machinery Home already uses
/// (scoped to the merchant's own category when it has one) to say which
/// owned card to use there.
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
        _errorMessage = err.toString();
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
    return Scaffold(
      appBar: AppBar(title: const Text('Nearby merchants')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Checks your current location once and looks for merchants '
              "you or other PandaPay users have transacted at nearby, then "
              'suggests which of your cards to use. This is a one-shot '
              "check, not always-on background tracking.",
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
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
    );
  }

  Widget _buildBody() {
    if (_state == _LoadState.error) {
      return Center(child: Text(_errorMessage ?? 'Something went wrong.'));
    }
    if (_state == _LoadState.idle) {
      return const Center(child: Text('Tap the button above to check.'));
    }
    if (_state == _LoadState.locating || _state == _LoadState.fetching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_matches.isEmpty) {
      return const Center(child: Text('No known merchants within 2km.'));
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

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              match.candidate.displayName ?? 'Unnamed merchant',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${match.distanceMeters.toStringAsFixed(0)}m away',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            best.when(
              loading: () => const LinearProgressIndicator(),
              error: (err, _) => Text('Could not rank cards: $err'),
              data: (rec) {
                if (rec == null) return const Text('No usable card for this spot.');
                return Row(
                  children: [
                    const Icon(Icons.credit_card, size: 18),
                    const SizedBox(width: 6),
                    Expanded(child: Text('Use ${rec.card.name}')),
                    MoneyText(rec.expectedValue, confidence: rec.confidence),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
