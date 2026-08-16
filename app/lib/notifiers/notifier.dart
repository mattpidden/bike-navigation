import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/ble_protocol.dart';
import '../services/ble_service.dart';
import '../services/directions_service.dart';
import '../services/route_tracker.dart';

enum NavMode { home, navigating, arrived }

/// Single source of truth for BLE, GPS, and navigation state — every screen
/// reads and drives the app through this instead of each page keeping its
/// own copy (which is what the old app did, and why its BLE connection kept
/// dropping between screens).
///
/// Telemetry (position + heading) streams to the wearable continuously
/// whenever a location fix and a BLE connection both exist, independent of
/// whether a route is active — the wearable's map should track you the
/// moment it's connected, not only once you've picked a destination. Route
/// data layers on top of that only while [navMode] is [NavMode.navigating].
class Notifier with ChangeNotifier {
  Notifier() {
    _directionsService = DirectionsService(dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '');
    _bleService = BleService();
    _bleService.statusStream.listen(_onBleStatusChanged);
    _init();
  }

  late final DirectionsService _directionsService;
  late final BleService _bleService;
  RouteTracker? _routeTracker;

  LatLng? _userLocation;
  double _heading = 0.0;
  bool _cycleRoute = true; // a bike computer defaults to bicycling directions

  StreamSubscription<Position>? _positionSub;
  Timer? _telemetryTimer;

  // Below this speed, GPS course-over-ground is too noisy to trust, so we
  // hold the last known heading instead of updating it.
  static const double _minHeadingSpeedMps = 1.5;

  NavMode _navMode = NavMode.home;
  DirectionsRoute? _previewRoute; // fetched but not yet started
  DirectionsRoute? _activeRoute;
  String _destinationName = '';
  double? _distanceRemainingM;
  bool _isFetchingRoute = false;

  // GETTERS
  BleStatus get bleStatus => _bleService.status;
  bool get bleConnected => _bleService.isConnected;
  LatLng? get userLocation => _userLocation;
  bool get cycleRoute => _cycleRoute;
  NavMode get navMode => _navMode;
  DirectionsRoute? get previewRoute => _previewRoute;
  DirectionsRoute? get activeRoute => _activeRoute;
  String get destinationName => _destinationName;
  double? get distanceRemainingM => _distanceRemainingM;
  bool get isFetchingRoute => _isFetchingRoute;

  /// Nudges the background scan/connect loop to try immediately instead of
  /// waiting for its next scheduled attempt. Safe to call anytime — a no-op
  /// if already connected.
  void retryBleConnection() => _bleService.start();

  Future<void> _init() async {
    _bleService.start();
    final allowed = await _requestLocationPermission();
    if (!allowed) return;
    await _refreshUserLocation();
    _listenToLocation();
    _startTelemetryTimer();
  }

  // The ESP32's route buffer is RAM-only, so a fresh connection always starts
  // with no route loaded — this covers both "start navigation before the
  // wearable finished connecting" (sendRoute in startNavigation() silently
  // no-ops if not connected yet, nothing else retried it) and "BLE dropped and
  // reconnected mid-ride" (the device comes back with an empty route buffer
  // regardless of what it had before).
  void _onBleStatusChanged(BleStatus status) {
    if (status == BleStatus.connected && _navMode == NavMode.navigating && _activeRoute != null) {
      unawaited(_bleService.sendRoute(_projectRoute(_activeRoute!)));
    }
    notifyListeners();
  }

  Future<bool> _requestLocationPermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.whileInUse) {
      // On Android this escalates to "Allow all the time" (needed to keep
      // tracking with the screen off/locked). On iOS, geolocator only ever
      // grants When In Use once NSLocationWhenInUseUsageDescription is set,
      // so this call is a harmless no-op there — background updates on iOS
      // instead rely on allowBackgroundLocationUpdates below, which works
      // under When In Use as long as tracking is already active.
      permission = await Geolocator.requestPermission();
    }
    return permission != LocationPermission.denied && permission != LocationPermission.deniedForever;
  }

  Future<void> _refreshUserLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
      );
      _userLocation = LatLng(pos.latitude, pos.longitude);
      notifyListeners();
    } catch (e) {
      if (kDebugMode) print('getCurrentPosition failed: $e');
    }
  }

  void _listenToLocation() {
    _positionSub?.cancel();
    final LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Bike Navigation',
          notificationText: 'Tracking your location for navigation',
        ),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    } else {
      settings = const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 5);
    }
    _positionSub = Geolocator.getPositionStream(locationSettings: settings).listen(_onPosition);
  }

  void _startTelemetryTimer() {
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sendTelemetry());
  }

  void _onPosition(Position pos) {
    _userLocation = LatLng(pos.latitude, pos.longitude);
    if (pos.speed >= _minHeadingSpeedMps) {
      _heading = pos.heading;
    }

    if (_navMode == NavMode.navigating && _routeTracker != null) {
      final local = projectLatLon(pos.latitude, pos.longitude);
      final progress = _routeTracker!.update(local.x, local.y);
      _distanceRemainingM = progress.remainingDistanceM;

      if (progress.arrived) {
        _navMode = NavMode.arrived;
      } else if (progress.offRoute && !_isFetchingRoute) {
        unawaited(_recalculateRoute());
      }
    }
    notifyListeners();
  }

  void _sendTelemetry() {
    final loc = _userLocation;
    if (loc == null) return;
    final local = projectLatLon(loc.latitude, loc.longitude);
    final mode = switch (_navMode) {
      NavMode.home => modeHome,
      NavMode.navigating => modeNav,
      NavMode.arrived => modeArrived,
    };
    unawaited(_bleService.sendTelemetry(xMeters: local.x, yMeters: local.y, headingDeg: _heading, mode: mode));
  }

  Future<List<dynamic>> searchPlaces(String input) {
    return _directionsService.placeAutocomplete(input, lat: _userLocation?.latitude, lng: _userLocation?.longitude);
  }

  Future<Map<String, dynamic>?> placeDetails(String placeId) => _directionsService.placeDetails(placeId);

  void setCycleRoute(bool cycling) {
    _cycleRoute = cycling;
    notifyListeners();
  }

  /// Fetches a route to preview (distance/ETA) without starting navigation.
  Future<bool> fetchPreviewRoute(String destination) async {
    if (_userLocation == null) await _refreshUserLocation();
    final origin = _userLocation;
    if (origin == null) return false;

    _isFetchingRoute = true;
    _destinationName = destination;
    notifyListeners();

    final route = await _directionsService.fetchRoute(origin: origin, destination: destination, cycling: _cycleRoute);
    _previewRoute = route;
    _isFetchingRoute = false;
    notifyListeners();
    return route != null;
  }

  Future<void> startNavigation() async {
    final route = _previewRoute;
    if (route == null) return;

    _activeRoute = route;
    _previewRoute = null;
    _navMode = NavMode.navigating;
    notifyListeners();

    _setupRouteTracker(route);
    await _bleService.sendRoute(_projectRoute(route));
  }

  void _setupRouteTracker(DirectionsRoute route) {
    _routeTracker = RouteTracker(_projectRoute(route), stepBoundariesM: route.stepBoundariesMeters);
  }

  List<({double x, double y})> _projectRoute(DirectionsRoute route) {
    return route.polylinePoints.map((p) => projectLatLon(p.latitude, p.longitude)).toList();
  }

  Future<void> _recalculateRoute() async {
    if (_isFetchingRoute || _userLocation == null || _destinationName.isEmpty) return;
    _isFetchingRoute = true;
    notifyListeners();

    final route = await _directionsService.fetchRoute(
      origin: _userLocation!,
      destination: _destinationName,
      cycling: _cycleRoute,
    );
    if (route != null) {
      _activeRoute = route;
      _setupRouteTracker(route);
      await _bleService.sendRoute(_projectRoute(route));
    }
    _isFetchingRoute = false;
    notifyListeners();
  }

  /// Cancels navigation before arrival (user-initiated).
  void stopNavigation() {
    _endNavigation();
  }

  /// Called once the user acknowledges the arrival screen.
  void acknowledgeArrival() {
    _endNavigation();
  }

  void _endNavigation() {
    _navMode = NavMode.home;
    _activeRoute = null;
    _previewRoute = null;
    _routeTracker = null;
    _distanceRemainingM = null;
    _destinationName = '';
    unawaited(_bleService.clearRoute());
    notifyListeners();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _telemetryTimer?.cancel();
    _bleService.dispose();
    super.dispose();
  }
}
