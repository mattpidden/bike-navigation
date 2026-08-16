"""Parser for map.bin — mirrors exactly what the ESP32 firmware will read,
so this doubles as a spec for the on-device binary format.

Format (little-endian), two sections, in the order the device draws them:

    Section 1 — filled areas (bottom layer):
        u32                     polygon_count
        per polygon:
            u8                  class   (0=green, 1=water — see POLY_CLASS_NAMES)
            i16, i16            centroid x, y (meters, relative to origin)
            u16                 radius  (meters, max dist from centroid to any vertex)
            u16                 triangle_count
            triangle_count * 3 * (i16 x, i16 y)   pre-triangulated (ear-clipped offline)

    Section 2 — line ways (drawn on top of areas):
        u32                     way_count
        per way:
            u8                  class   (see CLASS_NAMES below)
            i16, i16            centroid x, y (meters, relative to origin)
            u16                 radius  (meters, max dist from centroid to any point)
            u16                 point_count
            point_count * (i16 x, i16 y)   absolute coords, meters relative to origin
"""
import struct
from dataclasses import dataclass
from pathlib import Path

CLASS_NAMES = {
    0: "motorway/trunk",
    1: "primary",
    2: "secondary/tertiary",
    3: "residential",
    4: "cycleway",
    5: "path/track",
    6: "water",
}

POLY_CLASS_NAMES = {
    0: "green",
    1: "water",
}


@dataclass
class Way:
    cls: int
    cx: int
    cy: int
    radius: int
    points: list  # list[(x, y)] in meters relative to origin


@dataclass
class Polygon:
    cls: int
    cx: int
    cy: int
    radius: int
    triangles: list  # list[((x,y),(x,y),(x,y))] in meters relative to origin


@dataclass
class MapData:
    polygons: list  # list[Polygon]
    ways: list      # list[Way]


def load(path: Path) -> MapData:
    data = Path(path).read_bytes()
    offset = 0

    (poly_count,) = struct.unpack_from("<I", data, offset)
    offset += 4
    polygons = []
    for _ in range(poly_count):
        cls, cx, cy, radius, tri_count = struct.unpack_from("<BhhHH", data, offset)
        offset += 9
        vals = struct.unpack_from(f"<{tri_count * 6}h", data, offset)
        offset += tri_count * 12
        triangles = []
        for t in range(tri_count):
            v = vals[t * 6:(t + 1) * 6]
            triangles.append(((v[0], v[1]), (v[2], v[3]), (v[4], v[5])))
        polygons.append(Polygon(cls, cx, cy, radius, triangles))

    (way_count,) = struct.unpack_from("<I", data, offset)
    offset += 4
    ways = []
    for _ in range(way_count):
        cls, cx, cy, radius, point_count = struct.unpack_from("<BhhHH", data, offset)
        offset += 9
        pts = struct.unpack_from(f"<{point_count * 2}h", data, offset)
        offset += point_count * 4
        points = list(zip(pts[0::2], pts[1::2]))
        ways.append(Way(cls, cx, cy, radius, points))

    assert offset == len(data), f"trailing bytes: read {offset}, file is {len(data)}"
    return MapData(polygons, ways)
