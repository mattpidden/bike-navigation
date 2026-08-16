import 'dart:ui' show Offset, Size;

/// World meters <-> screen pixels for a north-up, freely pannable/zoomable
/// map view. World +x = east, +y = north (matches lib/services/ble_protocol.dart's
/// projectLatLon); screen y grows downward, hence the sign flip on y.
class MapTransform {
  final double centerX;
  final double centerY;
  final double metersPerPixel;
  final Size viewportSize;

  const MapTransform({
    required this.centerX,
    required this.centerY,
    required this.metersPerPixel,
    required this.viewportSize,
  });

  Offset get _viewportCenter => Offset(viewportSize.width / 2, viewportSize.height / 2);

  Offset worldToScreen(double worldX, double worldY) {
    final vc = _viewportCenter;
    return Offset(
      vc.dx + (worldX - centerX) / metersPerPixel,
      vc.dy - (worldY - centerY) / metersPerPixel,
    );
  }

  Offset screenToWorld(Offset screenPt) {
    final vc = _viewportCenter;
    return Offset(
      centerX + (screenPt.dx - vc.dx) * metersPerPixel,
      centerY - (screenPt.dy - vc.dy) * metersPerPixel,
    );
  }
}
