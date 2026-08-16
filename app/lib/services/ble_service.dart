import 'dart:async';
import 'dart:math';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_protocol.dart';

enum BleStatus { disconnected, scanning, connecting, connected }

/// Owns the ESP32 BLE connection end to end — scanning, connecting, staying
/// connected, and sending protocol packets. A single instance of this lives
/// in [Notifier] and is shared by every screen, so (unlike the old app) the
/// connection genuinely persists across navigation instead of each page
/// reconnecting from scratch.
class BleService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSub;
  Timer? _supervisorTimer;
  bool _busy = false; // guards against overlapping scan/connect attempts

  final _statusController = StreamController<BleStatus>.broadcast();
  BleStatus _status = BleStatus.disconnected;

  Stream<BleStatus> get statusStream => _statusController.stream;
  BleStatus get status => _status;
  bool get isConnected => _status == BleStatus.connected;
  int get mtu => _device?.mtuNow ?? 23;

  void _setStatus(BleStatus s) {
    _status = s;
    _statusController.add(s);
  }

  /// Starts the scan/connect/reconnect supervisor loop. Safe to call
  /// repeatedly — subsequent calls just reset the timer.
  void start() {
    _supervisorTimer?.cancel();
    _supervisorTimer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
    _tick();
  }

  /// Stops the supervisor loop and disconnects, if connected.
  Future<void> stop() async {
    _supervisorTimer?.cancel();
    _supervisorTimer = null;
    final device = _device;
    _teardown();
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {
        // already gone — fine
      }
    }
    _setStatus(BleStatus.disconnected);
  }

  Future<void> _tick() async {
    if (_busy || _status == BleStatus.connected) return;
    _busy = true;
    try {
      await _scanAndConnect();
    } finally {
      _busy = false;
    }
  }

  Future<void> _scanAndConnect() async {
    _setStatus(BleStatus.scanning);
    BluetoothDevice? found;
    final completer = Completer<void>();
    final sub = FlutterBluePlus.scanResults.listen((results) {
      if (results.isNotEmpty && !completer.isCompleted) {
        found = results.first.device;
        completer.complete();
      }
    });

    try {
      // Filter on our service UUID, not device name — far more reliable across
      // platforms (a device's advertised name often only lands in a separate
      // scan-response packet that doesn't merge consistently everywhere, the
      // service UUID rides in the primary advertisement packet and matches
      // every time).
      await FlutterBluePlus.startScan(
        withServices: [Guid(bleServiceUuid)],
        timeout: const Duration(seconds: 8),
      );
      await completer.future.timeout(const Duration(seconds: 8), onTimeout: () {});
    } catch (_) {
      // scan failed to start — fall through and retry on the next tick
    } finally {
      await sub.cancel();
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    }

    if (found == null) {
      _setStatus(BleStatus.disconnected);
      return;
    }
    await _connect(found!);
  }

  Future<void> _connect(BluetoothDevice device) async {
    _setStatus(BleStatus.connecting);
    try {
      await device.connect(timeout: const Duration(seconds: 10), mtu: 512);

      _connectionStateSub?.cancel();
      _connectionStateSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _teardown();
          _setStatus(BleStatus.disconnected);
        }
      });

      final services = await device.discoverServices();
      BluetoothCharacteristic? characteristic;
      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.uuid == Guid(bleCharacteristicUuid)) {
            characteristic = c;
            break;
          }
        }
      }

      if (characteristic == null) {
        await device.disconnect();
        _teardown();
        _setStatus(BleStatus.disconnected);
        return;
      }

      _device = device;
      _characteristic = characteristic;
      _setStatus(BleStatus.connected);
    } catch (_) {
      try {
        await device.disconnect();
      } catch (_) {
        // already gone
      }
      _teardown();
      _setStatus(BleStatus.disconnected);
    }
  }

  void _teardown() {
    _connectionStateSub?.cancel();
    _connectionStateSub = null;
    _device = null;
    _characteristic = null;
  }

  Future<void> _write(List<int> bytes, {required bool withoutResponse}) async {
    final c = _characteristic;
    if (c == null) return;
    try {
      await c.write(bytes, withoutResponse: withoutResponse);
    } catch (_) {
      // a write failing here almost always means the link just dropped —
      // the connectionState listener above will notice and tear down/retry.
    }
  }

  Future<void> sendTelemetry({
    required double xMeters,
    required double yMeters,
    required double headingDeg,
    required int mode,
  }) {
    return _write(
      buildTelemetry(xMeters: xMeters, yMeters: yMeters, headingDeg: headingDeg, mode: mode),
      withoutResponse: true,
    );
  }

  /// Sends a full route as ROUTE_START, N ROUTE_CHUNKs sized to the connection's
  /// actual negotiated MTU, then ROUTE_END. Chunks are written with response
  /// (sequential, awaited) since this is a one-off transfer where reliability
  /// matters more than raw speed.
  Future<void> sendRoute(List<({double x, double y})> points) async {
    if (!isConnected || points.isEmpty) return;
    // Each point is 8 bytes; leave 3 bytes of ATT overhead and 4 bytes for our
    // own chunk header (type+seq+count) out of the negotiated MTU.
    final chunkPoints = (((mtu - 3) - 4) / 8).floor().clamp(1, 255);

    await _write(buildRouteStart(points.length), withoutResponse: false);
    var seq = 0;
    for (var i = 0; i < points.length; i += chunkPoints) {
      final chunk = points.sublist(i, min(i + chunkPoints, points.length));
      await _write(buildRouteChunk(seq, chunk), withoutResponse: false);
      seq++;
    }
    await _write(buildRouteEnd(), withoutResponse: false);
  }

  Future<void> clearRoute() => _write(buildRouteClear(), withoutResponse: false);

  void dispose() {
    unawaited(stop());
    _statusController.close();
  }
}
