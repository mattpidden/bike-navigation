import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
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
    _bleService.statusStream.listen((_) => notifyListeners());
    _init();
  }

  late final DirectionsService _directionsService;
  late final BleService _bleService;
  RouteTracker? _routeTracker;

  LatLng? _userLocation;
  double _heading = 0.0;
  bool _cycleRoute = true; // a bike computer defaults to bicycling directions

  StreamSubscription<Position>? _positionSub;
  StreamSubscription<CompassEvent>? _compassSub;
  Timer? _telemetryTimer;

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

  Future<void> _init() async {
    _bleService.start();
    final allowed = await _requestLocationPermission();
    if (!allowed) return;
    await _refreshUserLocation();
    _listenToLocation();
    _listenToCompass();
    _startTelemetryTimer();
  }

  Future<bool> _requestLocationPermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
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
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 5),
    ).listen(_onPosition);
  }

  void _listenToCompass() {
    _compassSub?.cancel();
    _compassSub = FlutterCompass.events?.listen((event) {
      _heading = event.heading ?? _heading;
    });
  }

  void _startTelemetryTimer() {
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sendTelemetry());
  }

  void _onPosition(Position pos) {
    _userLocation = LatLng(pos.latitude, pos.longitude);

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
    _compassSub?.cancel();
    _telemetryTimer?.cancel();
    _bleService.dispose();
    super.dispose();
  }
}
