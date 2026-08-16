import 'package:bike_navigation/services/directions_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('decodePolyline', () {
    test('decodes Google\'s own reference example correctly', () {
      // The canonical example from Google's polyline algorithm documentation.
      final points = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      expect(points.length, 3);
      expect(points[0].latitude, closeTo(38.5, 1e-5));
      expect(points[0].longitude, closeTo(-120.2, 1e-5));
      expect(points[1].latitude, closeTo(40.7, 1e-5));
      expect(points[1].longitude, closeTo(-120.95, 1e-5));
      expect(points[2].latitude, closeTo(43.252, 1e-5));
      expect(points[2].longitude, closeTo(-126.453, 1e-5));
    });

    test('handles an empty string', () {
      expect(decodePolyline(''), isEmpty);
    });
  });

  group('cleanInstruction', () {
    test('strips HTML tags and adds a trailing period', () {
      expect(cleanInstruction('Turn <b>left</b> onto Main St'), 'Turn left onto Main St.');
    });

    test('does not double up an existing trailing period', () {
      expect(cleanInstruction('Continue straight.'), 'Continue straight.');
    });

    test('turns a div boundary into a separator', () {
      expect(
        cleanInstruction('Turn left<div style="font-size:0.9em">Destination will be on the right</div>'),
        'Turn left. Destination will be on the right.',
      );
    });
  });

  group('DirectionsRoute.stepBoundariesMeters', () {
    test('computes cumulative distance at the end of each step', () {
      const origin = LatLng(0, 0);
      const route = DirectionsRoute(
        steps: [
          DirectionsStep(
            startLocation: origin,
            endLocation: origin,
            polylinePoints: [],
            distanceMeters: 100,
            instruction: '',
          ),
          DirectionsStep(
            startLocation: origin,
            endLocation: origin,
            polylinePoints: [],
            distanceMeters: 50,
            instruction: '',
          ),
        ],
        polylinePoints: [],
        totalDistanceMeters: 150,
      );
      expect(route.stepBoundariesMeters, [100.0, 150.0]);
    });
  });
}
