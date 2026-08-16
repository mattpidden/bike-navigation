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
  final _focusNode = FocusNode();
  List<dynamic> _suggestions = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // Coming back to this page (e.g. from the route preview) leaves the typed
    // text in place but the dropdown was cleared when we navigated away — tapping
    // back into the field with text already there should show suggestions again
    // immediately, not require a fresh keystroke first.
    _focusNode.addListener(() {
      if (_focusNode.hasFocus && _destinationController.text.isNotEmpty && _suggestions.isEmpty) {
        _fetchSuggestions(_destinationController.text);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _destinationController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _fetchSuggestions(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      final results = await context.read<Notifier>().searchPlaces(value);
      if (!mounted) return;
      setState(() => _suggestions = results);
    });
  }

  void _onChanged(String value) {
    setState(() {}); // updates the clear button's visibility immediately
    if (value.isEmpty) {
      _debounce?.cancel();
      setState(() => _suggestions = []);
      return;
    }
    _fetchSuggestions(value);
  }

  void _clearDestination() {
    _debounce?.cancel();
    setState(() {
      _destinationController.clear();
      _suggestions = [];
    });
  }

  void _goToDestination(String description) {
    _focusNode.unfocus();
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
    final notifier = context.watch<Notifier>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bike Navigation'),
        actions: [BleStatusAction(status: notifier.bleStatus, onRetry: notifier.retryBleConnection)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _destinationController,
              focusNode: _focusNode,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: 'Where to?',
                border: const OutlineInputBorder(),
                suffixIcon: _destinationController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: _clearDestination,
                      ),
              ),
              onChanged: _onChanged,
              // Typing a full address and hitting search/enter shouldn't require
              // picking a dropdown suggestion first — go straight there.
              onSubmitted: (value) {
                if (value.isNotEmpty) _goToDestination(value);
              },
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
                      onTap: () => _goToDestination(suggestion['description'] as String),
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
