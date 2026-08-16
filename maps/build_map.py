#!/usr/bin/env python3
"""Extract, simplify, and pack OSM road/water/green-space data into a compact
binary blob for the ESP32 map renderer. No SD card / no shapely / no
geopandas — just GDAL's ogr2ogr (already on the system) to pull filtered
GeoJSON, then stdlib for everything else (projection, simplification,
ear-clipping triangulation, packing).
"""
import json
import math
import struct
import subprocess
from pathlib import Path

MAPS_DIR = Path(__file__).parent
PBF = MAPS_DIR / "planet_-0.191_51.459_2ad4d3d6.osm.pbf"
ROADS_GEOJSON = MAPS_DIR / "roads_raw.geojson"
AREAS_GEOJSON = MAPS_DIR / "areas_raw.geojson"
# OSM has no usable Thames polygon in this extract (see build_map.py history /
# conversation — its water-body relation extends past the bbox and won't
# reassemble). This is a small pre-filtered slice of OS OpenMap Local's
# TQ_TidalWater shapefile instead: a real, non-relation, non-clipped polygon
# straight from Ordnance Survey open data.
THAMES_TIDAL_GEOJSON = MAPS_DIR / "thames_tidal_os.geojson"
OUT_BIN = MAPS_DIR / "map.bin"

# Origin — everything is stored as meters relative to this point. Battersea
# Park, chosen as a public landmark rather than a residential address.
ORIGIN_LAT = 51.4793
ORIGIN_LON = -0.1573

EARTH_R = 6371000.0

# Road classes we care about for a bike map, collapsed into a styling byte.
ROAD_CLASS_MAP = {
    "motorway": 0, "motorway_link": 0, "trunk": 0, "trunk_link": 0,
    "primary": 1, "primary_link": 1,
    "secondary": 2, "secondary_link": 2, "tertiary": 2, "tertiary_link": 2,
    "residential": 3, "unclassified": 3, "living_street": 3,
    "cycleway": 4,
    "path": 5, "track": 5, "bridleway": 5, "pedestrian": 5,
}
# Rivers/canals only — kept as simple centerlines (not the true water polygon)
# for the same reason roads are centerlines: cheap to store, cheap to draw.
# No reliable width data exists in this extract (no `width` tag on any waterway
# here, and the Thames's actual bank polygon doesn't reconstruct cleanly from a
# bbox-clipped extract), so all water — Thames included — shares one style
# rather than faking a width for the Thames that isn't grounded in real data.
WATER = 6

# Filled area classes (separate byte space from the line classes above — these
# live in their own section of the file). landuse=grass / leisure=garden are
# deliberately excluded: 1130 / 1231 features respectively in this extract,
# almost all tiny garden plots and verges — clutter, not context.
POLY_GREEN = 0
POLY_WATER = 1

DP_EPSILON_M = 2.0       # line simplification tolerance, meters
POLY_EPSILON_M = 3.0     # area boundary simplification tolerance, meters


def run_ogr2ogr(out_path, layer, where, fields):
    if out_path.exists():
        print(f"Reusing existing {out_path.name}")
        return
    subprocess.run(
        [
            "ogr2ogr", "-f", "GeoJSON", str(out_path), str(PBF), layer,
            "-where", where, "-select", ",".join(fields),
        ],
        check=True,
    )


def extract_roads():
    highways = "','".join(ROAD_CLASS_MAP.keys())
    waterways = "','".join(["river", "canal"])
    where = f"highway IN ('{highways}') OR waterway IN ('{waterways}')"
    run_ogr2ogr(ROADS_GEOJSON, "lines", where, ["osm_id", "name", "highway", "waterway"])


def extract_areas():
    where = (
        "leisure='park' OR natural IN ('wood','water') "
        "OR landuse IN ('forest','recreation_ground')"
    )
    run_ogr2ogr(AREAS_GEOJSON, "multipolygons", where, ["osm_id", "name", "leisure", "landuse", "natural"])


def project(lat, lon):
    x = EARTH_R * math.radians(lon - ORIGIN_LON) * math.cos(math.radians(ORIGIN_LAT))
    y = EARTH_R * math.radians(lat - ORIGIN_LAT)
    return x, y


def douglas_peucker(points, epsilon):
    if len(points) < 3:
        return points
    (x1, y1), (x2, y2) = points[0], points[-1]
    dx, dy = x2 - x1, y2 - y1
    seg_len2 = dx * dx + dy * dy

    def perp_dist(p):
        x0, y0 = p
        if seg_len2 == 0:
            return math.hypot(x0 - x1, y0 - y1)
        t = ((x0 - x1) * dx + (y0 - y1) * dy) / seg_len2
        t = max(0.0, min(1.0, t))
        px, py = x1 + t * dx, y1 + t * dy
        return math.hypot(x0 - px, y0 - py)

    max_dist, idx = 0.0, 0
    for i in range(1, len(points) - 1):
        d = perp_dist(points[i])
        if d > max_dist:
            max_dist, idx = d, i

    if max_dist > epsilon:
        left = douglas_peucker(points[: idx + 1], epsilon)
        right = douglas_peucker(points[idx:], epsilon)
        return left[:-1] + right
    return [points[0], points[-1]]


def polygon_signed_area2(poly):
    s = 0.0
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    return s


def _cross(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _point_in_triangle(p, a, b, c):
    d1 = _cross(a, b, p)
    d2 = _cross(b, c, p)
    d3 = _cross(c, a, p)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_neg and has_pos)


def ear_clip(poly):
    """Triangulate a simple polygon (no holes) via ear clipping. Offline-only —
    the device just draws whatever triangles come out of this, so correctness
    here matters more than speed."""
    pts = list(poly)
    if len(pts) >= 2 and pts[0] == pts[-1]:
        pts.pop()  # drop closing duplicate vertex if present
    if len(pts) < 3:
        return []
    if polygon_signed_area2(pts) < 0:
        pts.reverse()  # ear-clipping below assumes CCW winding

    idx = list(range(len(pts)))
    triangles = []
    guard = 0
    guard_max = len(idx) * len(idx) + 16
    while len(idx) > 3 and guard < guard_max:
        guard += 1
        n = len(idx)
        found = False
        for i in range(n):
            ip, ic, inx = idx[(i - 1) % n], idx[i], idx[(i + 1) % n]
            a, b, c = pts[ip], pts[ic], pts[inx]
            if _cross(a, b, c) <= 0:
                continue  # reflex vertex — can't be an ear
            if any(_point_in_triangle(pts[j], a, b, c) for j in idx if j not in (ip, ic, inx)):
                continue
            triangles.append((a, b, c))
            idx.pop(i)
            found = True
            break
        if not found:
            break  # degenerate/self-intersecting ring — stop, keep what we have
    if len(idx) == 3:
        triangles.append((pts[idx[0]], pts[idx[1]], pts[idx[2]]))
    return triangles


def classify_area(props):
    if props.get("leisure") == "park":
        return POLY_GREEN
    if props.get("landuse") in ("forest", "recreation_ground"):
        return POLY_GREEN
    if props.get("natural") == "wood":
        return POLY_GREEN
    if props.get("natural") == "water":
        return POLY_WATER
    return None


def load_polygons():
    data = json.loads(AREAS_GEOJSON.read_text())
    rings = []
    for feat in data["features"]:
        cls = classify_area(feat["properties"])
        if cls is None:
            continue
        geom = feat["geometry"]
        polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
        for poly in polys:
            if not poly:
                continue
            exterior = poly[0]  # holes (poly[1:]) intentionally ignored — see module docstring
            rings.append((POLY_WATER if cls == POLY_WATER else cls, [pt[:2] for pt in exterior]))

    # Thames — from OS OpenMap Local, not OSM (see THAMES_TIDAL_GEOJSON comment above)
    tidal = json.loads(THAMES_TIDAL_GEOJSON.read_text())
    for feat in tidal["features"]:
        geom = feat["geometry"]
        polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
        for poly in polys:
            if not poly:
                continue
            exterior = poly[0]
            rings.append((POLY_WATER, [pt[:2] for pt in exterior]))  # drop shapefile's Z coordinate

    return rings


def build_polygons():
    rings = load_polygons()
    polys = []
    raw_pt_count = 0
    tri_count_total = 0
    for cls, ring in rings:
        raw_pt_count += len(ring)
        pts = [project(lat, lon) for lon, lat in ring]
        simplified = douglas_peucker(pts, POLY_EPSILON_M)
        if len(simplified) < 3:
            continue
        triangles = ear_clip(simplified)
        if not triangles:
            continue
        tri_count_total += len(triangles)
        all_pts = [p for tri in triangles for p in tri]
        cx = sum(p[0] for p in all_pts) / len(all_pts)
        cy = sum(p[1] for p in all_pts) / len(all_pts)
        radius = max(math.hypot(x - cx, y - cy) for x, y in all_pts)
        polys.append((cls, cx, cy, radius, triangles))

    print(f"area features:      {len(rings)}")
    print(f"area raw points:    {raw_pt_count}")
    print(f"triangles:          {tri_count_total}")
    return polys


def build_ways():
    data = json.loads(ROADS_GEOJSON.read_text())
    ways = []
    raw_pt_count = 0
    for feat in data["features"]:
        if feat["geometry"]["type"] != "LineString":
            continue
        highway = feat["properties"].get("highway")
        waterway = feat["properties"].get("waterway")
        name = feat["properties"].get("name") or ""
        if highway in ROAD_CLASS_MAP:
            cls = ROAD_CLASS_MAP[highway]
        elif waterway in ("river", "canal"):
            if "thames" in name.lower():
                continue  # now drawn as a real polygon instead — see THAMES_TIDAL_GEOJSON
            cls = WATER
        else:
            continue
        coords = feat["geometry"]["coordinates"]  # [lon, lat]
        raw_pt_count += len(coords)
        pts = [project(lat, lon) for lon, lat in coords]
        simplified = douglas_peucker(pts, DP_EPSILON_M)
        if len(simplified) < 2:
            continue
        ways.append((cls, simplified))

    # The device draws ways in storage order with no z-buffer, so order here *is*
    # the draw order: water at the very bottom (roads/bridges always on top of it),
    # then roads smallest-to-largest so major roads always win at intersections
    # rather than whichever road happened to come later out of the GeoJSON.
    def draw_priority(cls):
        if cls == WATER:
            return -1
        return 5 - cls  # cls 5 (path/track) -> 0 (bottom); cls 0 (motorway) -> 5 (top)

    ways.sort(key=lambda w: draw_priority(w[0]))

    simp_pt_count = sum(len(w[1]) for w in ways)
    print(f"ways kept:          {len(ways)}")
    print(f"way raw points:     {raw_pt_count}")
    print(f"way simplified pts: {simp_pt_count} ({100*simp_pt_count/raw_pt_count:.1f}% of raw)")
    return ways


def pack_point(buf, x, y, clip_counter):
    xi = max(-32767, min(32767, round(x)))
    yi = max(-32767, min(32767, round(y)))
    if xi != round(x) or yi != round(y):
        clip_counter[0] += 1
    buf += struct.pack("<hh", xi, yi)


def main():
    extract_roads()
    extract_areas()

    polys = build_polygons()
    ways = build_ways()

    clipped = [0]
    buf = bytearray()

    # Section 1: filled areas (drawn first == bottom layer)
    #   [poly_count:u32] then per polygon:
    #   [class:u8][cx:i16][cy:i16][radius:u16][triangle count:u16][triangles: 3x(i16 x,i16 y)]*
    buf += struct.pack("<I", len(polys))
    for cls, cx, cy, radius, triangles in polys:
        cxi = max(-32767, min(32767, round(cx)))
        cyi = max(-32767, min(32767, round(cy)))
        ri = max(0, min(65535, round(radius)))
        buf += struct.pack("<BhhHH", cls, cxi, cyi, ri, len(triangles))
        for tri in triangles:
            for x, y in tri:
                pack_point(buf, x, y, clipped)

    # Section 2: line ways (drawn second == on top of areas)
    #   [way_count:u32] then per way:
    #   [class:u8][cx:i16][cy:i16][radius:u16][point count:u16][pts: i16 x, i16 y]*
    buf += struct.pack("<I", len(ways))
    for cls, pts in ways:
        cx = sum(p[0] for p in pts) / len(pts)
        cy = sum(p[1] for p in pts) / len(pts)
        radius = max(math.hypot(x - cx, y - cy) for x, y in pts)
        cxi = max(-32767, min(32767, round(cx)))
        cyi = max(-32767, min(32767, round(cy)))
        ri = max(0, min(65535, round(radius)))
        buf += struct.pack("<BhhHH", cls, cxi, cyi, ri, len(pts))
        for x, y in pts:
            pack_point(buf, x, y, clipped)

    OUT_BIN.write_bytes(buf)

    print(f"polygons kept:      {len(polys)}")
    print(f"clipped points:     {clipped[0]} (outside int16 meter range — increase origin precision if >0)")
    print(f"output size:        {len(buf):,} bytes ({len(buf)/1024:.1f} KB)")


if __name__ == "__main__":
    main()
