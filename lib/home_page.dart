import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _originController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();

  List<dynamic> _originSuggestions = [];
  List<dynamic> _destinationSuggestions = [];

  String? _origin;
  String? _destination;

  late final String _apiKey;

  @override
  void initState() {
    super.initState();
    _apiKey = dotenv.env['GOOGLE_MAPS_API_KEY']!;
  }

  Future<void> _fetchSuggestions(String input, bool isOrigin) async {
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
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/autocomplete/json'
      '?input=$input'
      '&key=$_apiKey'
      '&components=country:uk',
    );

    final res = await http.get(url);

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
    } else {
      debugPrint('Error fetching suggestions: ${res.statusCode}');
    }
  }

  void _onStartNavigation() {
    if (_origin == null || _destination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select both origin and destination')),
      );
      return;
    }
    debugPrint('Origin: $_origin');
    debugPrint('Destination: $_destination');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Starting navigation...')),
    );
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
