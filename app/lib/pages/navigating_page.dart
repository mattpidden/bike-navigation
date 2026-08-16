import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../notifiers/notifier.dart';
import '../services/ble_protocol.dart';
import '../services/offline_map_data.dart';
import '../widgets/ble_status_badge.dart';
import '../widgets/device_preview_map.dart';
import '../widgets/offline_map_view.dart' show MapRoute;
import 'arrived_page.dart';

const double _deviceSize = 220;
const double _bezelWidth = 10;

/// Status screen during active navigation. Centers on a small circular
/// preview — styled like the wearable's own round display (black bezel,
/// circular crop, heading-up rotation, same look-ahead focus point) of the
/// same live position + route the ESP32 is rendering, so it's clear the
/// phone itself isn't what to look at anymore.
class NavigatingPage extends StatefulWidget {
  const NavigatingPage({super.key});

  @override
  State<NavigatingPage> createState() => _NavigatingPageState();
}

class _NavigatingPageState extends State<NavigatingPage> {
  bool _navigatedToArrived = false;
  late final Future<OfflineMapData> _mapDataFuture;

  @override
  void initState() {
    super.initState();
    _mapDataFuture = OfflineMapData.load();
  }

  void _cancel() {
    context.read<Notifier>().stopNavigation();
    Navigator.popUntil(context, (route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<Notifier>();

    if (notifier.navMode == NavMode.arrived && !_navigatedToArrived) {
      _navigatedToArrived = true;
      final destination = notifier.destinationName;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => ArrivedPage(destination: destination)),
        );
      });
    }

    final remaining = notifier.distanceRemainingM;

    return Scaffold(
      appBar: AppBar(
        title: Text(notifier.destinationName, overflow: TextOverflow.ellipsis),
        actions: [
          BleStatusBadge(status: notifier.bleStatus, onRetry: notifier.retryBleConnection),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              const SizedBox(height: 8),
              _buildDevicePreview(notifier),
              const SizedBox(height: 32),
              Text(
                remaining == null ? 'Navigating...' : '${(remaining / 1000).toStringAsFixed(1)} km remaining',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Your bike display is now showing this map. You can lock your phone and put it away.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const Spacer(),
              OutlinedButton(onPressed: _cancel, child: const Text('Cancel Navigation')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDevicePreview(Notifier notifier) {
    final user = notifier.userLocation;
    final local = user == null ? null : projectLatLon(user.latitude, user.longitude);
    final route = notifier.activeRoute;

    return Container(
      width: _deviceSize,
      height: _deviceSize,
      padding: const EdgeInsets.all(_bezelWidth),
      decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black),
      child: ClipOval(
        child: FutureBuilder<OfflineMapData>(
          future: _mapDataFuture,
          builder: (context, snapshot) {
            if (!snapshot.hasData || local == null) return const ColoredBox(color: Colors.black);
            return DevicePreviewMap(
              data: snapshot.data!,
              posX: local.x,
              posY: local.y,
              headingDeg: notifier.heading,
              hasHeading: notifier.hasHeading,
              routes: [
                if (route != null)
                  MapRoute(points: route.polylinePoints.map((p) => projectLatLon(p.latitude, p.longitude)).toList()),
              ],
            );
          },
        ),
      ),
    );
  }
}
