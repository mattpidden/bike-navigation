import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bike_navigation/arrived_page.dart';
import 'package:bike_navigation/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue/flutter_blue.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class DirectionsPage extends StatefulWidget {
  final String destination;
  final BluetoothCharacteristic? esp32Characteristic;
  const DirectionsPage({super.key, required this.destination, required this.esp32Characteristic});

  @override
  State<DirectionsPage> createState() => _DirectionsPageState();
}

class _DirectionsPageState extends State<DirectionsPage> {
  List<dynamic> steps = [];
   List<LatLng> _polylinePoints = [];
   LatLng _startPoint = LatLng(0.0, 0.0);
   LatLng _finishPoint = LatLng(0.0, 0.0);
  late final String _apiKey;
  LatLng? _userLocation;
double _heading = 0.0;
int _currentStepIndex = 0;
StreamSubscription<Position>? _positionStream;
StreamSubscription<CompassEvent>? _compassStream;
MapController mapController = MapController();
String? initialInstruction;
double? _remainingDistanceMeters;
bool firstcall = false;
bool recalculating = false;
String currentInstruction = "";
String currentDistance = "";
List<dynamic> upcomingSteps = [];
int _lastUpdateMs = 0;


  @override
  void initState() {
    super.initState();   
     _apiKey = dotenv.env['GOOGLE_MAPS_API_KEY']!;
    _listenToLocation();
  _listenToCompass();
  }


  void _sendBleUpdate(String icon, String distance, String roadName) {
  if (_userLocation == null) return;

  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final payload = {
    'timestamp': timestamp,
    'mode': 'nav',
    'icon': icon,
    'distance': distance,
    'road': roadName
  };

  final jsonString = jsonEncode(payload);

  // assume you have a connected BLE characteristic named `esp32Characteristic`
  // and it supports write without response
  try {
    widget.esp32Characteristic?.write(utf8.encode(jsonString), withoutResponse: false);
    debugPrint('BLE write sent: $jsonString');
  } catch (e) {
    debugPrint('BLE write failed: $e');
  }
}


  String _cleanInstruction(String instruction) {
    String clean_instruction = instruction
        .replaceAll(RegExp(r'<div.*?>'), '. ')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
         clean_instruction =
    clean_instruction.endsWith('.') ? clean_instruction : '$clean_instruction.';
    return clean_instruction;
  }

  

  void _loadInstructions() async {
    setState(() {
      recalculating = true;
    });
    final url = Uri.parse(
    'https://maps.googleapis.com/maps/api/directions/json'
    '?origin=${_userLocation?.latitude},${_userLocation?.longitude}'
    '&destination=${widget.destination}'
    '&mode=bicycling'
    '&key=$_apiKey',
  );
  final res = await http.get(url);
  if (res.statusCode == 200) {
    final data = jsonDecode(res.body);
    final routes = data['routes'];
    if (routes == null || routes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No route found')),
      );
      return;
    }
   steps = routes[0]['legs'][0]['steps'] ?? [];
  } else {
    debugPrint('Error fetching directions: ${res.statusCode}');
    return;
  }

  if (steps.isEmpty) return;
  // store the very first instruction separately
  initialInstruction = _cleanInstruction(steps.first['html_instructions']);

  // shift instructions forward
  for (int i = 0; i < steps.length - 1; i++) {
    steps[i]['html_instructions'] = _cleanInstruction(steps[i + 1]['html_instructions']);
  }

  // clear the last instruction (no next step)
  steps.last['html_instructions'] = "You have arrived at your destination.";
  setState(() {
    _currentStepIndex = 0;
  });
  _setupMapData();
    setState(() {
      recalculating = false;
    });
  return;
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


  void _setupMapData() {
    if (steps.isEmpty) {
      _polylinePoints = [const LatLng(51.4545, -2.5879)];
      _startPoint = _polylinePoints.first;
      _finishPoint = _polylinePoints.last;
      return;
    }

    _polylinePoints = [];
for (var step in steps) {
  if (step['polyline'] != null && step['polyline']['points'] != null) {
    final encoded = step['polyline']['points'];
    _polylinePoints.addAll(_decodePolyline(encoded));
  }
}


    _polylinePoints.add(  LatLng(
      (steps.last['end_location']['lat'] as num).toDouble(),
      (steps.last['end_location']['lng'] as num).toDouble(),
    ));

    _startPoint = _polylinePoints.first;
    _finishPoint = _polylinePoints.last;
  }

  void _listenToLocation() async {
  await Geolocator.requestPermission();
  _positionStream = Geolocator.getPositionStream(
    locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
  ).listen((pos) {
    final loc = LatLng(pos.latitude, pos.longitude);
    setState(() => _userLocation = loc);
    if (firstcall == false) {
      _loadInstructions();
      firstcall = true;
    }
    mapController.move(loc, mapController.camera.zoom);
    _updateProgress(loc);
  });
}

void _listenToCompass() {
  _compassStream = FlutterCompass.events!.listen((event) {
    setState(() => _heading = event.heading ?? 0);
  });
}

String iconToString(IconData icon) {
  if (icon == Icons.turn_left) return 'left';
  if (icon == Icons.turn_right) return 'right';
  if (icon == Icons.u_turn_left) return 'uturn';
  if (icon == Icons.navigation || icon == Icons.straight) return 'straight';
  if (icon == Icons.sports_score) return 'finish';
  return 'straight';
}


void _updateProgress(LatLng loc) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - _lastUpdateMs < 2000) return; // skip if less than 2000ms since last
  _lastUpdateMs = now;
  if (steps.isEmpty) return;
  final distanceCalc = const Distance();

  // find which step the user is closest to
  double minDist = double.infinity;
  int closestStep = _currentStepIndex;

  for (int i = 0; i < steps.length; i++) {
    final step = steps[i];
    final stepLat = (step['start_location']['lat'] as num).toDouble();
    final stepLng = (step['start_location']['lng'] as num).toDouble();
    final d = distanceCalc.as(LengthUnit.Meter, loc, LatLng(stepLat, stepLng));
    if (d < minDist) {
      minDist = d;
      closestStep = i;
    }
  }

  // if we've reached/passed the next instruction
  if (closestStep > _currentStepIndex && minDist < 25) {
    setState(() => _currentStepIndex = closestStep);
  }

  final step = steps[_currentStepIndex];
  final stepEnd = LatLng(
    (step['end_location']['lat'] as num).toDouble(),
    (step['end_location']['lng'] as num).toDouble(),
  );

  _remainingDistanceMeters = distanceCalc.as(LengthUnit.Meter, loc, stepEnd);


  // destination reached
  final endDist = distanceCalc.as(LengthUnit.Meter, loc, _finishPoint);
  if (endDist < 20) {
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ArrivedPage(destination: widget.destination, esp32Characteristic: widget.esp32Characteristic,)));
    return;
  }

        String distanceDisplay = '';
    if (_remainingDistanceMeters != null) {
      if (_remainingDistanceMeters! >= 250) {
        distanceDisplay = (_remainingDistanceMeters! / 1609).toStringAsFixed(1) + ' mi';
      } else {
        distanceDisplay = (_remainingDistanceMeters! * 1.09361).toStringAsFixed(0) + ' yd';
      }
    }
final currentStep = steps.isNotEmpty
    ? steps[_currentStepIndex]
    : null;
     currentInstruction = (currentStep?['html_instructions'] ?? '');
 currentDistance = distanceDisplay.isNotEmpty
    ? distanceDisplay
    : (currentStep?['distance']?['text'] ?? '');
 upcomingSteps = steps.length > _currentStepIndex + 1
    ? steps.sublist(_currentStepIndex + 1)
    : [];

  


  final icon = _getDirectionIcon(step['html_instructions']);
  // extract part after "onto " but before "." from step["html_instructions"] to get road name
  final roadName = RegExp(r'onto (.+?)(?:\.|$)')
    .firstMatch(step['html_instructions'])
    ?.group(1)
    ?.trim() ?? '';
  _sendBleUpdate(iconToString(icon), distanceDisplay, roadName);


  // if genuinely off-route (not just GPS noise)
  if (!_isOnRoute(loc)) {
    print('off route detected');
    _loadInstructions();
  }
}


bool _isOnRoute(LatLng user, {double threshold = 20}) {
  final distance = const Distance();
  double minDistance = double.infinity;

  for (int i = 0; i < _polylinePoints.length - 1; i++) {
    final d = _perpendicularDistanceToSegment(user, _polylinePoints[i], _polylinePoints[i + 1], distance);
    if (d < minDistance) minDistance = d;
  }

  print(minDistance);
  return minDistance < threshold;
}

double _perpendicularDistanceToSegment(LatLng p, LatLng v, LatLng w, Distance distance) {
  final double total = distance(v, w);
  if (total == 0) return distance(p, v);

  // bearing from v→w and v→p
  final double bearingVW = distance.bearing(v, w);
  final double bearingVP = distance.bearing(v, p);

  // cross-track error formula (Haversine-based)
  final double distVP = distance(v, p);
  final double dXt = (distVP * 
    (sin((bearingVP - bearingVW) * pi / 180)).abs());

  // along-track distance
  final double dAt = acos(cos(distVP / 6371000) /
      cos(dXt / 6371000)) * 6371000;

  // if projection lies beyond the segment, clamp to nearest end
  if (dAt > total) return distance(p, w);
  if (dAt < 0) return distance(p, v);

  return dXt;
}






  IconData _getDirectionIcon(String? instruction) {
    if (instruction == null) return Icons.navigation;
    final lower = instruction.toLowerCase();
    if (lower.contains('turn left')) return Icons.turn_left;
    if (lower.contains('turn right')) return Icons.turn_right;
    if (lower.contains('uturn')) return Icons.u_turn_left;
    if (lower.contains('arrived at your destination')) return Icons.sports_score;
    return Icons.straight; // default straight
  }

  @override
  void dispose() {
    // TODO: implement dispose
    super.dispose();
_positionStream?.cancel();
_compassStream?.cancel();
  }


  @override
  Widget build(BuildContext context) {


    return Scaffold(
      appBar: AppBar(title: const Text('Directions'), actions: [IconButton(onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => HomePage(givenesp32Characteristic: widget.esp32Characteristic,))), icon: Icon(Icons.cancel))],),
      body: Column(
        children: [
          // Top half: Map + current instruction
          if (recalculating == true)
          Container(
            height: 50,
            width: double.infinity,
             margin: const EdgeInsets.all(8),
             padding: const EdgeInsets.all(16),
                    color: Colors.blue.shade50,
                    child: Center(child: Text("Recalculating route ..."),),
          ),
          if (_currentStepIndex == 0)
          Container(
            height: 50,
            width: double.infinity,
             margin: const EdgeInsets.all(8),
             padding: const EdgeInsets.all(16),
                    color: Colors.orange.shade50,
                    child: Center(child: Text(initialInstruction ?? "Please proceed to the highlighted route."),),
          ),
          Expanded(
            flex: 1,
            child: Row(
              children: [
                // Left: Map
                Expanded(
                  flex: 1,
                  child: Container(                    margin: const EdgeInsets.all(8),

                    child: FlutterMap(
                      mapController: mapController,
                      options: MapOptions(
                        initialCenter: _userLocation ?? _startPoint,
                        initialZoom: 17,
                        interactionOptions: InteractionOptions(
                          flags: InteractiveFlag.none
                        ),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.bikenavigation',
                        ),
                        if(_polylinePoints.isNotEmpty) PolylineLayer(
                          polylines: [
                            Polyline(
                              points: _polylinePoints,
                              strokeWidth: 5,
                              color: Colors.orange,
                            ),
                          ],
                        ),
                        MarkerLayer(
                          markers: [
                            if (_userLocation != null)
                            Marker(
                              point: _userLocation!,
                              width: 40,
                              height: 40,
                              child: Transform.rotate(
                                angle: _heading * (pi / 180),
                                child:  Icon(
                                  _heading == 0.0 ? Icons.circle : Icons.navigation,
                                  color: Colors.blueAccent,
                                  size: 20,
                                ),
                              ),
                            ),
                       

                            Marker(
                              point: _startPoint,
                              width: 40,
                              height: 40,
                              child: const Icon(
                                Icons.location_on,
                                color: Colors.red,
                                size: 40,
                              ),
                            ),
                            Marker(
                              point: _finishPoint,
                              width: 40,
                              height: 40,
                              
                              child: const Icon(
                                Icons.sports_score,
                                color: Colors.black,
                                
                                size: 40,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                // Right: Current instruction
                Expanded(
                  flex: 1,
                  child: Container(
                    margin: const EdgeInsets.all(8),
                    padding: const EdgeInsets.all(16),
                    color: Colors.orange.shade50,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _getDirectionIcon(currentInstruction),
                          size: 72,
                          color: Colors.orange,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          currentInstruction ?? 'Start',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          currentDistance,
                          style: const TextStyle(
                            fontSize: 18,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Bottom half: List of upcoming steps
          Expanded(
            flex: 1,
            child: ListView.builder(
              itemCount: upcomingSteps.length,
              itemBuilder: (context, index) {
                final step = upcomingSteps[index];
                String instruction = (step['html_instructions'] ?? '');

                final distance = step['distance']?['text'] ?? '';
                // distance is a string like 74 m or 0.4 km. lets turn it into a string of yd and mi
                String distanceDisplay = '';
                final distValue = step['distance']?['value'] ?? 0; // in meters
                if (distValue >= 250) {
                  distanceDisplay = (distValue / 1609).toStringAsFixed(1) + ' mi';
                } else {
                  distanceDisplay = (distValue * 1.09361).toStringAsFixed(0) + ' yd';
                }
                return ListTile(
                  leading: Icon(_getDirectionIcon(instruction)),
                  title: Text(
                    instruction ?? 'Step ${index + 1}',
                    style: const TextStyle(fontSize: 16),
                  ),
                  subtitle: Text(distanceDisplay),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
