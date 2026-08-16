import 'dart:ui';

import 'package:bike_navigation/services/map_transform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MapTransform.worldToScreen', () {
    test('world origin maps to the viewport center when centered on it', () {
      const t = MapTransform(centerX: 0, centerY: 0, metersPerPixel: 1, viewportSize: Size(200, 200));
      final p = t.worldToScreen(0, 0);
      expect(p.dx, closeTo(100, 1e-9));
      expect(p.dy, closeTo(100, 1e-9));
    });

    test('east (+x) moves right on screen, north (+y) moves up on screen', () {
      const t = MapTransform(centerX: 0, centerY: 0, metersPerPixel: 1, viewportSize: Size(200, 200));
      final east = t.worldToScreen(10, 0);
      final north = t.worldToScreen(0, 10);
      expect(east.dx, greaterThan(100)); // right
      expect(east.dy, closeTo(100, 1e-9));
      expect(north.dy, lessThan(100)); // up (screen y grows down)
      expect(north.dx, closeTo(100, 1e-9));
    });

    test('metersPerPixel scales screen distance inversely', () {
      const zoomedIn = MapTransform(centerX: 0, centerY: 0, metersPerPixel: 0.5, viewportSize: Size(200, 200));
      const zoomedOut = MapTransform(centerX: 0, centerY: 0, metersPerPixel: 2, viewportSize: Size(200, 200));
      final pIn = zoomedIn.worldToScreen(10, 0);
      final pOut = zoomedOut.worldToScreen(10, 0);
      // Same world point sits farther from center on screen when more zoomed in.
      expect(pIn.dx - 100, greaterThan(pOut.dx - 100));
    });
  });

  group('MapTransform.screenToWorld', () {
    test('is the exact inverse of worldToScreen (round trip)', () {
      const t = MapTransform(centerX: 123.4, centerY: -56.7, metersPerPixel: 2.5, viewportSize: Size(390, 844));
      const worldPts = [(0.0, 0.0), (100.0, -50.0), (-200.0, 300.0)];
      for (final (wx, wy) in worldPts) {
        final screen = t.worldToScreen(wx, wy);
        final back = t.screenToWorld(screen);
        expect(back.dx, closeTo(wx, 1e-6));
        expect(back.dy, closeTo(wy, 1e-6));
      }
    });

    test('the viewport center screen point maps back to the world center', () {
      const t = MapTransform(centerX: 42, centerY: -7, metersPerPixel: 3, viewportSize: Size(300, 600));
      final world = t.screenToWorld(const Offset(150, 300));
      expect(world.dx, closeTo(42, 1e-9));
      expect(world.dy, closeTo(-7, 1e-9));
    });
  });
}
