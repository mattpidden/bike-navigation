import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue/flutter_blue.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;

class Notifier with ChangeNotifier {
  static const String _esp32DeviceName = 'ESP32'; // Target device name fragment
  BluetoothDevice? _esp32Device;
  StreamSubscription<BluetoothDeviceState>? _deviceStateSub;
  Timer? _mainBluetoothTimer; // Handles the periodic check/reconnect logic
  bool _scanningForDevice =
      false; // Flag to prevent multiple scans simultaneously
  BluetoothCharacteristic? _esp32Characteristic;
  bool _bluetoothConnected = false;

  LatLng? _userLocation;

  List<dynamic> _steps = [];
  List<LatLng> _polylinePoints = [];
  LatLng _startPoint = LatLng(0.0, 0.0);
  LatLng _finishPoint = LatLng(0.0, 0.0);
  bool _cycleRoute = false;
  int _currentStepIndex = 0;
  double _heading = 0.0;
  double? _remainingDistanceMeters;
  bool _recalculating = false;
  String _currentInstruction = '';
  String _currentDistance = '';
  List<dynamic> _upcomingSteps = [];
  bool _navigating = false;

  StreamSubscription<Position>? _positionStream;
  StreamSubscription<CompassEvent>? _compassStream;
  Timer? _bleTimer;
  int _lastUpdateMs = 0;
  late final String _apiKey;
  // In Notifier class
  List<LatLng> _drivingPolylinePoints = [];
  List<LatLng> _cyclingPolylinePoints = [];
  String _destinationName =
      ''; // To store the destination name for easy retrieval
  bool _isRouteFetching = false;

// New Getters
  List<LatLng> get drivingPolylinePoints => _drivingPolylinePoints;
  List<LatLng> get cyclingPolylinePoints => _cyclingPolylinePoints;
  bool get isRouteFetching => _isRouteFetching;
  String get destinationName => _destinationName;

  // GETTERS
  bool get bluetoothConnected => _bluetoothConnected;
  LatLng? get userLocation => _userLocation;
  List<LatLng> get polylinePoints => _polylinePoints;
  LatLng get startPoint => _startPoint;
  LatLng get finishPoint => _finishPoint;
  bool get cycleRoute => _cycleRoute;
  int get currentStepIndex => _currentStepIndex;
  double get heading => _heading;
  double? get remainingDistanceMeters => _remainingDistanceMeters;
  bool get recalculating => _recalculating;
  String get currentInstruction => _currentInstruction;
  String get currentDistance => _currentDistance;
  List<dynamic> get upcomingSteps => _upcomingSteps;
  bool get navigating => _navigating;

  Notifier() {
    _apiKey = dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '';
    _init();
  }

  Future<void> _init() async {
    await getLocationPermissions();
    await getUsersLocation();
    startBleAutoConnect();
  }

  Future<bool> getLocationPermissions() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) {
      return false;
    }
    return true;
  }

  Future<void> getUsersLocation() async {
    try {
      final allowed = await getLocationPermissions();
      if (!allowed) return;
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best);
      _userLocation = LatLng(pos.latitude, pos.longitude);
      notifyListeners();
    } catch (e) {
      if (kDebugMode) print('getUsersLocation error: $e');
    }
  }

  void startBleAutoConnect() {
    // 1. Cancel any existing timer
    _mainBluetoothTimer?.cancel();

    // 2. Start the main periodic timer (5s period for check/reconnect)
    _mainBluetoothTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _bluetoothStateCheckAndConnect();
    });
  }

  void stopBleAutoConnect() {
    _mainBluetoothTimer?.cancel();
    _mainBluetoothTimer = null;
    _handleDisconnection(manualDisconnect: true);
  }

  Future<void> _bluetoothStateCheckAndConnect() async {
    // --- STATE 1: NOT CONNECTED ---
    if (!_bluetoothConnected) {
      if (!_scanningForDevice) {
        if (kDebugMode)
          print('State 1: Not Connected. Starting scan/connect attempt...');
        await _attemptScanAndConnect();
      }
    }
    // --- STATE 2: CONNECTED ---
    else {
      // Periodically check if the device is still in the connected state.
      // This acts as your connection health check.
      if (_esp32Device != null) {
        final state = await _esp32Device!.state.first;
        if (state != BluetoothDeviceState.connected) {
          if (kDebugMode)
            print(
                'State 2: Connection lost (State: $state). Handling disconnection.');
          await _handleDisconnection(); // Transition to State 1
        } else {
          // Connection confirmed. Execute periodic BLE task (e.g., sending data).
          if (kDebugMode)
            print('State 2: Connected. Sending periodic BLE tick.');
          _periodicBleTick();
        }
      }
    }
  }

  // New combined method to fetch both routes
  Future<void> fetchDualDirections(String destination) async {
    if (_userLocation == null) {
      await getUsersLocation();
      if (_userLocation == null) return;
    }

    _isRouteFetching = true;
    _destinationName = destination;
    notifyListeners();

    // Define route fetching logic (reusing or creating a helper function)
    Future<List<LatLng>> _getRoutePolyline(String mode) async {
      final origin = '${_userLocation!.latitude},${_userLocation!.longitude}';
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json?origin=$origin&destination=${Uri.encodeComponent(destination)}&mode=$mode&key=$_apiKey',
      );
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final routes = data['routes'];
        if (routes != null && routes.isNotEmpty) {
          List<LatLng> polyline = [];
          // This is simplified; the full implementation needs step data for actual navigation
          for (var step in routes[0]['legs'][0]['steps']) {
            if (step['polyline'] != null &&
                step['polyline']['points'] != null) {
              polyline.addAll(_decodePolyline(step['polyline']['points']));
            }
          }
          // Add final point
          polyline.add(LatLng(
            (routes[0]['legs'][0]['steps'].last['end_location']['lat'] as num)
                .toDouble(),
            (routes[0]['legs'][0]['steps'].last['end_location']['lng'] as num)
                .toDouble(),
          ));
          return polyline;
        }
      }
      return [];
    }

    // Fetch both routes concurrently
    final results = await Future.wait([
      _getRoutePolyline("driving"),
      _getRoutePolyline("bicycling"),
    ]);

    _drivingPolylinePoints = results[0];
    _cyclingPolylinePoints = results[1];
    _isRouteFetching = false;
    notifyListeners();
  }

  Future<void> _attemptScanAndConnect() async {
    if (_scanningForDevice) return;
    _scanningForDevice = true;
    notifyListeners();

    try {
      // 1. Scan for ESP32
      final scanStream =
          FlutterBlue.instance.scan(timeout: const Duration(seconds: 8));
      final scanResult = await scanStream.firstWhere(
        (sr) {
          final name = sr.device.name ?? '';
          return name.toLowerCase().contains(_esp32DeviceName.toLowerCase());
        },
        orElse: () => throw '$_esp32DeviceName not found',
      );

      FlutterBlue.instance.stopScan();

      // 2. Found device, set it up
      _esp32Device = scanResult.device;

      // 3. Subscribe to state changes before connecting (Critical for monitoring disconnections)
      await _deviceStateSub?.cancel();
      _deviceStateSub = _esp32Device!.state.listen((state) async {
        if (state == BluetoothDeviceState.disconnected) {
          if (kDebugMode)
            print(
                'Device state subscription detected DISCONNECTED. Triggering cleanup.');
          // The main periodic timer will catch this, but we clean up immediately.
          await _handleDisconnection();
        } else if (state == BluetoothDeviceState.connected) {
          if (kDebugMode)
            print('Device state subscription detected CONNECTED.');
          // This ensures state is updated if the connection happens outside the main connect call (e.g., auto-reconnect if enabled).
          if (!_bluetoothConnected) await _handleConnection();
        }
      });

      // 4. Connect to device
      try {
        // 4. Attempt to connect to device. THIS IS THE LINE THAT WAS FAILING.
        await _esp32Device!
            .connect(timeout: const Duration(seconds: 10), autoConnect: false);

        // 5. Discover services and finalize connection setup ONLY if connect succeeds
        await _handleConnection();
      } catch (e) {
        // Handle TimeoutException or other connection failures gracefully.
        if (kDebugMode) {
          print('Connection attempt failed or timed out: $e');
        }
        // Crucial: Manually trigger disconnection logic to clean up the stale device reference
        // and ensure the next periodic cycle attempts a full scan again.
        await _handleDisconnection();
      }
    } catch (e) {
      if (kDebugMode)
        print('Scan/Connect failed: $e. Will retry on next timer tick.');
      // Connection failed, state remains !_bluetoothConnected, timer will retry.
    } finally {
      _scanningForDevice = false;
      notifyListeners();
    }
  }

  Future<void> _handleConnection() async {
    if (_bluetoothConnected) return; // Already connected

    try {
      if (_esp32Device == null) throw 'Device is null in _handleConnection';

      final services = await _esp32Device!.discoverServices();
      bool characteristicFound = false;

      // Find the first characteristic that supports writing
      for (var s in services) {
        for (var c in s.characteristics) {
          if (c.properties.write) {
            _esp32Characteristic = c;
            characteristicFound = true;
            break;
          }
        }
        if (characteristicFound) break;
      }

      if (characteristicFound) {
        _bluetoothConnected = true;
        if (kDebugMode)
          print('*** Bluetooth CONNECTED and Characteristic found. ***');
      } else {
        // Did connect, but failed to find required characteristic
        if (kDebugMode)
          print(
              'Connected but failed to find writable characteristic. Disconnecting.');
        await _esp32Device!.disconnect();
        await _handleDisconnection();
      }
    } catch (e) {
      if (kDebugMode) print('_handleConnection error: $e');
      await _handleDisconnection();
    } finally {
      notifyListeners();
    }
  }

  Future<void> _handleDisconnection({bool manualDisconnect = false}) async {
    if (!_bluetoothConnected && !manualDisconnect)
      return; // Already disconnected

    _bluetoothConnected = false;
    _esp32Characteristic = null;
    await _deviceStateSub?.cancel(); // Stop listening to the old device state

    if (_esp32Device != null && !manualDisconnect) {
      // Small delay to ensure the OS/FlutterBlue finishes internal cleanup
      await Future.delayed(const Duration(milliseconds: 500));
    }
    _esp32Device = null;

    // The main periodic timer (_mainBluetoothTimer) will take care of the transition
    // back to STATE 1 (Not Connected) and initiate a new search/connect cycle.
    if (kDebugMode) print('*** Bluetooth DISCONNECTED and state reset. ***');
    notifyListeners();
  }

  Future<List<dynamic>> placeAutocomplete(String input,
      {double? lat, double? lng}) async {
    if (input.isEmpty) return [];
    Uri url;
    if (lat == null || lng == null) {
      url = Uri.parse(
          'https://maps.googleapis.com/maps/api/place/autocomplete/json?input=${Uri.encodeComponent(input)}&key=$_apiKey');
    } else {
      url = Uri.parse(
          'https://maps.googleapis.com/maps/api/place/autocomplete/json?input=${Uri.encodeComponent(input)}&location=$lat,$lng&radius=10000&key=$_apiKey');
    }
    final res = await http.get(url);
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      return data['predictions'] ?? [];
    }
    return [];
  }

  Future<Map<String, dynamic>?> placeDetailsFromPlaceId(String placeId) async {
    if (placeId.isEmpty) return null;
    final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/place/details/json?place_id=$placeId&key=$_apiKey');
    final res = await http.get(url);
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      return data['result'];
    }
    return null;
  }

  void updateCycleRoutePreference(bool cycleRoute) {
    _cycleRoute = cycleRoute;
    notifyListeners();
  }

  Future<void> writeToESP32Bluetooth(String message,
      {bool withoutResponse = false}) async {
    try {
      if (_esp32Characteristic == null) return;
      final bytes = utf8.encode(message);
      await _esp32Characteristic!
          .write(bytes, withoutResponse: withoutResponse);
    } catch (e) {
      if (kDebugMode) print('writeToESP32Bluetooth error: $e');
    }
  }

  Future<void> fetchDirections(String destination) async {
    if (_userLocation == null) {
      await getUsersLocation();
      if (_userLocation == null) return;
    }
    _recalculating = true;
    notifyListeners();
    final origin = '${_userLocation!.latitude},${_userLocation!.longitude}';
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json?origin=$origin&destination=${Uri.encodeComponent(destination)}&mode=${cycleRoute ? "bicycling" : "driving"}&key=$_apiKey',
    );
    final res = await http.get(url);
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      final routes = data['routes'];
      if (routes == null || routes.isEmpty) {
        _steps = [];
        _polylinePoints = [];
        _startPoint = LatLng(0.0, 0.0);
        _finishPoint = LatLng(0.0, 0.0);
        _recalculating = false;
        notifyListeners();
        return;
      }
      _steps = routes[0]['legs'][0]['steps'] ?? [];
    } else {
      _steps = [];
      _recalculating = false;
      notifyListeners();
      return;
    }

    if (_steps.isEmpty) {
      _recalculating = false;
      notifyListeners();
      return;
    }

    final firstHtml = _cleanInstruction(_steps.first['html_instructions']);
    for (int i = 0; i < _steps.length - 1; i++) {
      _steps[i]['html_instructions'] =
          _cleanInstruction(_steps[i + 1]['html_instructions']);
    }
    _steps.last['html_instructions'] = "You have arrived at your destination.";

    _currentStepIndex = 0;
    _setupMapData();
    _recalculating = false;
    notifyListeners();
  }

  void startNavigation(String destination) async {
    if (_navigating) return;
    _navigating = true;
    notifyListeners();
    await fetchDirections(destination);
    _listenToLocation();
    _listenToCompass();
  }

  void stopNavigation() {
    _navigating = false;
    _positionStream?.cancel();
    _compassStream?.cancel();
    _steps = [];
    _polylinePoints = [];
    _currentInstruction = '';
    _currentDistance = '';
    notifyListeners();
  }

  void _periodicBleTick() {
    if (!_bluetoothConnected) return;
    final icon = _iconToString(_getDirectionIcon(_currentInstruction));
    final distance = _currentDistance;
    final roadName = _extractRoadName(_steps.isNotEmpty
        ? _steps[_currentStepIndex]['html_instructions']
        : '');
    final payload = {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'mode': _navigating ? 'nav' : 'home',
      'icon': icon,
      'distance': distance,
      'road': roadName,
    };
    final jsonString = jsonEncode(payload);
    writeToESP32Bluetooth(jsonString, withoutResponse: false);
  }

  void _listenToLocation() async {
    try {
      await Geolocator.requestPermission();
    } catch (_) {}
    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
    ).listen((pos) {
      final loc = LatLng(pos.latitude, pos.longitude);
      _userLocation = loc;
      notifyListeners();
      if (_steps.isNotEmpty) _updateProgress(loc);
    });
  }

  void _listenToCompass() {
    _compassStream?.cancel();
    _compassStream = FlutterCompass.events!.listen((event) {
      _heading = event.heading ?? 0;
      notifyListeners();
    });
  }

  void _setupMapData() {
    if (_steps.isEmpty) {
      _polylinePoints = [const LatLng(51.4545, -2.5879)];
      _startPoint = _polylinePoints.first;
      _finishPoint = _polylinePoints.last;
      return;
    }
    _polylinePoints = [];
    for (var step in _steps) {
      if (step['polyline'] != null && step['polyline']['points'] != null) {
        final encoded = step['polyline']['points'];
        _polylinePoints.addAll(_decodePolyline(encoded));
      }
    }
    _polylinePoints.add(LatLng(
      (_steps.last['end_location']['lat'] as num).toDouble(),
      (_steps.last['end_location']['lng'] as num).toDouble(),
    ));
    _startPoint = _polylinePoints.first;
    _finishPoint = _polylinePoints.last;
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;
    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;
      poly.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return poly;
  }

  String _cleanInstruction(String instruction) {
    String clean_instruction = instruction
        .replaceAll(RegExp(r'<div.*?>'), '. ')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
    clean_instruction = clean_instruction.endsWith('.')
        ? clean_instruction
        : '$clean_instruction.';
    return clean_instruction;
  }

  IconData _getDirectionIcon(String? instruction) {
    if (instruction == null) return Icons.navigation;
    final lower = instruction.toLowerCase();
    if (lower.contains('turn left')) return Icons.turn_left;
    if (lower.contains('turn right')) return Icons.turn_right;
    if (lower.contains('uturn')) return Icons.u_turn_left;
    if (lower.contains('arrived at your destination'))
      return Icons.sports_score;
    return Icons.straight;
  }

  String _iconToString(IconData icon) {
    if (icon == Icons.turn_left) return 'left';
    if (icon == Icons.turn_right) return 'right';
    if (icon == Icons.u_turn_left) return 'uturn';
    if (icon == Icons.navigation || icon == Icons.straight) return 'straight';
    if (icon == Icons.sports_score) return 'finish';
    return 'straight';
  }

  String _extractRoadName(String instruction) {
    final match = RegExp(r'onto (.+?)(?:\.|$)').firstMatch(instruction);
    return match?.group(1)?.trim() ?? '';
  }

  void _updateProgress(LatLng loc) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastUpdateMs < 2000) return;
    _lastUpdateMs = now;
    if (_steps.isEmpty) return;
    final distanceCalc = const Distance();
    double minDist = double.infinity;
    int closestStep = _currentStepIndex;
    for (int i = 0; i < _steps.length; i++) {
      final step = _steps[i];
      final stepLat = (step['start_location']['lat'] as num).toDouble();
      final stepLng = (step['start_location']['lng'] as num).toDouble();
      final d =
          distanceCalc.as(LengthUnit.Meter, loc, LatLng(stepLat, stepLng));
      if (d < minDist) {
        minDist = d;
        closestStep = i;
      }
    }
    if (closestStep > _currentStepIndex && minDist < 15) {
      _currentStepIndex = closestStep;
    }
    final step = _steps[_currentStepIndex];
    final stepEnd = LatLng(
      (step['end_location']['lat'] as num).toDouble(),
      (step['end_location']['lng'] as num).toDouble(),
    );
    _remainingDistanceMeters = distanceCalc.as(LengthUnit.Meter, loc, stepEnd);
    final endDist = distanceCalc.as(LengthUnit.Meter, loc, _finishPoint);
    if (endDist < 15) {
      stopNavigation();
      return;
    }
    String distanceDisplay = '';
    if (_remainingDistanceMeters != null) {
      if (_remainingDistanceMeters! >= 250) {
        distanceDisplay =
            (_remainingDistanceMeters! / 1609).toStringAsFixed(1) + ' mi';
      } else {
        distanceDisplay =
            (_remainingDistanceMeters! * 1.09361).toStringAsFixed(0) + ' yd';
      }
    }
    final currentStep = _steps.isNotEmpty ? _steps[_currentStepIndex] : null;
    _currentInstruction = (currentStep?['html_instructions'] ?? '');
    _currentDistance = distanceDisplay.isNotEmpty
        ? distanceDisplay
        : (currentStep?['distance']?['text'] ?? '');
    _upcomingSteps = _steps.length > _currentStepIndex + 1
        ? _steps.sublist(_currentStepIndex + 1)
        : [];
    final icon = _getDirectionIcon(step['html_instructions']);
    final roadName = _extractRoadName(step['html_instructions']);
    final payload = {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'mode': 'nav',
      'icon': _iconToString(icon),
      'distance': _currentDistance,
      'road': roadName
    };
    final jsonString = jsonEncode(payload);
    writeToESP32Bluetooth(jsonString, withoutResponse: false);
    if (!_isOnRoute(loc)) {
      fetchDirections('${_finishPoint.latitude},${_finishPoint.longitude}');
    }
    notifyListeners();
  }

  bool _isOnRoute(LatLng user, {double threshold = 20}) {
    final distance = const Distance();
    double minDistance = double.infinity;
    for (int i = 0; i < _polylinePoints.length - 1; i++) {
      final d = _perpendicularDistanceToSegment(
          user, _polylinePoints[i], _polylinePoints[i + 1], distance);
      if (d < minDistance) minDistance = d;
    }
    return minDistance < threshold;
  }

  double _perpendicularDistanceToSegment(
      LatLng p, LatLng v, LatLng w, Distance distance) {
    final double total = distance(v, w);
    if (total == 0) return distance(p, v);
    final double bearingVW = distance.bearing(v, w);
    final double bearingVP = distance.bearing(v, p);
    final double distVP = distance(v, p);
    final double dXt =
        (distVP * (sin((bearingVP - bearingVW) * pi / 180)).abs());
    final double dAt =
        acos(cos(distVP / 6371000) / cos(dXt / 6371000)) * 6371000;
    if (dAt > total) return distance(p, w);
    if (dAt < 0) return distance(p, v);
    return dXt;
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _compassStream?.cancel();
    _mainBluetoothTimer?.cancel(); // Cancel the main timer
    _deviceStateSub?.cancel();
    super.dispose();
  }
}
