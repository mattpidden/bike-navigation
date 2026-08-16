import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../notifiers/notifier.dart';
import 'navigating_page.dart';

/// Route summary + start button. Deliberately no live map here — once
/// navigation starts, the wearable display is the map; this screen just
/// confirms distance/mode before committing.
class RoutePreviewPage extends StatefulWidget {
  final String destination;

  const RoutePreviewPage({super.key, required this.destination});

  @override
  State<RoutePreviewPage> createState() => _RoutePreviewPageState();
}

class _RoutePreviewPageState extends State<RoutePreviewPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  Future<void> _fetch() async {
    final ok = await context.read<Notifier>().fetchPreviewRoute(widget.destination);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not find a route to that destination.')),
    );
  }

  Future<void> _start() async {
    final notifier = context.read<Notifier>();
    await notifier.startNavigation();
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const NavigatingPage()));
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<Notifier>();
    final route = notifier.previewRoute;
    final fetching = notifier.isFetchingRoute;

    return Scaffold(
      appBar: AppBar(title: Text(widget.destination, overflow: TextOverflow.ellipsis)),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: fetching
            ? const Center(child: CircularProgressIndicator())
            : route == null
                ? const Center(child: Text('No route found.'))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${(route.totalDistanceMeters / 1000).toStringAsFixed(1)} km',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      Text('${route.steps.length} steps', style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 24),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Cycling directions'),
                        value: notifier.cycleRoute,
                        onChanged: (value) {
                          notifier.setCycleRoute(value);
                          _fetch();
                        },
                      ),
                      const Spacer(),
                      ElevatedButton(
                        onPressed: _start,
                        style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                        child: const Text('Start Navigation'),
                      ),
                    ],
                  ),
      ),
    );
  }
}
