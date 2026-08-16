import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// Dart port of maps/map_format.py's parser — reads the exact same binary
/// format already rendered identically in Python (maps/visualiser.py) and
/// C++ (firmware/src/MapRenderer.h). Keep the three in sync; this is the
/// third independent renderer of maps/map.bin, not a fourth data format.
///
/// Format (little-endian):
///   Section 1 — filled areas:
///     u32 polygon_count
///     per polygon: u8 class, i16 cx, i16 cy, u16 radius, u16 triangle_count,
///                  then triangle_count * 3 * (i16 x, i16 y)
///   Section 2 — line ways:
///     u32 way_count
///     per way: u8 class, i16 cx, i16 cy, u16 radius, u16 point_count,
///              then point_count * (i16 x, i16 y)
/// Coordinates are meters relative to the fixed home-origin local frame
/// (see maps/build_map.py's ORIGIN_LAT/ORIGIN_LON) — the same frame
/// lib/services/ble_protocol.dart's projectLatLon() produces.

/// Shared circle-vs-circle visibility test — kept as one implementation so
/// all three renderers stay behaviorally identical, not reimplemented per
/// painter/screen.
mixin MapCulling {
  double get cx;
  double get cy;
  double get radius;

  bool isVisibleFrom(double viewX, double viewY, double viewRadiusM) {
    final dx = cx - viewX;
    final dy = cy - viewY;
    final reach = viewRadiusM + radius;
    return dx * dx + dy * dy <= reach * reach;
  }
}

/// class 0..6 -> motorway/trunk, primary, secondary/tertiary, residential,
/// cycleway, path/track, water — matches ROAD_STYLES in MapRenderer.h.
class MapWay with MapCulling {
  final int cls;
  @override
  final double cx;
  @override
  final double cy;
  @override
  final double radius;

  /// Flat world-space meters, one polyline: x0,y0,x1,y1,...
  final Float32List points;

  const MapWay({
    required this.cls,
    required this.cx,
    required this.cy,
    required this.radius,
    required this.points,
  });
}

/// class 0..1 -> green (parks/woods/rec grounds), water (lakes/ponds/Thames)
/// — matches POLY_FILL_COLORS in MapRenderer.h.
class MapPolygon with MapCulling {
  final int cls;
  @override
  final double cx;
  @override
  final double cy;
  @override
  final double radius;

  /// Flat world-space meters, pre-triangulated offline (ear-clipping) — 3
  /// vertices per triangle: x0,y0,x1,y1,x2,y2,... Ready for Canvas.drawVertices
  /// once transformed to screen space.
  final Float32List triangleVertices;

  const MapPolygon({
    required this.cls,
    required this.cx,
    required this.cy,
    required this.radius,
    required this.triangleVertices,
  });
}

class OfflineMapData {
  final List<MapPolygon> polygons;
  final List<MapWay> ways;

  const OfflineMapData({required this.polygons, required this.ways});

  static Future<OfflineMapData> load({String assetPath = '../maps/map.bin'}) async {
    final data = await rootBundle.load(assetPath);
    return parse(data);
  }

  static OfflineMapData parse(ByteData data) {
    var offset = 0;

    final polyCount = data.getUint32(offset, Endian.little);
    offset += 4;
    final polygons = List<MapPolygon>.generate(polyCount, (_) {
      final cls = data.getUint8(offset);
      final cx = data.getInt16(offset + 1, Endian.little).toDouble();
      final cy = data.getInt16(offset + 3, Endian.little).toDouble();
      final radius = data.getUint16(offset + 5, Endian.little).toDouble();
      final triCount = data.getUint16(offset + 7, Endian.little);
      offset += 9;

      final vertCount = triCount * 3;
      final verts = Float32List(vertCount * 2);
      for (var v = 0; v < vertCount; v++) {
        verts[v * 2] = data.getInt16(offset, Endian.little).toDouble();
        verts[v * 2 + 1] = data.getInt16(offset + 2, Endian.little).toDouble();
        offset += 4;
      }
      return MapPolygon(cls: cls, cx: cx, cy: cy, radius: radius, triangleVertices: verts);
    });

    final wayCount = data.getUint32(offset, Endian.little);
    offset += 4;
    final ways = List<MapWay>.generate(wayCount, (_) {
      final cls = data.getUint8(offset);
      final cx = data.getInt16(offset + 1, Endian.little).toDouble();
      final cy = data.getInt16(offset + 3, Endian.little).toDouble();
      final radius = data.getUint16(offset + 5, Endian.little).toDouble();
      final pointCount = data.getUint16(offset + 7, Endian.little);
      offset += 9;

      final points = Float32List(pointCount * 2);
      for (var p = 0; p < pointCount; p++) {
        points[p * 2] = data.getInt16(offset, Endian.little).toDouble();
        points[p * 2 + 1] = data.getInt16(offset + 2, Endian.little).toDouble();
        offset += 4;
      }
      return MapWay(cls: cls, cx: cx, cy: cy, radius: radius, points: points);
    });

    assert(offset == data.lengthInBytes, 'trailing bytes: read $offset, file is ${data.lengthInBytes}');
    return OfflineMapData(polygons: polygons, ways: ways);
  }
}
