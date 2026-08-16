import 'package:flutter/material.dart';

import '../services/offline_map_data.dart';
import '../widgets/offline_map_view.dart';

/// Throwaway verification screen for the new Flutter map-rendering engine —
/// not part of the real app flow. Temporarily wired as the app's root in
/// main.dart so it can be checked on a real device before the real
/// search/pin/directions UI is built on top of it (map_page.dart, later).
/// Delete this file (and revert main.dart) once that's done.
class MapDebugPage extends StatefulWidget {
  const MapDebugPage({super.key});

  @override
  State<MapDebugPage> createState() => _MapDebugPageState();
}

class _MapDebugPageState extends State<MapDebugPage> {
  late final Future<OfflineMapData> _future;
  final _controller = MapViewController(centerX: 0, centerY: 0, metersPerPixel: 1.5);

  @override
  void initState() {
    super.initState();
    _future = OfflineMapData.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<OfflineMapData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load map: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!;
          return Stack(
            children: [
              OfflineMapView(
                data: data,
                controller: _controller,
                // Red circle at the home origin (0,0) — a known reference point
                // already checked visually many times in maps/visualiser.py
                // (Thames to the north, parks nearby), so it's easy to eyeball
                // whether this renders the same map correctly.
                markers: const [MapMarker(x: 0, y: 0)],
              ),
              Positioned(
                top: 48,
                left: 16,
                right: 16,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    return Text(
                      '${data.ways.length} ways, ${data.polygons.length} polygons\n'
                      'center=(${_controller.centerX.toStringAsFixed(0)}, ${_controller.centerY.toStringAsFixed(0)})m  '
                      'zoom=${_controller.metersPerPixel.toStringAsFixed(2)} m/px\n'
                      'Pan/pinch-zoom to explore. Red dot = home.',
                      style: const TextStyle(color: Colors.white, fontSize: 12, backgroundColor: Colors.black54),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
