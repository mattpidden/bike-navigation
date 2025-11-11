import 'package:bike_navigation/notifiers/notifier.dart';
import 'package:bike_navigation/pages/directions_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_map/flutter_map.dart'; // Add this import
import 'package:latlong2/latlong.dart'; // Already imported

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _controller = TextEditingController();
  List<dynamic> _suggestions = [];
  bool _searching = false;
  String? _selectedPlaceId; // To hold the place_id of the selected destination
  String destinationName = "";

  // Map controller to fit the bounds of the routes
  final MapController _mapController = MapController();

  // Function to center map on the currently available routes
  void _fitMapToRoutes(Notifier notifier) {
    List<LatLng> points = [];
    if (notifier.cyclingPolylinePoints.isNotEmpty) {
      points.addAll(notifier.cyclingPolylinePoints);
    }
    if (notifier.drivingPolylinePoints.isNotEmpty) {
      points.addAll(notifier.drivingPolylinePoints);
    }

    if (points.isNotEmpty) {
      // Calculate bounds and fit the map
      final bounds = LatLngBounds.fromPoints(points);
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(50),
          maxZoom: 15,
        ),
      );
    } else if (notifier.userLocation != null) {
      // Fallback: Center on user location if no routes found
      _mapController.move(notifier.userLocation!, 15.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<Notifier>();

    // Determine the map center
    final mapCenter = notifier.userLocation ??
        const LatLng(51.509865, -0.118092); // Default to London

    // Route Polylines
    final drivingRoute = Polyline(
      points: notifier.drivingPolylinePoints,
      strokeWidth: notifier.cycleRoute ? 4.0 : 5.0, // Thicker if selected
      color: Colors.blue.withOpacity(notifier.cycleRoute ? 0.8 : 1.0),
    );
    final cyclingRoute = Polyline(
      points: notifier.cyclingPolylinePoints,
      strokeWidth: !notifier.cycleRoute ? 4.0 : 5.0, // Thicker if selected
      color: Colors.green.withOpacity(!notifier.cycleRoute ? 0.8 : 1.0),
    );

    // List of polylines to display (draw selected route last for priority)
    List<Polyline> allPolylines = [];
    if (notifier.cyclingPolylinePoints.isNotEmpty) {
      allPolylines.add(cyclingRoute);
    }
    if (notifier.drivingPolylinePoints.isNotEmpty) {
      allPolylines.add(drivingRoute);
    }

    // Ensure the currently selected route is drawn on top and highlighted
    final selectedPolyline = notifier.cycleRoute ? cyclingRoute : drivingRoute;
    if (notifier.cyclingPolylinePoints.isNotEmpty ||
        notifier.drivingPolylinePoints.isNotEmpty) {
      // Remove the selected route's dimmed version if it was added
      allPolylines.removeWhere(
          (p) => p.color == selectedPolyline.color && p.strokeWidth != 5.0);
      // Add the highlighted version to the end
      allPolylines.add(selectedPolyline);
    }

    return Scaffold(
      appBar: AppBar(
          title: Text(
              "Bike Nav ${notifier.bluetoothConnected ? "(Connected ✅)" : "(Disconnected ❌)"}")),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => notifier.updateCycleRoutePreference(true),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: notifier.cycleRoute
                              ? Colors.green
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(
                            "Cycle",
                            style: TextStyle(
                              color: notifier.cycleRoute
                                  ? Colors.white
                                  : Colors.black87,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => notifier.updateCycleRoutePreference(false),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: !notifier.cycleRoute
                              ? Colors.blue
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(
                            "Drive",
                            style: TextStyle(
                              color: !notifier.cycleRoute
                                  ? Colors.white
                                  : Colors.black87,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Text(destinationName),
          // --- Map View Section ---
          Expanded(
            child: notifier.isRouteFetching
                ? const Center(child: CircularProgressIndicator())
                : FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: mapCenter,
                      initialZoom: 13.0,
                      onMapReady: () =>
                          _fitMapToRoutes(notifier), // Fit map on load
                    ),
                    children: [
                      // Tile Layer (Map background)
                      TileLayer(
                        urlTemplate:
                            'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.bike-nav',
                        subdomains: const ['a', 'b', 'c'],
                      ),
                      // Polyline Layer for Routes
                      PolylineLayer(
                        polylines: allPolylines,
                      ),
                      // Markers for Start and End points
                      MarkerLayer(
                        markers: [
                          // User Location Marker (if available)
                          if (notifier.userLocation != null)
                            Marker(
                              point: notifier.userLocation!,
                              child: const Icon(Icons.location_pin,
                                  color: Colors.red, size: 20),
                              width: 40,
                              height: 40,
                            ),
                          // Destination Marker (if routes are drawn)
                          if (notifier.drivingPolylinePoints.isNotEmpty ||
                              notifier.cyclingPolylinePoints.isNotEmpty)
                            Marker(
                              point: notifier.drivingPolylinePoints.isNotEmpty
                                  ? notifier.drivingPolylinePoints.last
                                  : notifier.cyclingPolylinePoints.last,
                              child: const Icon(Icons.flag_circle,
                                  color: Colors.red, size: 20),
                              width: 40,
                              height: 40,
                            ),
                        ],
                      ),
                    ],
                  ),
          ),

          // --- Controls Section ---
          Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // 1. Destination Text Field
                TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    hintText: "Enter destination",
                    border: const OutlineInputBorder(),
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : null,
                  ),
                  onChanged: (val) async {
                    if (val.isEmpty) {
                      setState(() {
                        _suggestions = [];
                        notifier.drivingPolylinePoints.clear();
                        notifier.cyclingPolylinePoints.clear();
                      });
                      return;
                    }
                    setState(() => _searching = true);
                    final s = await notifier.placeAutocomplete(val,
                        lat: notifier.userLocation?.latitude,
                        lng: notifier.userLocation?.longitude);
                    setState(() {
                      _suggestions = s;
                      _searching = false;
                    });
                  },
                ),

                const SizedBox(height: 10),

                // 2. Suggestions List
                if (_suggestions.isNotEmpty)
                  Container(
                    height: 100, // Limit height of suggestions list
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _suggestions.length > 3
                          ? 3
                          : _suggestions.length, // Show top 3 suggestions
                      itemBuilder: (_, i) {
                        final s = _suggestions[i];
                        return ListTile(
                          dense: true,
                          title: Text(s['description'],
                              style: const TextStyle(fontSize: 14)),
                          onTap: () async {
                            FocusScope.of(context).unfocus();

                            // Clear input and suggestions
                            //_controller.text = s['description'];
                            setState(() {
                              _suggestions = [];
                              _searching = true;
                              _selectedPlaceId = s['place_id'];
                              destinationName = s['description'];
                            });

                            // Fetch both routes
                            await notifier
                                .fetchDualDirections(s['description']);

                            // Fit map to the new routes
                            if (mounted) {
                              _fitMapToRoutes(notifier);
                              setState(() => _searching = false);
                            }
                          },
                        );
                      },
                    ),
                  ),

                // 3. Mode Switch and Start Button (Visible only after route selection)
                if (notifier.drivingPolylinePoints.isNotEmpty ||
                    notifier.cyclingPolylinePoints.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        // Use the destination name stored during fetch
                        final destination = notifier.destinationName;
                        if (destination.isNotEmpty && context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DirectionsPage(
                                destination: destination,
                                // The DirectionsPage will need to handle fetching the steps for the chosen mode
                              ),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.navigation),
                      label: const Text("START NAVIGATION"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            notifier.cycleRoute ? Colors.green : Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
