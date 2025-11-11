import 'dart:async';
import 'dart:convert';
import 'package:bike_navigation/directions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue/flutter_blue.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class HomePage extends StatefulWidget {
  final BluetoothCharacteristic? givenesp32Characteristic;

  const HomePage({super.key, this.givenesp32Characteristic});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _originController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();

  List<dynamic> _originSuggestions = [];
  List<dynamic> _destinationSuggestions = [];

  double _currentLat = 0.0;
  double _currentLng = 0.0;
  String? _origin;
  String? _destination;

  Timer? _debounce;
  BluetoothCharacteristic? esp32Characteristic;
Timer? _bleTimer;


  late final String _apiKey;

  @override
  void initState() {
    super.initState();
    _apiKey = dotenv.env['GOOGLE_MAPS_API_KEY']!;
    _useCurrentLocationAsOrigin();
    connectToEsp32();
    _bleTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
    if (mounted) {
      _sendBleUpdate("", "", "");
    }
  });

  }

  @override
void dispose() {
    _debounce?.cancel();

  _bleTimer?.cancel();
  super.dispose();
}

  Future<void> _useCurrentLocationAsOrigin() async {
  bool serviceEnabled;
  LocationPermission permission;

  serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Location services are disabled.')),
    );
    return;
  }

  permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      return;
    }
  }

  if (permission == LocationPermission.deniedForever) return;

  final position = await Geolocator.getCurrentPosition();
  setState(() {
    _origin = '${position.latitude},${position.longitude}';
    _currentLat = position.latitude;
    _currentLng = position.longitude;
    _originController.text = "Current Location (${_origin!})";
  });
}


  Future<void> _fetchSuggestions(String input, bool isOrigin) async {
  if (_debounce?.isActive ?? false) _debounce!.cancel();
  _debounce = Timer(const Duration(milliseconds: 500), () async {
    if (input.isEmpty) {
      setState(() {
        if (isOrigin) {
          _originSuggestions = [];
        } else {
          _destinationSuggestions = [];
        }
      });
      return;
    }

    Uri? url;
    if (_currentLat == 0.0 && _currentLng == 0.0) {
      url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/autocomplete/json'
      '?input=$input'
      '&key=$_apiKey',
    );
    } else {
      url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/autocomplete/json'
      '?input=$input'
      '&location=$_currentLat,$_currentLng'
      '&radius=10000' // 10km bias
      '&key=$_apiKey',
    );
    }

    final res = await http.get(url);
    if (!mounted) return;

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      final predictions = data['predictions'] ?? [];
      setState(() {
        if (isOrigin) {
          _originSuggestions = predictions;
        } else {
          _destinationSuggestions = predictions;
        }
      });
    }
  });
}

void connectToEsp32() async {
  if (widget.givenesp32Characteristic != null) {
    esp32Characteristic = widget.givenesp32Characteristic;
    return;
  }
  try {
    print('Scanning for ESP32 devices...');
    var scanResult = await FlutterBlue.instance
        .scan(timeout: const Duration(seconds: 15))
        .firstWhere(
          (scan) => scan.device.name.contains("ESP32"),
          orElse: () {
            print('No ESP32 found during scan');
            throw 'ESP32 not found';
          },
        );

    print('Found device: ${scanResult.device.name} (${scanResult.device.id})');
    
    print('Connecting...');
    await scanResult.device.connect(timeout: const Duration(seconds: 10));
    print('Connected! Discovering services...');
    
    final services = await scanResult.device.discoverServices();
    print('Discovered ${services.length} services');

    bool characteristicFound = false;
    for (var service in services) {
      for (var c in service.characteristics) {
        print('Found characteristic ${c.uuid} with properties: ${c.properties}');
        if (c.properties.write) {
          esp32Characteristic = c;
          characteristicFound = true;
          print('Writable characteristic found: ${c.uuid}');
          _sendBleUpdate("", "", "");
          break;
        }
      }
      if (characteristicFound) break;
    }

    if (!characteristicFound) {
      print('No writable characteristic found!');
    }
  } catch (e) {
    print('ESP32 connection failed: $e');
  } finally {
    FlutterBlue.instance.stopScan();
  }
}

 Future<void> _onStartNavigation() async {
  if (_origin == null || _destination == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Please select both origin and destination')),
    );
    return;
  }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => DirectionsPage(destination: _destination!, esp32Characteristic: esp32Characteristic,),
      ),
    );

}

  void _sendBleUpdate(String icon, String distance, String roadName) {

  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final payload = {
    'timestamp': timestamp,
    'mode': 'home',
    'icon': "",
    'distance': "",
    'road': ""
  };

  final jsonString = jsonEncode(payload);

  // assume you have a connected BLE characteristic named `esp32Characteristic`
  // and it supports write without response
  try {
    esp32Characteristic?.write(utf8.encode(jsonString), withoutResponse: false);
    debugPrint('BLE write sent: $jsonString');
  } catch (e) {
    debugPrint('BLE write failed: $e');
  }
}

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    required bool isOrigin,
  }) {
    final suggestions = isOrigin ? _originSuggestions : _destinationSuggestions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          enabled: isOrigin ? false : true,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) => _fetchSuggestions(value, isOrigin),
        ),
        if (suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(6),
              color: Colors.white,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: suggestions.length,
              itemBuilder: (context, index) {
                final suggestion = suggestions[index];
                return ListTile(
                  title: Text(suggestion['description']),
                  onTap: () {
                    setState(() {
                      controller.text = suggestion['description'];
                      if (isOrigin) {
                        _origin = suggestion['description'];
                        _originSuggestions = [];
                      } else {
                        _destination = suggestion['description'];
                        _destinationSuggestions = [];
                      }
                    });
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isButtonEnabled = _origin != null && _destination != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Navigation Setup')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              _buildTextField(
                label: 'Origin',
                controller: _originController,
                isOrigin: true,
              ),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'Destination',
                controller: _destinationController,
                isOrigin: false,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: isButtonEnabled ? _onStartNavigation : null,
                style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                child: const Text('Start Navigation'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
