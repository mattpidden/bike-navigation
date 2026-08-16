import 'package:flutter/material.dart';

import '../services/ble_service.dart';

class BleStatusBadge extends StatelessWidget {
  final BleStatus status;

  const BleStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (status) {
      BleStatus.connected => (Colors.green, Icons.bluetooth_connected, 'Display connected'),
      BleStatus.connecting => (Colors.orange, Icons.bluetooth_searching, 'Connecting...'),
      BleStatus.scanning => (Colors.orange, Icons.bluetooth_searching, 'Looking for display...'),
      BleStatus.disconnected => (Colors.grey, Icons.bluetooth_disabled, 'Display not connected'),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w500)),
      ],
    );
  }
}
