import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../notifiers/notifier.dart';
import '../widgets/ble_status_badge.dart';

class ArrivedPage extends StatelessWidget {
  final String destination;

  const ArrivedPage({super.key, required this.destination});

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<Notifier>();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        actions: [BleStatusAction(status: notifier.bleStatus, onRetry: notifier.retryBleConnection)],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.flag, size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text("You've arrived", style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(destination, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () {
                notifier.acknowledgeArrival();
                Navigator.popUntil(context, (route) => route.isFirst);
              },
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
