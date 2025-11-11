import 'dart:async';
import 'dart:convert';

import 'package:bike_navigation/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue/flutter_blue.dart';

class ArrivedPage extends StatefulWidget {
  final String destination;
  final BluetoothCharacteristic? esp32Characteristic;

  const ArrivedPage({super.key, required this.destination, required this.esp32Characteristic});

  @override
  State<ArrivedPage> createState() => _ArrivedPageState();
}

class _ArrivedPageState extends State<ArrivedPage> {
Timer? _bleTimer;


   @override
  void initState() {
    super.initState();
    _bleTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
    if (mounted) {
      _sendBleUpdate("", "", "");
    }
  });

  }

  @override
void dispose() {
  _bleTimer?.cancel();
  super.dispose();
}

    void _sendBleUpdate(String icon, String distance, String roadName) {

  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final payload = {
    'timestamp': timestamp,
    'mode': 'arrived',
    'icon': "",
    'distance': "",
    'road': ""
  };

  final jsonString = jsonEncode(payload);

  // assume you have a connected BLE characteristic named `esp32Characteristic`
  // and it supports write without response
  try {
    widget.esp32Characteristic?.write(utf8.encode(jsonString), withoutResponse: false);
    debugPrint('BLE write sent: $jsonString');
  } catch (e) {
    debugPrint('BLE write failed: $e');
  }
}



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Arrived')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.flag, size: 100, color: Colors.orange),
              const SizedBox(height: 24),
              Text(
                'You’ve arrived at your destination!',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                widget.destination,
                style: const TextStyle(
                  fontSize: 18,
                  color: Colors.black54,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {
                  Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => HomePage()));
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Done',
                  style: TextStyle(fontSize: 18, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
