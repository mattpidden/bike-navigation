import 'package:flutter/material.dart';

import '../services/ble_service.dart';

(Color, IconData, String) _bleStatusVisuals(BleStatus status) {
  return switch (status) {
    BleStatus.connected => (Colors.green, Icons.bluetooth_connected, 'Display connected'),
    BleStatus.connecting => (Colors.orange, Icons.bluetooth_searching, 'Connecting to display...'),
    BleStatus.scanning => (Colors.orange, Icons.bluetooth_searching, 'Looking for display...'),
    BleStatus.disconnected => (Colors.grey, Icons.bluetooth_disabled, 'Display not connected — tap to retry'),
  };
}

/// Shown in every page's AppBar so connection status is always visible in the
/// same place, instead of only appearing on some screens. Tapping it while
/// not connected nudges the background auto-reconnect loop to try
/// immediately, rather than waiting for its next scheduled attempt.
class BleStatusAction extends StatelessWidget {
  final BleStatus status;
  final VoidCallback onRetry;

  const BleStatusAction({super.key, required this.status, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = _bleStatusVisuals(status);
    return IconButton(
      icon: Icon(icon, color: color),
      tooltip: label,
      onPressed: status == BleStatus.connected ? null : onRetry,
    );
  }
}

/// The circular, elevated presentation of [BleStatusAction] used wherever it
/// floats over map/preview content instead of sitting in a plain AppBar.
class BleStatusBadge extends StatelessWidget {
  final BleStatus status;
  final VoidCallback onRetry;

  const BleStatusBadge({super.key, required this.status, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      shape: const CircleBorder(),
      child: BleStatusAction(status: status, onRetry: onRetry),
    );
  }
}
