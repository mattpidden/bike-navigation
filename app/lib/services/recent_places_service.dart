import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A place the user has actually picked (from search or recents), with real
/// coordinates — not just a text description. Search results only carry a
/// `place_id` until resolved via `placeDetails`; this is that resolved form.
class SelectedPlace {
  final String description;
  final double lat;
  final double lng;

  const SelectedPlace({required this.description, required this.lat, required this.lng});

  Map<String, dynamic> toJson() => {'description': description, 'lat': lat, 'lng': lng};

  static SelectedPlace? tryFromJson(Map<String, dynamic> json) {
    final lat = json['lat'], lng = json['lng'];
    if (json['description'] is! String || lat is! num || lng is! num) return null;
    return SelectedPlace(description: json['description'] as String, lat: lat.toDouble(), lng: lng.toDouble());
  }
}

/// Persists a capped, most-recent-first list of places the user has
/// selected, so the search page has something useful to show before typing.
class RecentPlacesService {
  static const _key = 'recent_places';
  static const _maxEntries = 8;

  Future<List<SelectedPlace>> getRecent() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    return raw
        .map((s) => SelectedPlace.tryFromJson(jsonDecode(s) as Map<String, dynamic>))
        .whereType<SelectedPlace>()
        .toList();
  }

  /// Adds [place] to the front of the list, de-duplicating by description
  /// and capping the total stored.
  Future<void> addRecent(SelectedPlace place) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await getRecent();
    existing.removeWhere((p) => p.description == place.description);
    final updated = [place, ...existing].take(_maxEntries);
    await prefs.setStringList(_key, [for (final p in updated) jsonEncode(p.toJson())]);
  }
}
