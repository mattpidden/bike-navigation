import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class DirectionsStep {
  final LatLng startLocation;
  final LatLng endLocation;
  final List<LatLng> polylinePoints;
  final double distanceMeters;
  final String instruction; // HTML stripped

  const DirectionsStep({
    required this.startLocation,
    required this.endLocation,
    required this.polylinePoints,
    required this.distanceMeters,
    required this.instruction,
  });
}

class DirectionsRoute {
  final List<DirectionsStep> steps;
  final List<LatLng> polylinePoints;
  final double totalDistanceMeters;

  const DirectionsRoute({
    required this.steps,
    required this.polylinePoints,
    required this.totalDistanceMeters,
  });

  /// Cumulative distance-along-route at the end of each step — what
  /// RouteTracker needs to derive a step index from arc-length.
  List<double> get stepBoundariesMeters {
    var cumulative = 0.0;
    return steps.map((s) {
      cumulative += s.distanceMeters;
      return cumulative;
    }).toList();
  }
}

/// Decodes a Google-encoded polyline string into LatLng points.
List<LatLng> decodePolyline(String encoded) {
  final poly = <LatLng>[];
  var index = 0;
  final len = encoded.length;
  var lat = 0, lng = 0;
  while (index < len) {
    int b, shift = 0, result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    lat += dlat;

    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    lng += dlng;

    poly.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return poly;
}

/// Strips Google's HTML-formatted step instructions down to plain text.
String cleanInstruction(String instruction) {
  final clean = instruction
      .replaceAll(RegExp(r'<div.*?>'), '. ')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .trim();
  return clean.endsWith('.') ? clean : '$clean.';
}

class DirectionsService {
  DirectionsService(this._apiKey);
  final String _apiKey;

  Future<DirectionsRoute?> fetchRoute({
    required LatLng origin,
    required String destination,
    required bool cycling,
  }) async {
    final mode = cycling ? 'bicycling' : 'driving';
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${origin.latitude},${origin.longitude}'
      '&destination=${Uri.encodeComponent(destination)}'
      '&mode=$mode&key=$_apiKey',
    );
    final res = await http.get(url);
    if (res.statusCode != 200) return null;

    final data = jsonDecode(res.body);
    final routes = data['routes'];
    if (routes == null || routes.isEmpty) return null;

    final rawSteps = routes[0]['legs'][0]['steps'] as List<dynamic>;
    if (rawSteps.isEmpty) return null;

    final steps = <DirectionsStep>[];
    final fullPolyline = <LatLng>[];
    for (final raw in rawSteps) {
      final points = raw['polyline']?['points'] != null ? decodePolyline(raw['polyline']['points']) : <LatLng>[];
      fullPolyline.addAll(points);
      steps.add(DirectionsStep(
        startLocation: LatLng(
          (raw['start_location']['lat'] as num).toDouble(),
          (raw['start_location']['lng'] as num).toDouble(),
        ),
        endLocation: LatLng(
          (raw['end_location']['lat'] as num).toDouble(),
          (raw['end_location']['lng'] as num).toDouble(),
        ),
        polylinePoints: points,
        distanceMeters: (raw['distance']?['value'] as num?)?.toDouble() ?? 0.0,
        instruction: cleanInstruction(raw['html_instructions'] ?? ''),
      ));
    }

    final totalDistance = steps.fold<double>(0.0, (sum, s) => sum + s.distanceMeters);
    return DirectionsRoute(steps: steps, polylinePoints: fullPolyline, totalDistanceMeters: totalDistance);
  }

  Future<List<dynamic>> placeAutocomplete(String input, {double? lat, double? lng}) async {
    if (input.isEmpty) return [];
    final url = (lat == null || lng == null)
        ? Uri.parse(
            'https://maps.googleapis.com/maps/api/place/autocomplete/json'
            '?input=${Uri.encodeComponent(input)}&key=$_apiKey',
          )
        : Uri.parse(
            'https://maps.googleapis.com/maps/api/place/autocomplete/json'
            '?input=${Uri.encodeComponent(input)}&location=$lat,$lng&radius=5000&key=$_apiKey',
          );
    final res = await http.get(url);
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body);
    return data['predictions'] ?? [];
  }

  Future<Map<String, dynamic>?> placeDetails(String placeId) async {
    if (placeId.isEmpty) return null;
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/details/json?place_id=$placeId&key=$_apiKey',
    );
    final res = await http.get(url);
    if (res.statusCode != 200) return null;
    final data = jsonDecode(res.body);
    return data['result'];
  }
}
