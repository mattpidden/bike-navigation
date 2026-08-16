import 'package:bike_navigation/notifiers/notifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';
// TEMPORARY: swapped to the map-rendering-engine verification screen while
// that's being checked on a real device (see pages/map_debug_page.dart).
// Revert to home_page.dart once the new map_page.dart flow replaces it.
import 'pages/map_debug_page.dart';

void main() async {
  await dotenv.load(fileName: "assets/.env");
  runApp(
    ChangeNotifierProvider(
      create: (_) => Notifier(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bike Navigation',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MapDebugPage(),
    );
  }
}
