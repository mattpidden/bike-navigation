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
  final double totalDurationSeconds;

  const DirectionsRoute({
    required this.steps,
    required this.polylinePoints,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
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
    final routes = await _fetchRoutes(origin: origin, destination: destination, cycling: cycling, alternatives: false);
    return routes.isEmpty ? null : routes.first;
  }

  /// Google has no parameter for "prefer cycle paths" as a distinct mode —
  /// this just requests whatever alternative route candidates Google's own
  /// bicycling engine offers (not guaranteed to be exactly 2, not labeled by
  /// infrastructure preference) and sorts them fastest-first; the caller
  /// decides how to present them (e.g. "Fastest" / "Alternative route").
  Future<List<DirectionsRoute>> fetchRouteAlternatives({
    required LatLng origin,
    required String destination,
    required bool cycling,
  }) async {
    final routes = await _fetchRoutes(origin: origin, destination: destination, cycling: cycling, alternatives: true);
    routes.sort((a, b) => a.totalDurationSeconds.compareTo(b.totalDurationSeconds));
    return routes;
  }

  Future<List<DirectionsRoute>> _fetchRoutes({
    required LatLng origin,
    required String destination,
    required bool cycling,
    required bool alternatives,
  }) async {
    final mode = cycling ? 'bicycling' : 'driving';
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${origin.latitude},${origin.longitude}'
      '&destination=${Uri.encodeComponent(destination)}'
      '&mode=$mode'
      '&alternatives=$alternatives'
      '&key=$_apiKey',
    );
    final res = await http.get(url);
    if (res.statusCode != 200) return [];

    final data = jsonDecode(res.body);
    final rawRoutes = data['routes'];
    if (rawRoutes == null || rawRoutes.isEmpty) return [];

    return [for (final raw in rawRoutes) _parseRoute(raw)].whereType<DirectionsRoute>().toList();
  }

  DirectionsRoute? _parseRoute(dynamic rawRoute) {
    final leg = rawRoute['legs'][0];
    final rawSteps = leg['steps'] as List<dynamic>;
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
    final totalDuration = (leg['duration']?['value'] as num?)?.toDouble() ?? 0.0;
    return DirectionsRoute(
      steps: steps,
      polylinePoints: fullPolyline,
      totalDistanceMeters: totalDistance,
      totalDurationSeconds: totalDuration,
    );
  }

  /// `location`+`radius` bias results toward nearby places; `origin` is a
  /// separate parameter that additionally makes Google return a
  /// `distance_meters` field on every prediction (straight-line distance
  /// from `origin`) — both are sent together when a location is known.
  Future<List<dynamic>> placeAutocomplete(String input, {double? lat, double? lng}) async {
    if (input.isEmpty) return [];
    final url = (lat == null || lng == null)
        ? Uri.parse(
            'https://maps.googleapis.com/maps/api/place/autocomplete/json'
            '?input=${Uri.encodeComponent(input)}&key=$_apiKey',
          )
        : Uri.parse(
            'https://maps.googleapis.com/maps/api/place/autocomplete/json'
            '?input=${Uri.encodeComponent(input)}&location=$lat,$lng&radius=5000&origin=$lat,$lng&key=$_apiKey',
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
