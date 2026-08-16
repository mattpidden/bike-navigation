import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../notifiers/notifier.dart';
import '../widgets/ble_status_badge.dart';
import 'route_preview_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _destinationController = TextEditingController();
  List<dynamic> _suggestions = [];
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _destinationController.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      final results = await context.read<Notifier>().searchPlaces(value);
      if (!mounted) return;
      setState(() => _suggestions = results);
    });
  }

  void _selectSuggestion(dynamic suggestion) {
    final description = suggestion['description'] as String;
    setState(() {
      _destinationController.text = description;
      _suggestions = [];
    });
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RoutePreviewPage(destination: description)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bleStatus = context.watch<Notifier>().bleStatus;
    return Scaffold(
      appBar: AppBar(title: const Text('Bike Navigation')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BleStatusBadge(status: bleStatus),
            const SizedBox(height: 24),
            TextField(
              controller: _destinationController,
              decoration: const InputDecoration(
                labelText: 'Where to?',
                border: OutlineInputBorder(),
              ),
              onChanged: _onChanged,
            ),
            if (_suggestions.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _suggestions.length,
                  itemBuilder: (context, index) {
                    final suggestion = _suggestions[index];
                    return ListTile(
                      title: Text(suggestion['description']),
                      onTap: () => _selectSuggestion(suggestion),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
