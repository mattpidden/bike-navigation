import 'dart:math';
import 'dart:typed_data';

/// Binary BLE protocol shared with the ESP32 firmware (see
/// firmware/src/src.ino's MyCallbacks::onWrite for the device-side mirror of
/// this exact format — keep the two in sync). Little-endian throughout.
///
/// Packet types (first byte of every characteristic write):
///   0x01 TELEMETRY   {x_cm:i32, y_cm:i32, heading_decideg:i16, mode:u8}
///   0x02 ROUTE_START {total_points:u16}
///   0x03 ROUTE_CHUNK {seq:u16, count:u8, (x_cm:i32,y_cm:i32)*count}
///   0x04 ROUTE_END   {}
///   0x05 ROUTE_CLEAR {}
///
/// Positions are centimeters relative to a fixed home-origin local coordinate
/// frame — the same one maps/build_map.py projected the on-device map into.

const String bleServiceUuid = "12345678-1234-1234-1234-1234567890ab";
const String bleCharacteristicUuid = "87654321-4321-4321-4321-ba0987654321";

const int kPacketTelemetry = 0x01;
const int kPacketRouteStart = 0x02;
const int kPacketRouteChunk = 0x03;
const int kPacketRouteEnd = 0x04;
const int kPacketRouteClear = 0x05;

const int modeHome = 0;
const int modeNav = 1;
const int modeArrived = 2;

// Must match maps/build_map.py's ORIGIN_LAT/ORIGIN_LON/EARTH_R exactly — this is
// the same home-origin local coordinate frame the baked on-device map uses.
const double originLat = 51.4793;
const double originLon = -0.1573;
const double earthRadiusM = 6371000.0;

double _degToRad(double deg) => deg * pi / 180.0;

/// Projects a lat/lon into meters relative to [originLat]/[originLon], using
/// the same equirectangular approximation as build_map.py's project(). Route
/// points must go through this before being sent over BLE, or they won't line
/// up with the roads/water/parks already baked into the device's map.
({double x, double y}) projectLatLon(double lat, double lon) {
  final x = earthRadiusM * _degToRad(lon - originLon) * cos(_degToRad(originLat));
  final y = earthRadiusM * _degToRad(lat - originLat);
  return (x: x, y: y);
}

Uint8List buildTelemetry({
  required double xMeters,
  required double yMeters,
  required double headingDeg,
  required int mode,
}) {
  final data = ByteData(12);
  data.setUint8(0, kPacketTelemetry);
  data.setInt32(1, (xMeters * 100).round(), Endian.little);
  data.setInt32(5, (yMeters * 100).round(), Endian.little);
  data.setInt16(9, (headingDeg * 10).round(), Endian.little);
  data.setUint8(11, mode);
  return data.buffer.asUint8List();
}

Uint8List buildRouteStart(int totalPoints) {
  final data = ByteData(3);
  data.setUint8(0, kPacketRouteStart);
  data.setUint16(1, totalPoints, Endian.little);
  return data.buffer.asUint8List();
}

Uint8List buildRouteChunk(int seq, List<({double x, double y})> points) {
  final data = ByteData(4 + points.length * 8);
  data.setUint8(0, kPacketRouteChunk);
  data.setUint16(1, seq, Endian.little);
  data.setUint8(3, points.length);
  for (var i = 0; i < points.length; i++) {
    final offset = 4 + i * 8;
    data.setInt32(offset, (points[i].x * 100).round(), Endian.little);
    data.setInt32(offset + 4, (points[i].y * 100).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

Uint8List buildRouteEnd() => Uint8List.fromList([kPacketRouteEnd]);

Uint8List buildRouteClear() => Uint8List.fromList([kPacketRouteClear]);
