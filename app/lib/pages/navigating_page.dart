import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../notifiers/notifier.dart';
import '../widgets/ble_status_badge.dart';
import 'arrived_page.dart';

/// Minimal status screen during active navigation. Deliberately no live map
/// or turn list here — that's the wearable's job now. This just shows BLE
/// connection health, distance remaining, and a way to cancel.
class NavigatingPage extends StatefulWidget {
  const NavigatingPage({super.key});

  @override
  State<NavigatingPage> createState() => _NavigatingPageState();
}

class _NavigatingPageState extends State<NavigatingPage> {
  bool _navigatedToArrived = false;

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
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            BleStatusBadge(status: notifier.bleStatus),
            const SizedBox(height: 24),
            Icon(Icons.directions_bike, size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              remaining == null ? 'Navigating...' : '${(remaining / 1000).toStringAsFixed(1)} km remaining',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text('Follow the map on your bike display', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 48),
            OutlinedButton(onPressed: _cancel, child: const Text('Cancel Navigation')),
          ],
        ),
      ),
    );
  }
}
