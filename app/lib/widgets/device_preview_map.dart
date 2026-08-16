import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/offline_map_data.dart';
import 'offline_map_view.dart';

/// A faithful Dart port of firmware/src/MapRenderer.h's drawMap() — used
/// only for the circular "what the wearable is showing right now" preview
/// during navigation. Unlike [OfflineMapView] (freely pannable, north-up,
/// no heading marker — the browsing map), this is fixed heading-up with the
/// same 1/3-up-from-bottom focus point and the same triangle/dot "you are
/// here" marker logic as the real device, so it actually looks like the
/// hardware screen rather than just another map view.
class DevicePreviewMap extends StatelessWidget {
  final OfflineMapData data;
  final double posX;
  final double posY;
  final double headingDeg;
  final bool hasHeading;
  final double viewRadiusM;
  final List<MapRoute> routes;

  const DevicePreviewMap({
    super.key,
    required this.data,
    required this.posX,
    required this.posY,
    required this.headingDeg,
    required this.hasHeading,
    this.viewRadiusM = 150.0,
    this.routes = const [],
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DevicePreviewPainter(
        data: data,
        posX: posX,
        posY: posY,
        headingDeg: headingDeg,
        hasHeading: hasHeading,
        viewRadiusM: viewRadiusM,
        routes: routes,
      ),
    );
  }
}

class _DevicePreviewPainter extends CustomPainter {
  final OfflineMapData data;
  final double posX;
  final double posY;
  final double headingDeg;
  final bool hasHeading;
  final double viewRadiusM;
  final List<MapRoute> routes;

  _DevicePreviewPainter({
    required this.data,
    required this.posX,
    required this.posY,
    required this.headingDeg,
    required this.hasHeading,
    required this.viewRadiusM,
    required this.routes,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colorBg);

    final pxPerM = (size.width / 2) / viewRadiusM;
    // "you are here" sits 1/3 up from the bottom edge rather than dead
    // center — mirrors MAP_FOCUS_X/Y in MapRenderer.h, so more of the view
    // ahead is visible than what's behind.
    final focusX = size.width / 2;
    final focusY = size.height * (2 / 3);

    // Bearings (0=north, clockwise) map to world vectors as (sin, cos), not
    // (cos, sin) — see MapRenderer.h's identical comment. +heading is the
    // correct rotation to align "the way you're facing" with "screen up".
    final theta = headingDeg * pi / 180.0;
    final cosT = cos(theta);
    final sinT = sin(theta);

    double sx(double wx, double wy) {
      final lx = wx - posX, ly = wy - posY;
      final rx = lx * cosT - ly * sinT;
      return focusX + rx * pxPerM;
    }

    double sy(double wx, double wy) {
      final lx = wx - posX, ly = wy - posY;
      final ry = lx * sinT + ly * cosT;
      return focusY - ry * pxPerM;
    }

    _drawPolygons(canvas, sx, sy);
    _drawWays(canvas, sx, sy, pxPerM);
    _drawRoutes(canvas, sx, sy, pxPerM);
    _drawYouAreHere(canvas, focusX, focusY);
  }

  void _drawPolygons(Canvas canvas, double Function(double, double) sx, double Function(double, double) sy) {
    for (var cls = 0; cls < polyFillColors.length; cls++) {
      final screenVerts = <double>[];
      for (final poly in data.polygons) {
        if (poly.cls != cls) continue;
        if (!poly.isVisibleFrom(posX, posY, viewRadiusM)) continue;
        final v = poly.triangleVertices;
        for (var i = 0; i < v.length; i += 2) {
          screenVerts.add(sx(v[i], v[i + 1]));
          screenVerts.add(sy(v[i], v[i + 1]));
        }
      }
      if (screenVerts.isEmpty) continue;
      final vertices = ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList(screenVerts));
      canvas.drawVertices(
        vertices,
        BlendMode.srcOver,
        Paint()
          ..color = polyFillColors[cls]
          ..isAntiAlias = false,
      );
    }
  }

  void _drawWays(
    Canvas canvas,
    double Function(double, double) sx,
    double Function(double, double) sy,
    double pxPerM,
  ) {
    for (var cls = 0; cls < roadStyles.length; cls++) {
      final style = roadStyles[cls];
      final path = Path();
      var any = false;
      for (final way in data.ways) {
        if (way.cls != cls) continue;
        if (!way.isVisibleFrom(posX, posY, viewRadiusM)) continue;
        final p = way.points;
        if (p.length < 4) continue;
        any = true;
        path.moveTo(sx(p[0], p[1]), sy(p[0], p[1]));
        for (var i = 2; i < p.length; i += 2) {
          path.lineTo(sx(p[i], p[i + 1]), sy(p[i], p[i + 1]));
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

  void _drawRoutes(
    Canvas canvas,
    double Function(double, double) sx,
    double Function(double, double) sy,
    double pxPerM,
  ) {
    for (final route in routes) {
      if (route.points.length < 2) continue;
      final path = Path()..moveTo(sx(route.points[0].x, route.points[0].y), sy(route.points[0].x, route.points[0].y));
      for (var i = 1; i < route.points.length; i++) {
        path.lineTo(sx(route.points[i].x, route.points[i].y), sy(route.points[i].x, route.points[i].y));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = (routeBorderWidthM * pxPerM).clamp(1.0, double.infinity)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = routeOrange
          ..style = PaintingStyle.stroke
          ..strokeWidth = (routeCenterWidthM * pxPerM).clamp(1.0, double.infinity)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  // Fixed at the focus point, always pointing screen-up (never rotated by
  // heading — that's the entire point of heading-up mode). A triangle once
  // we have a direction to show it in; before that, just a dot — mirrors
  // MapRenderer.h's hasHeading branch exactly.
  void _drawYouAreHere(Canvas canvas, double focusX, double focusY) {
    if (hasHeading) {
      final path = Path()
        ..moveTo(focusX, focusY - 16)
        ..lineTo(focusX - 10, focusY + 12)
        ..lineTo(focusX + 10, focusY + 12)
        ..close();
      canvas.drawPath(path, Paint()..color = markerRed);
    } else {
      canvas.drawCircle(Offset(focusX, focusY), 10, Paint()..color = markerRed);
    }
  }

  @override
  bool shouldRepaint(covariant _DevicePreviewPainter oldDelegate) {
    return oldDelegate.posX != posX ||
        oldDelegate.posY != posY ||
        oldDelegate.headingDeg != headingDeg ||
        oldDelegate.hasHeading != hasHeading ||
        oldDelegate.viewRadiusM != viewRadiusM ||
        oldDelegate.data != data ||
        oldDelegate.routes != routes;
  }
}
