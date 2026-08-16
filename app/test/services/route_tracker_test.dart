import 'package:bike_navigation/services/route_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RouteTracker basic projection', () {
    test('a fix exactly on the route matches with ~0 perpendicular distance', () {
      final tracker = RouteTracker([(x: 0, y: 0), (x: 100, y: 0), (x: 100, y: 100)]);
      final p = tracker.update(50, 0);
      expect(p.distanceAlongRouteM, closeTo(50, 0.01));
      expect(p.perpendicularDistanceM, closeTo(0, 0.01));
      expect(p.remainingDistanceM, closeTo(150, 0.01));
    });

    test('a fix off to the side projects onto the nearest segment', () {
      final tracker = RouteTracker([(x: 0, y: 0), (x: 100, y: 0)]);
      final p = tracker.update(50, 10); // 10m off the route, abeam the midpoint
      expect(p.distanceAlongRouteM, closeTo(50, 0.01));
      expect(p.perpendicularDistanceM, closeTo(10, 0.01));
    });

    test('total distance is the sum of segment lengths', () {
      final tracker = RouteTracker([(x: 0, y: 0), (x: 3, y: 4), (x: 3, y: 14)]);
      expect(tracker.totalDistanceM, closeTo(15, 0.01)); // 5 + 10
    });
  });

  group('RouteTracker hysteresis', () {
    test('does not snap backward to an earlier segment the route passes near again', () {
      // A route that goes out and loops back close to its own start (like a
      // road looping under itself) — this is exactly the junction/overlap
      // case the old nearest-step-start matching used to jitter on.
      final tracker = RouteTracker([
        (x: 0, y: 0),
        (x: 100, y: 0),
        (x: 100, y: 100),
        (x: 0, y: 100),
        (x: 0, y: 5), // back near the start, geometrically close to segment 0
      ]);

      final p1 = tracker.update(100, 50); // clearly progressed onto segment 1-2
      expect(p1.distanceAlongRouteM, greaterThan(100));

      // Now a noisy fix that's geometrically very close to the START of the
      // route (segment 0) — without hysteresis this would wrongly snap
      // progress back to ~0.
      final p2 = tracker.update(1, 1);
      expect(p2.distanceAlongRouteM, greaterThanOrEqualTo(p1.distanceAlongRouteM - 15.0));
    });

    test('a genuinely large jump backward (way off route) is still picked up via fallback', () {
      final tracker = RouteTracker([(x: 0, y: 0), (x: 1000, y: 0)]);
      tracker.update(900, 0); // progressed far along
      // Simulate the rider actually starting over / GPS glitch far from the
      // last position with nothing satisfying hysteresis nearby.
      final p = tracker.update(10, 0);
      expect(p.distanceAlongRouteM, closeTo(10, 0.01));
    });
  });

  group('RouteTracker off-route detection', () {
    test('a single noisy sample does not trigger off-route', () {
      final tracker = RouteTracker([(x: 0, y: 0), (x: 100, y: 0)]);
      final p = tracker.update(10, 40); // 40m off, one sample
      expect(p.offRoute, isFalse);
    });

    test('several consecutive off-route samples do trigger it', () {
      final tracker = RouteTracker([(x: 0, y: 0), (x: 100, y: 0)]);
      RouteProgress? last;
      for (var i = 0; i < 5; i++) {
        last = tracker.update(10.0 + i, 40); // consistently ~40m off
      }
      expect(last!.offRoute, isTrue);
    });

    test('returning close to the route resets the off-route streak', () {
      final tracker = RouteTracker([(x: 0, y: 0), (x: 100, y: 0)]);
      for (var i = 0; i < 3; i++) {
        tracker.update(10.0, 40); // building up an off-route streak
      }
      final backOnRoute = tracker.update(20, 0);
      expect(backOnRoute.offRoute, isFalse);
    });
  });

  group('RouteTracker step index', () {
    test('derives the current step from cumulative step-boundary distances', () {
      final tracker = RouteTracker(
        [(x: 0, y: 0), (x: 50, y: 0), (x: 100, y: 0), (x: 150, y: 0)],
        stepBoundariesM: [50, 100, 150],
      );
      expect(tracker.update(10, 0).currentStepIndex, 0);
      expect(tracker.update(60, 0).currentStepIndex, 1);
      expect(tracker.update(140, 0).currentStepIndex, 2);
    });
  });

  group('RouteTracker arrival', () {
    test('flags arrived once within the arrival threshold of the route end', () {
      final tracker = RouteTracker([(x: 0, y: 0), (x: 100, y: 0)]);
      expect(tracker.update(80, 0).arrived, isFalse);
      expect(tracker.update(95, 0).arrived, isTrue);
    });
  });
}
