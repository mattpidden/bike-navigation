import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/map_transform.dart';
import '../services/offline_map_data.dart';

// Style constants transcribed from firmware/src/MapRenderer.h / maps/visualiser.py.
// Three independent renderers (C++, Python, this) — no shared config file
// across languages, so keep these in sync by eye when the style changes.
const Color _colorBg = Color(0xFF212121);
const Color _colorGreen = Color(0xFF6DA544);
const Color _colorBlue = Color(0xFF338AF3);
const Color _roadMajor = Color(0xFFEEEEEE);
const Color _roadMedium = Color(0xFFE0E0E0);
const Color _roadMinor = Color(0xFFDBDBDB);
const Color _markerRed = Color(0xFFD80027);

class _RoadStyle {
  final Color color;
  final double widthM;
  const _RoadStyle(this.color, this.widthM);
}

// class 0..6 -> motorway/trunk, primary, secondary/tertiary, residential, cycleway, path/track, water
const List<_RoadStyle> _roadStyles = [
  _RoadStyle(_roadMajor, 10.0),
  _RoadStyle(_roadMajor, 7.0),
  _RoadStyle(_roadMedium, 7.0),
  _RoadStyle(_roadMinor, 3.5),
  _RoadStyle(_roadMinor, 3.5),
  _RoadStyle(_roadMinor, 3.5),
  _RoadStyle(_colorBlue, 8.5),
];

// polygon class 0..1 -> green, water
const List<Color> _polyFillColors = [_colorGreen, _colorBlue];

const double _minMetersPerPixel = 0.05;
const double _maxMetersPerPixel = 200.0;

// Route line style — mirrors firmware/src/MapRenderer.h's COLOR_ROUTE_BORDER
// (white) / COLOR_ROUTE_CENTER (#ff9811) so a selected route on this browsing
// map looks consistent with what the wearable draws during actual navigation.
const Color _routeOrange = Color(0xFFFF9811);
const double _routeBorderWidthM = 12.0;
const double _routeCenterWidthM = 8.0;

/// A point to draw on the map, in the same world-meters frame as the map
/// data (see lib/services/ble_protocol.dart's projectLatLon).
class MapMarker {
  final double x;
  final double y;
  final Color color;
  final double radiusPx;

  const MapMarker({required this.x, required this.y, this.color = _markerRed, this.radiusPx = 8});
}

/// A route line to draw on the map, in the same world-meters frame as the
/// map data. [selected] draws it solid with a white border (matching the
/// wearable's in-navigation style); unselected draws it translucent with no
/// border, for comparing route options before starting.
class MapRoute {
  final List<({double x, double y})> points;
  final bool selected;

  const MapRoute({required this.points, this.selected = true});
}

/// Owns the current pan/zoom state (world-meters center + zoom level) so it
/// can be read by callers that need to place overlays in the same
/// transform, and offers a couple of programmatic setters (e.g. recentering
/// on a GPS fix) alongside the gesture-driven updates the widget applies.
class MapViewController extends ChangeNotifier {
  double centerX;
  double centerY;
  double metersPerPixel;

  MapViewController({this.centerX = 0, this.centerY = 0, this.metersPerPixel = 1.0});

  void setView({required double centerX, required double centerY, double? metersPerPixel}) {
    this.centerX = centerX;
    this.centerY = centerY;
    if (metersPerPixel != null) this.metersPerPixel = metersPerPixel.clamp(_minMetersPerPixel, _maxMetersPerPixel);
    notifyListeners();
  }
}

class OfflineMapView extends StatefulWidget {
  final OfflineMapData data;
  final MapViewController controller;
  final List<MapMarker> markers;
  final List<MapRoute> routes;

  const OfflineMapView({
    super.key,
    required this.data,
    required this.controller,
    this.markers = const [],
    this.routes = const [],
  });

  @override
  State<OfflineMapView> createState() => _OfflineMapViewState();
}

class _OfflineMapViewState extends State<OfflineMapView> {
  // Captured at gesture start so pinch-zoom keeps the point under your
  // fingers fixed on screen instead of the view center.
  late double _gestureStartMetersPerPixel;
  late Offset _gestureStartFocalWorld;
  Size _viewportSize = Size.zero;

  void _onScaleStart(ScaleStartDetails details) {
    final c = widget.controller;
    _gestureStartMetersPerPixel = c.metersPerPixel;
    final transform = MapTransform(
      centerX: c.centerX,
      centerY: c.centerY,
      metersPerPixel: c.metersPerPixel,
      viewportSize: _viewportSize,
    );
    _gestureStartFocalWorld = transform.screenToWorld(details.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final c = widget.controller;
    final viewportCenter = Offset(_viewportSize.width / 2, _viewportSize.height / 2);
    final newMpp =
        (_gestureStartMetersPerPixel / details.scale).clamp(_minMetersPerPixel, _maxMetersPerPixel);

    // Solve for the new center such that the world point under the focal
    // point at gesture-start stays under the (possibly moved) focal point now.
    final focalScreen = details.localFocalPoint;
    final newCenterX = _gestureStartFocalWorld.dx - (focalScreen.dx - viewportCenter.dx) * newMpp;
    final newCenterY = _gestureStartFocalWorld.dy + (focalScreen.dy - viewportCenter.dy) * newMpp;

    c.setView(centerX: newCenterX, centerY: newCenterY, metersPerPixel: newMpp);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) {
                return CustomPaint(
                  size: _viewportSize,
                  painter: _OfflineMapPainter(
                    data: widget.data,
                    centerX: widget.controller.centerX,
                    centerY: widget.controller.centerY,
                    metersPerPixel: widget.controller.metersPerPixel,
                    markers: widget.markers,
                    routes: widget.routes,
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _OfflineMapPainter extends CustomPainter {
  final OfflineMapData data;
  final double centerX;
  final double centerY;
  final double metersPerPixel;
  final List<MapMarker> markers;
  final List<MapRoute> routes;

  _OfflineMapPainter({
    required this.data,
    required this.centerX,
    required this.centerY,
    required this.metersPerPixel,
    required this.markers,
    required this.routes,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _colorBg);

    final viewportCx = size.width / 2;
    final viewportCy = size.height / 2;
    final pxPerM = 1 / metersPerPixel;
    // Meters visible from center to the farthest screen corner — the same
    // "view radius" concept the C++/Python renderers cull against.
    final viewRadiusM = (size.longestSide / 2) * metersPerPixel;

    // Same formula as MapTransform.worldToScreen, inlined as raw doubles
    // rather than going through Offset/the class — this runs per-vertex over
    // up to ~57,600 points every frame, so avoiding an Offset allocation per
    // point matters here specifically. MapTransform stays the canonical,
    // tested reference for this math; keep the two in sync if it changes.
    double sx(double wx) => viewportCx + (wx - centerX) * pxPerM;
    double sy(double wy) => viewportCy - (wy - centerY) * pxPerM;

    _drawPolygons(canvas, viewRadiusM, sx, sy);
    _drawWays(canvas, viewRadiusM, sx, sy, pxPerM);
    _drawRoutes(canvas, sx, sy, pxPerM);
    _drawMarkers(canvas, sx, sy);
  }

  void _drawPolygons(Canvas canvas, double viewRadiusM, double Function(double) sx, double Function(double) sy) {
    // Batched per class (2 classes) into one drawVertices call each, per the
    // validated rendering approach — flat triangle fill, no per-triangle Path.
    for (var cls = 0; cls < _polyFillColors.length; cls++) {
      final screenVerts = <double>[];
      for (final poly in data.polygons) {
        if (poly.cls != cls) continue;
        if (!poly.isVisibleFrom(centerX, centerY, viewRadiusM)) continue;
        final v = poly.triangleVertices;
        for (var i = 0; i < v.length; i += 2) {
          screenVerts.add(sx(v[i]));
          screenVerts.add(sy(v[i + 1]));
        }
      }
      if (screenVerts.isEmpty) continue;
      final vertices = ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList(screenVerts));
      canvas.drawVertices(
        vertices,
        BlendMode.srcOver,
        Paint()
          ..color = _polyFillColors[cls]
          ..isAntiAlias = false,
      );
    }
  }

  void _drawWays(
    Canvas canvas,
    double viewRadiusM,
    double Function(double) sx,
    double Function(double) sy,
    double pxPerM,
  ) {
    // Batched per class (7 classes) into one combined Path each, per the
    // validated rendering approach — cuts ~20,500 draw calls down to ~7.
    for (var cls = 0; cls < _roadStyles.length; cls++) {
      final style = _roadStyles[cls];
      final path = Path();
      var any = false;
      for (final way in data.ways) {
        if (way.cls != cls) continue;
        if (!way.isVisibleFrom(centerX, centerY, viewRadiusM)) continue;
        final p = way.points;
        if (p.length < 4) continue;
        any = true;
        path.moveTo(sx(p[0]), sy(p[1]));
        for (var i = 2; i < p.length; i += 2) {
          path.lineTo(sx(p[i]), sy(p[i + 1]));
        }
      }
      if (!any) continue;
      final widthPx = (style.widthM * pxPerM).clamp(1.0, double.infinity);
      canvas.drawPath(
        path,
        Paint()
          ..color = style.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = widthPx
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  void _drawRoutes(Canvas canvas, double Function(double) sx, double Function(double) sy, double pxPerM) {
    for (final route in routes) {
      if (route.points.length < 2) continue;
      final path = Path()..moveTo(sx(route.points[0].x), sy(route.points[0].y));
      for (var i = 1; i < route.points.length; i++) {
        path.lineTo(sx(route.points[i].x), sy(route.points[i].y));
      }
      if (route.selected) {
        canvas.drawPath(
          path,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = (_routeBorderWidthM * pxPerM).clamp(1.0, double.infinity)
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = route.selected ? _routeOrange : _routeOrange.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (_routeCenterWidthM * pxPerM).clamp(1.0, double.infinity)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  void _drawMarkers(Canvas canvas, double Function(double) sx, double Function(double) sy) {
    for (final m in markers) {
      canvas.drawCircle(Offset(sx(m.x), sy(m.y)), m.radiusPx, Paint()..color = m.color);
    }
  }

  @override
  bool shouldRepaint(covariant _OfflineMapPainter oldDelegate) {
    return oldDelegate.centerX != centerX ||
        oldDelegate.centerY != centerY ||
        oldDelegate.metersPerPixel != metersPerPixel ||
        oldDelegate.data != data ||
        oldDelegate.markers != markers ||
        oldDelegate.routes != routes;
  }
}
