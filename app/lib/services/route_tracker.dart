import 'dart:math';

/// Tracks progress of a live GPS fix along a route polyline.
///
/// Replaces the old approach (matching to the nearest step's *start point*,
/// which jumps unpredictably near junctions and overlapping roads) with a
/// proper projection: for each fix, project onto every segment of the route,
/// pick the closest, and track distance travelled as true arc-length along
/// the polyline rather than a step index.
///
/// Works entirely in local meters (the same projected space `projectLatLon`
/// produces and the BLE protocol sends) rather than lat/lon — at route scale
/// (a few km) the flat-plane approximation error is far smaller than GPS
/// accuracy on a bike, and it avoids the numerically fragile spherical
/// cross-track formula the old code used.
class RouteProgress {
  final double distanceAlongRouteM;
  final double perpendicularDistanceM;
  final double remainingDistanceM;
  final double distanceToNextStepM;
  final int currentStepIndex;
  final bool offRoute;
  final bool arrived;

  const RouteProgress({
    required this.distanceAlongRouteM,
    required this.perpendicularDistanceM,
    required this.remainingDistanceM,
    required this.distanceToNextStepM,
    required this.currentStepIndex,
    required this.offRoute,
    required this.arrived,
  });
}

({double t, double distToSegment, double alongTrackM}) _projectOntoSegment(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax, dy = by - ay;
  final segLenSq = dx * dx + dy * dy;
  double t = segLenSq == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / segLenSq;
  t = t.clamp(0.0, 1.0);
  final projX = ax + t * dx, projY = ay + t * dy;
  final distToSegment = sqrt((px - projX) * (px - projX) + (py - projY) * (py - projY));
  final segLen = sqrt(segLenSq);
  return (t: t, distToSegment: distToSegment, alongTrackM: t * segLen);
}

List<double> _cumulativeDistances(List<({double x, double y})> points) {
  final cum = <double>[0.0];
  for (var i = 1; i < points.length; i++) {
    final dx = points[i].x - points[i - 1].x;
    final dy = points[i].y - points[i - 1].y;
    cum.add(cum.last + sqrt(dx * dx + dy * dy));
  }
  return cum;
}

class RouteTracker {
  static const double _backtrackToleranceM = 15.0;
  static const double _offRouteThresholdM = 25.0;
  static const int _offRouteStreakToTrigger = 4;
  static const double _arrivalThresholdM = 15.0;

  final List<({double x, double y})> _points;
  final List<double> _cumulativeM;
  final List<double> _stepBoundariesM;
  final double totalDistanceM;

  double _lastArcLengthM = 0;
  int _offRouteStreak = 0;

  /// [points]: the route polyline in local meters (already projected).
  /// [stepBoundariesM]: cumulative distance-along-route at the end of each
  /// Directions API step, used to derive a step index without re-matching by
  /// step geometry.
  RouteTracker(List<({double x, double y})> points, {List<double> stepBoundariesM = const []})
      : assert(points.length >= 2, 'RouteTracker needs at least 2 points'),
        _points = points,
        _stepBoundariesM = stepBoundariesM,
        _cumulativeM = _cumulativeDistances(points),
        totalDistanceM = _cumulativeDistances(points).last;

  RouteProgress update(double x, double y) {
    var bestDist = double.infinity;
    var bestArc = _lastArcLengthM;
    var found = false;

    // Primary pass: honor hysteresis — don't accept a match that would jump
    // the arc-length backward past tolerance (prevents jitter at junctions
    // and overlapping roads snapping progress back and forth).
    for (var i = 0; i < _points.length - 1; i++) {
      final a = _points[i], b = _points[i + 1];
      final r = _projectOntoSegment(x, y, a.x, a.y, b.x, b.y);
      final arc = _cumulativeM[i] + r.alongTrackM;
      if (arc < _lastArcLengthM - _backtrackToleranceM) continue;
      if (r.distToSegment < bestDist) {
        bestDist = r.distToSegment;
        bestArc = arc;
        found = true;
      }
    }

    // Fallback: nothing satisfied the no-backtrack constraint (e.g. well off
    // route) — match against the whole route regardless of direction.
    if (!found) {
      for (var i = 0; i < _points.length - 1; i++) {
        final a = _points[i], b = _points[i + 1];
        final r = _projectOntoSegment(x, y, a.x, a.y, b.x, b.y);
        final arc = _cumulativeM[i] + r.alongTrackM;
        if (r.distToSegment < bestDist) {
          bestDist = r.distToSegment;
          bestArc = arc;
        }
      }
    }

    _lastArcLengthM = bestArc;
    _offRouteStreak = bestDist > _offRouteThresholdM ? _offRouteStreak + 1 : 0;

    var stepIndex = 0;
    for (final boundary in _stepBoundariesM) {
      if (bestArc >= boundary) stepIndex++;
    }
    if (_stepBoundariesM.isNotEmpty) {
      stepIndex = stepIndex.clamp(0, _stepBoundariesM.length - 1);
    }
    final nextBoundary = stepIndex < _stepBoundariesM.length ? _stepBoundariesM[stepIndex] : totalDistanceM;

    final remaining = (totalDistanceM - bestArc).clamp(0.0, totalDistanceM);

    return RouteProgress(
      distanceAlongRouteM: bestArc,
      perpendicularDistanceM: bestDist,
      remainingDistanceM: remaining,
      distanceToNextStepM: (nextBoundary - bestArc).clamp(0.0, totalDistanceM),
      currentStepIndex: stepIndex,
      offRoute: _offRouteStreak >= _offRouteStreakToTrigger,
      arrived: remaining < _arrivalThresholdM,
    );
  }
}
