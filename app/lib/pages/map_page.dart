import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../notifiers/notifier.dart';
import '../services/ble_protocol.dart';
import '../services/directions_service.dart';
import '../services/offline_map_data.dart';
import '../services/recent_places_service.dart';
import '../widgets/ble_status_badge.dart';
import '../widgets/offline_map_view.dart';
import 'navigating_page.dart';
import 'search_page.dart';

// Matches the route line's orange (see offline_map_view.dart's _routeOrange).
const Color _pinColor = Color(0xFFFF9811);
const double _pinIconSize = 40.0;

String _formatDistance(double meters) =>
    meters >= 1000 ? '${(meters / 1000).toStringAsFixed(1)} km' : '${meters.round()} m';

String _formatDuration(double seconds) {
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final remaining = minutes % 60;
  return remaining == 0 ? '$hours hr' : '$hours hr $remaining min';
}

// Notifier.fetchRouteOptions fetches one driving-mode and one bicycling-mode
// route — a real difference in Google's own routing engine (bicycling mode
// actually prefers cycle lanes/paths), not a relabeled alternative. The
// driving-mode one isn't necessarily fastest or shortest for a cyclist (it's
// just the most direct route a car would take, not detouring for cycle
// infrastructure), so "Direct route" is the honest label rather than
// claiming a speed/distance property that isn't guaranteed.
String _routeLabel(bool cycling) => cycling ? 'Cycle-friendly' : 'Direct route';

// The driving-mode ("Direct route") route's own duration is Google's
// car-speed estimate, which is misleading on a bike computer — Google has no
// "give me this distance at cycling speed" option, so instead we derive a
// duration from distance and a typical average urban cycling speed. Not turn-by-turn
// accurate, but far more honest than showing how fast a car would do it.
// The bicycling-mode ("Cycle-friendly") route already has a real cycling
// estimate from Google and is left untouched.
const double _avgCyclingSpeedMps = 15000 / 3600; // ~15 km/h
double _displayDurationSeconds(DirectionsRoute route, bool cycling) =>
    cycling ? route.totalDurationSeconds : route.totalDistanceMeters / _avgCyclingSpeedMps;

/// The app's home screen: a full-screen, freely pannable map (the same
/// offline map data/style the wearable renders) with a Google-Maps-style
/// search-pin-directions flow layered on top. Replaces the old
/// text-form home page + separate route-preview page.
class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  late final Future<OfflineMapData> _mapDataFuture;
  final _controller = MapViewController(centerX: 0, centerY: 0, metersPerPixel: 2.0);
  bool _hasCenteredOnUser = false;

  @override
  void initState() {
    super.initState();
    _mapDataFuture = OfflineMapData.load();
  }

  Future<void> _openSearch() async {
    final place = await Navigator.push<SelectedPlace>(context, MaterialPageRoute(builder: (_) => const SearchPage()));
    if (place == null || !mounted) return;
    final notifier = context.read<Notifier>();
    final ok = await notifier.fetchPreviewRoute(place.description);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not find a route to that destination.')),
      );
      return;
    }
    _fitToRoute(notifier);
  }

  Future<void> _showDirections(Notifier notifier) async {
    await notifier.fetchRouteOptions();
    if (!mounted) return;
    _fitToRoute(notifier);
  }

  Future<void> _start(Notifier notifier) async {
    await notifier.startNavigation();
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => const NavigatingPage()));
  }

  void _fitToRoute(Notifier notifier) {
    final user = notifier.userLocation;
    final dest = notifier.selectedDestinationLatLng;
    if (user == null || dest == null) return;

    final a = projectLatLon(user.latitude, user.longitude);
    final b = projectLatLon(dest.latitude, dest.longitude);
    final size = MediaQuery.sizeOf(context);
    final spanXM = (b.x - a.x).abs();
    final spanYM = (b.y - a.y).abs();
    // Leave headroom around the two points (0.6 of the viewport actually
    // used) and around the bottom card, rather than filling edge-to-edge.
    final mpp = max(spanXM / (size.width * 0.6), spanYM / (size.height * 0.4)).clamp(5.0, 2000.0);
    _controller.setView(centerX: (a.x + b.x) / 2, centerY: (a.y + b.y) / 2, metersPerPixel: mpp);
  }

  void _maybeCenterOnUser(Notifier notifier) {
    if (_hasCenteredOnUser) return;
    final user = notifier.userLocation;
    if (user == null) return;
    _hasCenteredOnUser = true;
    final local = projectLatLon(user.latitude, user.longitude);
    _controller.setView(centerX: local.x, centerY: local.y);
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<Notifier>();
    _maybeCenterOnUser(notifier);

    final markers = <MapMarker>[];
    final user = notifier.userLocation;
    if (user != null) {
      final local = projectLatLon(user.latitude, user.longitude);
      markers.add(MapMarker(x: local.x, y: local.y));
    }

    final routeOptions = notifier.routeOptions;
    final routes = <MapRoute>[
      for (var i = 0; i < routeOptions.length; i++)
        MapRoute(
          points: routeOptions[i].polylinePoints.map((p) => projectLatLon(p.latitude, p.longitude)).toList(),
          selected: i == notifier.selectedRouteOptionIndex,
        ),
    ];

    return Scaffold(
      body: FutureBuilder<OfflineMapData>(
        future: _mapDataFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load map: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return Stack(
            children: [
              OfflineMapView(data: snapshot.data!, controller: _controller, markers: markers, routes: routes),
              if (notifier.selectedDestinationLatLng != null) _buildDestinationPin(notifier),
              _buildTopBar(notifier),
              if (routeOptions.isNotEmpty) _buildRouteBadges(routeOptions, notifier),
              if (notifier.destinationName.isNotEmpty) _buildBottomCard(notifier),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDestinationPin(Notifier notifier) {
    final dest = notifier.selectedDestinationLatLng;
    if (dest == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final size = MediaQuery.sizeOf(context);
        final local = projectLatLon(dest.latitude, dest.longitude);
        final screenX = size.width / 2 + (local.x - _controller.centerX) / _controller.metersPerPixel;
        final screenY = size.height / 2 - (local.y - _controller.centerY) / _controller.metersPerPixel;
        // location_on's glyph point sits at the bottom-center of its bounding
        // box, so that's what should land on the actual coordinate.
        return Positioned(
          left: screenX - _pinIconSize / 2,
          top: screenY - _pinIconSize,
          child: const Icon(
            Icons.location_on,
            color: _pinColor,
            size: _pinIconSize,
            shadows: [Shadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 2))],
          ),
        );
      },
    );
  }

  Widget _buildTopBar(Notifier notifier) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Material(
                  elevation: 3,
                  borderRadius: BorderRadius.circular(28),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(28),
                    onTap: _openSearch,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      child: Row(
                        children: [
                          const Icon(Icons.search),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              notifier.destinationName.isEmpty ? 'Search for a destination' : notifier.destinationName,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: notifier.destinationName.isEmpty ? Colors.grey.shade600 : null),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              BleStatusBadge(status: notifier.bleStatus, onRetry: notifier.retryBleConnection),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRouteBadges(List<DirectionsRoute> routeOptions, Notifier notifier) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final size = MediaQuery.sizeOf(context);
        final positions = _computeBadgePositions(routeOptions, size);
        return Stack(
          children: [
            for (var i = 0; i < routeOptions.length; i++)
              if (positions[i] != null) _buildRouteBadge(routeOptions, i, notifier, positions[i]!),
          ],
        );
      },
    );
  }

  // Driving and cycling directions often share most of their path (they
  // only diverge for a short stretch), so their polyline midpoints — and
  // therefore their badges — frequently land right on top of each other.
  // When that happens, spread them vertically around their shared midpoint
  // instead of letting them overlap.
  static const double _badgeOverlapThresholdPx = 90.0;
  static const double _badgeSeparationPx = 34.0;

  List<Offset?> _computeBadgePositions(List<DirectionsRoute> routeOptions, Size size) {
    final positions = <Offset?>[
      for (final route in routeOptions)
        if (route.polylinePoints.isEmpty)
          null
        else
          _worldToScreen(
            projectLatLon(
              route.polylinePoints[route.polylinePoints.length ~/ 2].latitude,
              route.polylinePoints[route.polylinePoints.length ~/ 2].longitude,
            ),
            size,
          ),
    ];

    if (positions.length == 2 && positions[0] != null && positions[1] != null) {
      final a = positions[0]!;
      final b = positions[1]!;
      if ((a - b).distance < _badgeOverlapThresholdPx) {
        final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
        positions[0] = Offset(mid.dx, mid.dy - _badgeSeparationPx);
        positions[1] = Offset(mid.dx, mid.dy + _badgeSeparationPx);
      }
    }

    return positions;
  }

  Offset _worldToScreen(({double x, double y}) local, Size size) {
    return Offset(
      size.width / 2 + (local.x - _controller.centerX) / _controller.metersPerPixel,
      size.height / 2 - (local.y - _controller.centerY) / _controller.metersPerPixel,
    );
  }

  Widget _buildRouteBadge(List<DirectionsRoute> routeOptions, int index, Notifier notifier, Offset center) {
    final route = routeOptions[index];
    final cycling = notifier.routeOptionIsCycling[index];
    final selected = index == notifier.selectedRouteOptionIndex;
    final textColor = selected ? Colors.white : Colors.black87;

    return Positioned(
      left: center.dx - 48,
      top: center.dy - 22,
      child: Material(
        elevation: 3,
        color: selected ? const Color(0xFFFF9811) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => notifier.selectRouteOption(index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _routeLabel(cycling),
                  style: TextStyle(fontSize: 10, color: textColor.withValues(alpha: 0.85)),
                ),
                Text(
                  _formatDuration(_displayDurationSeconds(route, cycling)),
                  style: TextStyle(fontWeight: FontWeight.bold, color: textColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomCard(Notifier notifier) {
    final route = notifier.selectedRouteOption ?? notifier.previewRoute;
    final showingOptions = notifier.routeOptions.isNotEmpty;
    // Before "Directions" is tapped there's no routeOptionIsCycling entry to
    // check — previewRoute was fetched using whatever cycleRoute mode was
    // active at the time, which is exactly what that getter still reflects.
    final cycling = showingOptions ? notifier.routeOptionIsCycling[notifier.selectedRouteOptionIndex] : notifier.cycleRoute;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        elevation: 6,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        notifier.destinationName,
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.close), onPressed: notifier.clearSelectedDestination),
                  ],
                ),
                const SizedBox(height: 8),
                if (notifier.isFetchingRoute)
                  const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 8), child: CircularProgressIndicator()))
                else if (route == null)
                  const Text('No route found.')
                else ...[
                  Text(
                    '${showingOptions ? '${_routeLabel(cycling)} · ' : ''}'
                    '${_formatDistance(route.totalDistanceMeters)} · ${_formatDuration(_displayDurationSeconds(route, cycling))} · '
                    '${route.steps.length} steps',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: showingOptions ? () => _start(notifier) : () => _showDirections(notifier),
                    style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    child: Text(showingOptions ? 'Start' : 'Directions'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

