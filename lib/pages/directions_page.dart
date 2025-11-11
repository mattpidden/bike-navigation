import 'package:bike_navigation/notifiers/notifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

class DirectionsPage extends StatefulWidget {
  final String destination;
  const DirectionsPage({super.key, required this.destination});

  @override
  State<DirectionsPage> createState() => _DirectionsPageState();
}

class _DirectionsPageState extends State<DirectionsPage> {
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = context.read<Notifier>();
    if (!_started) {
      notifier.startNavigation(widget.destination);
      _started = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<Notifier>();

    if (!notifier.navigating && !notifier.recalculating) {
      if (context.mounted) {
        Navigator.pop(context);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
            "Bike Nav ${notifier.bluetoothConnected ? "(Connected ✅)" : "(Disconnected ❌)"}"),
        actions: [
          IconButton(
            icon: const Icon(Icons.stop),
            onPressed: () {
              notifier.stopNavigation();
              Navigator.pop(context);
            },
          )
        ],
      ),
      body: notifier.recalculating
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  flex: 3,
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: notifier.userLocation ??
                          const LatLng(51.4545, -2.5879), // fallback (Bristol)
                      initialZoom: 13,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                        subdomains: const ['a', 'b', 'c'],
                      ),
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: notifier.polylinePoints,
                            color: notifier.cycleRoute
                                ? Colors.green
                                : Colors.blue,
                            strokeWidth: 5,
                          ),
                        ],
                      ),
                      if (notifier.userLocation != null)
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: notifier.userLocation!,
                              child: Icon(Icons.circle,
                                  color: !notifier.cycleRoute
                                      ? Colors.green
                                      : Colors.blue,
                                  size: 15),
                            ),
                            Marker(
                              point: notifier.startPoint,
                              child: const Icon(Icons.location_pin,
                                  color: Colors.red, size: 20),
                            ),
                            Marker(
                              point: notifier.finishPoint,
                              child: const Icon(Icons.flag_circle,
                                  color: Colors.red, size: 20),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Text(
                          notifier.currentInstruction,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          notifier.currentDistance,
                          style:
                              const TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                        const SizedBox(height: 30),
                        if (notifier.remainingDistanceMeters != null)
                          Text(
                            "Remaining: ${(notifier.remainingDistanceMeters! / 1000).toStringAsFixed(2)} km",
                            style: const TextStyle(fontSize: 16),
                          ),
                        const Spacer(),
                        ElevatedButton.icon(
                          onPressed: () => notifier.stopNavigation(),
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text("End Navigation"),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
