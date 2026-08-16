#!/usr/bin/env python3
"""Local pygame preview of the on-device map renderer, so we can settle on a
style before writing any firmware. Draws the same map.bin the ESP32 will get,
at the same 240x240 round geometry (scaled up for visibility on a laptop).

Controls:
    W/A/S/D     move (relative to current heading, like actually riding)
    Q/E         rotate heading left/right
    Z/X         zoom out/in (view radius)
    R           reset to home / north
    Esc         quit

Run:
    python3 visualiser.py
    python3 visualiser.py --snapshot out.png   # render one static frame, no window
"""
import argparse
import math
import sys
from pathlib import Path

import pygame

import map_format

MAP_BIN = Path(__file__).parent / "map.bin"

# --- Style — tweak these and rerun to see the effect immediately -----------
SCALE = 2  # real device is 240x240; blown up 2x so it's visible on a laptop
SCREEN_PX = 240 * SCALE
BG_COLOR = (0x21, 0x21, 0x21)  # #212121
BEZEL_COLOR = (60, 60, 60)
YOU_COLOR = (0xD8, 0x00, 0x27)  # #d80027
HUD_COLOR = (150, 150, 150)

GREEN = (0x6D, 0xA5, 0x44)   # #6da544
BLUE = (0x33, 0x8A, 0xF3)    # #338af3
ROAD_MAJOR = (0xEE, 0xEE, 0xEE)  # #eeeeee
ROAD_MEDIUM = (0xE0, 0xE0, 0xE0)  # #e0e0e0
ROAD_MINOR = (0xDB, 0xDB, 0xDB)  # #dbdbdb

# color + width (real-world meters, not pixels — scales with zoom like everything else)
STYLE = {
    0: {"color": ROAD_MAJOR, "width_m": 10.0},  # motorway/trunk
    1: {"color": ROAD_MAJOR, "width_m": 7.0},   # primary
    2: {"color": ROAD_MEDIUM, "width_m": 7.0},  # secondary/tertiary
    3: {"color": ROAD_MINOR, "width_m": 3.5},   # residential
    4: {"color": ROAD_MINOR, "width_m": 3.5},   # cycleway
    5: {"color": ROAD_MINOR, "width_m": 3.5},   # path/track
    6: {"color": BLUE, "width_m": 8.5},         # water (rivers/canals)
}
MIN_ROAD_WIDTH_PX = 1.0  # floor so roads don't vanish when zoomed way out

# fill color per polygon class (0=green, 1=water)
POLY_STYLE = {
    0: GREEN,  # parks/woods/rec grounds
    1: BLUE,   # water areas — same blue as the line-drawn waterways (class 6 above)
}

# active-route overlay: orange (#ff9811) line with a white border on either side
ROUTE_BORDER_COLOR = (0xFF, 0xFF, 0xFF)
ROUTE_CENTER_COLOR = (0xFF, 0x98, 0x11)  # #ff9811
ROUTE_BORDER_WIDTH_M = 12.0
ROUTE_CENTER_WIDTH_M = 8.0

# direction chevrons drawn on top of the route — same orange fill / white
# border as the route line itself, but wider so they stick out either side.
CHEVRON_WIDTH_M = 22.0   # wider than ROUTE_BORDER_WIDTH_M so it pokes out both sides
CHEVRON_LENGTH_M = 20.0
CHEVRON_NOTCH_M = 8.0    # how far the back notch cuts forward, giving the arrow its "V"
CHEVRON_BORDER_MARGIN_M = 3.0  # white outline thickness around each chevron
CHEVRON_SPACING_M = 100.0  # real-world distance between chevrons along the route

DEFAULT_VIEW_RADIUS_M = 150.0
MOVE_SPEED_MPS = 6.0  # ~13mph, a plausible cycling speed
ROTATE_SPEED_DPS = 90.0
# ----------------------------------------------------------------------------


def pick_demo_route(ways):
    """No real route to preview with yet (that comes from the phone app), so borrow
    a real nearby major road's own points as a stand-in — good enough to judge the
    route line styling without inventing fake geometry."""
    candidates = [w for w in ways if w.cls in (0, 1) and len(w.points) >= 6]
    if not candidates:
        return []
    candidates.sort(key=lambda w: math.hypot(w.cx, w.cy))
    return candidates[0].points


def _chevron_local_points(width_m, length_m, notch_m):
    """A forward-pointing arrow/flag shape in a local frame where +y is the
    direction of travel and +x is to the right: a tip at the front and a
    V-notch cut into the back edge, which is what actually reads as a
    "chevron" rather than a plain triangle."""
    half_w, half_l = width_m / 2, length_m / 2
    return [
        (0, half_l),               # front tip
        (half_w, -half_l),         # back right
        (0, -half_l + notch_m),    # back notch (pulled forward)
        (-half_w, -half_l),        # back left
    ]


def _place_local_points(base_x, base_y, dir_x, dir_y, local_points):
    """Transforms local (right, forward) points into world meters, oriented
    by the given forward direction — same idea as to_screen's rotation, just
    per-chevron instead of per-frame."""
    right_x, right_y = dir_y, -dir_x
    return [(base_x + right_x * lx + dir_x * ly, base_y + right_y * lx + dir_y * ly) for lx, ly in local_points]


def _chevron_placements(route_pts, spacing_m):
    """Walks the route polyline at a fixed real-world distance interval,
    yielding (x, y, dir_x, dir_y) for each chevron — spacing by distance
    rather than by point index keeps the chevrons evenly spaced regardless
    of how densely the route's own points are packed."""
    if len(route_pts) < 2:
        return []
    placements = []
    dist_since_last = spacing_m / 2  # first chevron a bit into the route, not right at the start
    for i in range(len(route_pts) - 1):
        x0, y0 = route_pts[i]
        x1, y1 = route_pts[i + 1]
        seg_dx, seg_dy = x1 - x0, y1 - y0
        seg_len = math.hypot(seg_dx, seg_dy)
        if seg_len < 1e-6:
            continue
        dir_x, dir_y = seg_dx / seg_len, seg_dy / seg_len
        pos_along = 0.0
        while dist_since_last + (seg_len - pos_along) >= spacing_m:
            pos_along += spacing_m - dist_since_last
            placements.append((x0 + dir_x * pos_along, y0 + dir_y * pos_along, dir_x, dir_y))
            dist_since_last = 0.0
        dist_since_last += seg_len - pos_along
    return placements


class MapView:
    def __init__(self, map_data: map_format.MapData, route=None):
        self.polygons = map_data.polygons
        self.ways = map_data.ways
        self.route = route or []
        self.x = 0.0
        self.y = 0.0
        self.heading = 0.0  # degrees, 0 = north, clockwise
        self.view_radius_m = DEFAULT_VIEW_RADIUS_M

    def move_forward(self, dist_m):
        rad = math.radians(self.heading)
        self.x += math.sin(rad) * dist_m
        self.y += math.cos(rad) * dist_m

    def strafe(self, dist_m):
        rad = math.radians(self.heading + 90)
        self.x += math.sin(rad) * dist_m
        self.y += math.cos(rad) * dist_m

    def render(self, surface):
        surface.fill(BG_COLOR)
        center = SCREEN_PX / 2
        px_per_m = (SCREEN_PX / 2) / self.view_radius_m
        # "you are here" sits 1/3 up from the bottom edge rather than dead center, so
        # more of the view ahead is visible and less of what's behind.
        focus_x = center
        focus_y = SCREEN_PX - SCREEN_PX / 3

        # heading-up: bearings (0=north, clockwise) map to world vectors as
        # (sin, cos), not (cos, sin) like standard math angles — rotating by
        # -heading here would rotate bearing-space vectors by the wrong sign
        # (works out to a spurious 2x-heading rotation, not a no-op or mirror).
        # +heading is the correct angle to align "facing direction" with "screen up".
        theta = math.radians(self.heading)
        cos_t, sin_t = math.cos(theta), math.sin(theta)

        def to_screen(wx, wy):
            lx, ly = wx - self.x, wy - self.y
            rx = lx * cos_t - ly * sin_t
            ry = lx * sin_t + ly * cos_t
            return (focus_x + rx * px_per_m, focus_y - ry * px_per_m)

        # filled areas first — bottom layer, roads/water-lines draw on top of these
        for poly in self.polygons:
            dx, dy = poly.cx - self.x, poly.cy - self.y
            reach = self.view_radius_m + poly.radius
            if dx * dx + dy * dy > reach * reach:
                continue
            color = POLY_STYLE[poly.cls]
            for a, b, c in poly.triangles:
                pygame.draw.polygon(surface, color, [to_screen(*a), to_screen(*b), to_screen(*c)])

        for way in self.ways:
            dx, dy = way.cx - self.x, way.cy - self.y
            reach = self.view_radius_m + way.radius
            if dx * dx + dy * dy > reach * reach:
                continue
            style = STYLE[way.cls]
            # px_per_m already bakes in SCALE (SCREEN_PX = 240*SCALE), so this width is
            # already in final canvas pixels — do NOT multiply by SCALE again here.
            width_px = max(MIN_ROAD_WIDTH_PX * SCALE, style["width_m"] * px_per_m)
            screen_pts = [to_screen(wx, wy) for wx, wy in way.points]
            if len(screen_pts) >= 2:
                pygame.draw.lines(surface, style["color"], False, screen_pts, max(1, round(width_px)))

        # active route overlay — white border, orange line on top, no arrows
        if len(self.route) >= 2:
            route_screen = [to_screen(wx, wy) for wx, wy in self.route]
            border_px = max(1, round(max(MIN_ROAD_WIDTH_PX, ROUTE_BORDER_WIDTH_M * px_per_m)))
            center_px = max(1, round(max(MIN_ROAD_WIDTH_PX, ROUTE_CENTER_WIDTH_M * px_per_m)))
            pygame.draw.lines(surface, ROUTE_BORDER_COLOR, False, route_screen, border_px)
            pygame.draw.lines(surface, ROUTE_CENTER_COLOR, False, route_screen, center_px)

            # direction chevrons on top of the route line — same border/fill
            # colors as the route itself, spaced by real-world distance.
            for px, py, dir_x, dir_y in _chevron_placements(self.route, CHEVRON_SPACING_M):
                dx, dy = px - self.x, py - self.y
                if dx * dx + dy * dy > self.view_radius_m * self.view_radius_m:
                    continue
                border_pts = _place_local_points(px, py, dir_x, dir_y, _chevron_local_points(
                    CHEVRON_WIDTH_M + CHEVRON_BORDER_MARGIN_M * 2,
                    CHEVRON_LENGTH_M + CHEVRON_BORDER_MARGIN_M * 2,
                    CHEVRON_NOTCH_M + CHEVRON_BORDER_MARGIN_M,
                ))
                fill_pts = _place_local_points(
                    px, py, dir_x, dir_y, _chevron_local_points(CHEVRON_WIDTH_M, CHEVRON_LENGTH_M, CHEVRON_NOTCH_M)
                )
                pygame.draw.polygon(surface, ROUTE_BORDER_COLOR, [to_screen(wx, wy) for wx, wy in border_pts])
                pygame.draw.polygon(surface, ROUTE_CENTER_COLOR, [to_screen(wx, wy) for wx, wy in fill_pts])

        # bezel ring (cosmetic reference for the round glass)
        pygame.draw.circle(surface, BEZEL_COLOR, (center, center), center - 1, width=2)

        # "you are here" — fixed at the focus point, pointing up (heading-up mode)
        tip = (focus_x, focus_y - 16 * SCALE)
        left = (focus_x - 10 * SCALE, focus_y + 12 * SCALE)
        right = (focus_x + 10 * SCALE, focus_y + 12 * SCALE)
        pygame.draw.polygon(surface, YOU_COLOR, [tip, left, right])


def draw_hud(surface, font, view: MapView, fps):
    lines = [
        f"pos=({view.x:6.0f}, {view.y:6.0f})m  heading={view.heading:5.1f}  radius={view.view_radius_m:.0f}m  fps={fps:.0f}",
        "WASD move  Q/E rotate  Z/X zoom  R reset  Esc quit",
    ]
    y = 4
    for line in lines:
        surface.blit(font.render(line, True, HUD_COLOR), (4, y))
        y += 14


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot", help="render one static frame to this PNG path and exit")
    parser.add_argument("--x", type=float, default=0.0, help="position, meters east of home")
    parser.add_argument("--y", type=float, default=0.0, help="position, meters north of home")
    parser.add_argument("--heading", type=float, default=0.0, help="degrees clockwise from north")
    parser.add_argument("--radius", type=float, default=DEFAULT_VIEW_RADIUS_M, help="view radius, meters")
    args = parser.parse_args()

    map_data = map_format.load(MAP_BIN)
    view = MapView(map_data, route=pick_demo_route(map_data.ways))
    view.x, view.y, view.heading, view.view_radius_m = args.x, args.y, args.heading, args.radius

    pygame.init()
    if args.snapshot:
        surf = pygame.Surface((SCREEN_PX, SCREEN_PX))
        view.render(surf)
        pygame.image.save(surf, args.snapshot)
        print(f"wrote {args.snapshot}")
        return

    screen = pygame.display.set_mode((SCREEN_PX, SCREEN_PX + 32))
    pygame.display.set_caption("bike nav map preview")
    clock = pygame.time.Clock()
    font = pygame.font.SysFont("monospace", 12)
    map_surf = pygame.Surface((SCREEN_PX, SCREEN_PX))

    running = True
    while running:
        dt = clock.tick(60) / 1000.0
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
                running = False
            elif event.type == pygame.KEYDOWN and event.key == pygame.K_r:
                view.x = view.y = view.heading = 0.0

        keys = pygame.key.get_pressed()
        if keys[pygame.K_w]:
            view.move_forward(MOVE_SPEED_MPS * dt)
        if keys[pygame.K_s]:
            view.move_forward(-MOVE_SPEED_MPS * dt)
        if keys[pygame.K_a]:
            view.strafe(-MOVE_SPEED_MPS * dt)
        if keys[pygame.K_d]:
            view.strafe(MOVE_SPEED_MPS * dt)
        if keys[pygame.K_q]:
            view.heading = (view.heading - ROTATE_SPEED_DPS * dt) % 360
        if keys[pygame.K_e]:
            view.heading = (view.heading + ROTATE_SPEED_DPS * dt) % 360
        if keys[pygame.K_z]:
            view.view_radius_m = min(600.0, view.view_radius_m * (1 + dt))
        if keys[pygame.K_x]:
            view.view_radius_m = max(30.0, view.view_radius_m * (1 - dt))

        view.render(map_surf)
        screen.fill((15, 15, 15))
        screen.blit(map_surf, (0, 0))
        draw_hud(screen, font, view, clock.get_fps())
        pygame.display.flip()

    pygame.quit()


if __name__ == "__main__":
    main()
