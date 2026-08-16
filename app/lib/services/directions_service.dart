import 'dart:convert';

import 'package:flutter/foundation.dart';
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

// Google's Directions/Places APIs return HTTP 200 even when the request
// failed (bad/restricted API key, quota exceeded, malformed params) — the
// real outcome is in the body's "status" field, with "error_message" giving
// the specific reason. Logging it here is the only way to see *why* a
// request failed, since callers just get null/[] back.
void _logIfNotOk(String endpoint, Map<String, dynamic> data) {
  final status = data['status'];
  if (status != null && status != 'OK') {
    debugPrint('[DirectionsService] $endpoint status=$status error_message=${data['error_message']}');
  }
}

class DirectionsService {
  DirectionsService(this._apiKey);
  final String _apiKey;

  /// [cycling] selects Google's routing profile, not just a preference
  /// within one profile: `mode=bicycling` actually routes via cycle
  /// lanes/paths and back streets where available, while `mode=driving`
  /// gives the most direct route disregarding cycle infrastructure — a real
  /// difference in Google's own routing engine, not something we're
  /// simulating client-side.
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
      '&mode=$mode'
      '&key=$_apiKey',
    );
    final res = await http.get(url);
    if (res.statusCode != 200) {
      debugPrint('[DirectionsService] directions HTTP ${res.statusCode}: ${res.body}');
      return null;
    }

    final data = jsonDecode(res.body);
    _logIfNotOk('directions', data);
    final rawRoutes = data['routes'];
    if (rawRoutes == null || rawRoutes.isEmpty) {
      debugPrint('[DirectionsService] directions mode=$mode status=${data['status']} returned no routes');
      return null;
    }

    final route = _parseRoute(rawRoutes.first, mode);
    if (route == null) {
      debugPrint('[DirectionsService] directions mode=$mode: route came back but failed to parse (see previous log)');
    }
    return route;
  }

  DirectionsRoute? _parseRoute(dynamic rawRoute, String mode) {
    final leg = rawRoute['legs'][0];
    final rawSteps = leg['steps'] as List<dynamic>;
    if (rawSteps.isEmpty) {
      debugPrint('[DirectionsService] directions mode=$mode: route leg has zero steps');
      return null;
    }

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
    if (res.statusCode != 200) {
      debugPrint('[DirectionsService] autocomplete HTTP ${res.statusCode}: ${res.body}');
      return [];
    }
    final data = jsonDecode(res.body);
    _logIfNotOk('autocomplete', data);
    return data['predictions'] ?? [];
  }

  Future<Map<String, dynamic>?> placeDetails(String placeId) async {
    if (placeId.isEmpty) return null;
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/details/json?place_id=$placeId&key=$_apiKey',
    );
    final res = await http.get(url);
    if (res.statusCode != 200) {
      debugPrint('[DirectionsService] place details HTTP ${res.statusCode}: ${res.body}');
      return null;
    }
    final data = jsonDecode(res.body);
    _logIfNotOk('place details', data);
    return data['result'];
  }
}
