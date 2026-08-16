import 'dart:typed_data';

import 'package:bike_navigation/services/offline_map_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OfflineMapData.load (real asset)', () {
    // Loads the actual bundled maps/map.bin — this doubles as a check that
    // the pubspec.yaml asset path (declared outside the app/ directory) is
    // valid, not just that the parser logic is correct in isolation.
    test('parses the real map.bin with the expected way/polygon counts', () async {
      final data = await OfflineMapData.load();

      // From the last `python3 build_map.py` run this session:
      // "ways kept: 20559" / "polygons kept: 834".
      expect(data.ways.length, 20559);
      expect(data.polygons.length, 834);

      // Every way/polygon should have at least the minimum valid geometry.
      for (final way in data.ways) {
        expect(way.points.length, greaterThanOrEqualTo(4)); // >= 2 points
        expect(way.points.length % 2, 0);
        expect(way.cls, inInclusiveRange(0, 6));
      }
      for (final poly in data.polygons) {
        expect(poly.triangleVertices.length, greaterThanOrEqualTo(6)); // >= 1 triangle
        expect(poly.triangleVertices.length % 6, 0); // whole triangles
        expect(poly.cls, inInclusiveRange(0, 1));
      }
    });
  });

  group('MapCulling.isVisibleFrom', () {
    final fixturePoints = Float32List.fromList([0, 0, 1, 1]);

    test('visible when the view circle overlaps the shape\'s bounding circle', () {
      final way = MapWay(cls: 0, cx: 100, cy: 0, radius: 10, points: fixturePoints);
      expect(way.isVisibleFrom(0, 0, 91), isTrue);
    });

    test('not visible when the view circle falls well short', () {
      final way = MapWay(cls: 0, cx: 100, cy: 0, radius: 10, points: fixturePoints);
      expect(way.isVisibleFrom(0, 0, 50), isFalse);
    });

    test('boundary: reach exactly equal to distance counts as visible (<=)', () {
      final way = MapWay(cls: 0, cx: 100, cy: 0, radius: 10, points: fixturePoints);
      expect(way.isVisibleFrom(0, 0, 90), isTrue); // dist=100, reach=90+10=100
    });
  });
}
