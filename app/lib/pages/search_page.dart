import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../notifiers/notifier.dart';
import '../services/recent_places_service.dart';

/// Full-screen search, pushed from [MapPage]. An empty query shows recently
/// selected places; typing shows live, distance-annotated autocomplete
/// results. Either path resolves to a [SelectedPlace] with real coordinates
/// (not just a text description) that's popped back to the caller.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _recentPlacesService = RecentPlacesService();
  Timer? _debounce;

  List<dynamic> _predictions = [];
  List<SelectedPlace> _recentPlaces = [];
  bool _searching = false;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final recent = await _recentPlacesService.getRecent();
    if (!mounted) return;
    setState(() => _recentPlaces = recent);
  }

  void _onChanged(String value) {
    setState(() {}); // updates the clear button's visibility immediately
    _debounce?.cancel();
    if (value.isEmpty) {
      setState(() => _predictions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _searching = true);
      final results = await context.read<Notifier>().searchPlaces(value);
      if (!mounted) return;
      setState(() {
        _predictions = results;
        _searching = false;
      });
    });
  }

  Future<void> _selectPrediction(dynamic prediction) async {
    final placeId = prediction['place_id'] as String?;
    final description = prediction['description'] as String? ?? '';
    if (placeId == null) return;

    setState(() => _resolving = true);
    final details = await context.read<Notifier>().placeDetails(placeId);
    if (!mounted) return;

    final location = details?['geometry']?['location'];
    if (location == null) {
      setState(() => _resolving = false);
      return;
    }
    final place = SelectedPlace(
      description: description,
      lat: (location['lat'] as num).toDouble(),
      lng: (location['lng'] as num).toDouble(),
    );
    await _recentPlacesService.addRecent(place);
    if (!mounted) return;
    Navigator.pop(context, place);
  }

  String? _distanceLabel(double? meters) {
    if (meters == null) return null;
    return meters >= 1000 ? '${(meters / 1000).toStringAsFixed(1)} km' : '${meters.round()} m';
  }

  double? _distanceToRecent(SelectedPlace place, LatLng? origin) {
    if (origin == null) return null;
    return const Distance().as(LengthUnit.Meter, origin, LatLng(place.lat, place.lng));
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<Notifier>();
    final showingRecent = _controller.text.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search for a destination',
            border: InputBorder.none,
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
          ),
          onChanged: _onChanged,
        ),
      ),
      body: _resolving
          ? const Center(child: CircularProgressIndicator())
          : showingRecent
              ? _buildRecentList(notifier.userLocation)
              : _buildPredictionsList(),
    );
  }

  Widget _buildRecentList(LatLng? origin) {
    if (_recentPlaces.isEmpty) {
      return const Center(child: Text('No recent places yet'));
    }
    return ListView.builder(
      itemCount: _recentPlaces.length,
      itemBuilder: (context, index) {
        final place = _recentPlaces[index];
        final distance = _distanceLabel(_distanceToRecent(place, origin));
        return ListTile(
          leading: const Icon(Icons.history),
          title: Text(place.description),
          trailing: distance == null ? null : Text(distance),
          onTap: () => Navigator.pop(context, place),
        );
      },
    );
  }

  Widget _buildPredictionsList() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_predictions.isEmpty) {
      return const Center(child: Text('No results'));
    }
    return ListView.builder(
      itemCount: _predictions.length,
      itemBuilder: (context, index) {
        final prediction = _predictions[index];
        final distanceMeters = (prediction['distance_meters'] as num?)?.toDouble();
        final distance = _distanceLabel(distanceMeters);
        return ListTile(
          leading: const Icon(Icons.place_outlined),
          title: Text(prediction['description'] ?? ''),
          trailing: distance == null ? null : Text(distance),
          onTap: () => _selectPrediction(prediction),
        );
      },
    );
  }
}
