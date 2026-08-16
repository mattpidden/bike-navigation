// Renders the offline map baked into map_data.h. Binary layout is documented
// in maps/map_format.py — keep the two in sync.
#pragma once

#include <TFT_eSPI.h>
#include <string.h>
#include "map_data.h"

#define RGB565(r, g, b) ((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | ((b) >> 3))

static const uint16_t COLOR_GREEN  = RGB565(0x6D, 0xA5, 0x44);  // #6da544
static const uint16_t COLOR_BLUE   = RGB565(0x33, 0x8A, 0xF3);  // #338af3
static const uint16_t COLOR_RED    = RGB565(0xD8, 0x00, 0x27);  // #d80027
static const uint16_t COLOR_BG     = RGB565(0x21, 0x21, 0x21);  // #212121
static const uint16_t ROAD_MAJOR   = RGB565(0xEE, 0xEE, 0xEE);  // #eeeeee
static const uint16_t ROAD_MEDIUM  = RGB565(0xE0, 0xE0, 0xE0);  // #e0e0e0
static const uint16_t ROAD_MINOR   = RGB565(0xDB, 0xDB, 0xDB);  // #dbdbdb

struct RoadStyle {
  uint16_t color;
  float widthM;  // real-world meters, not pixels — so width scales with zoom like
                 // everything else on the map instead of staying a fixed pixel count
};

// class 0..6 -> motorway/trunk, primary, secondary/tertiary, residential, cycleway, path/track, water
static const RoadStyle ROAD_STYLES[7] = {
  { ROAD_MAJOR,  10.0f },
  { ROAD_MAJOR,  7.0f },
  { ROAD_MEDIUM, 7.0f },
  { ROAD_MINOR,  3.5f },
  { ROAD_MINOR,  3.5f },
  { ROAD_MINOR,  3.5f },
  { COLOR_BLUE,  8.5f },
};

static const float MIN_ROAD_WIDTH_PX = 1.0f;  // floor so roads don't vanish when zoomed way out

// polygon class 0..1 -> green (parks/woods/rec grounds), water (lakes/ponds/Thames)
static const uint16_t POLY_FILL_COLORS[2] = {
  COLOR_GREEN,
  COLOR_BLUE,  // same blue as the line-drawn waterways in ROAD_STYLES[6]
};

static const int MAP_SCREEN_CX = 120;  // true center of the round 240x240 screen — used for scale only
static const int MAP_SCREEN_CY = 120;
// "you are here" sits 1/3 up from the bottom edge rather than dead center, so more of
// the view ahead is visible and less of what's behind.
static const int MAP_FOCUS_X = 120;
static const int MAP_FOCUS_Y = 160;
static const uint16_t YOU_ARE_HERE_COLOR = COLOR_RED;

// Live route overlay — filled in from BLE ROUTE_CHUNK packets, not baked map data.
// Meters relative to the same home origin as everything else drawn here.
struct RoutePoint {
  float x, y;
};

static const uint16_t COLOR_ROUTE_CASING = RGB565(0x99, 0x5C, 0x0A);  // muted dark orange
static const uint16_t COLOR_ROUTE_CENTER = RGB565(0xFF, 0x98, 0x11);  // #ff9811
static const float ROUTE_CASING_WIDTH_M = 8.0f;
static const float ROUTE_CENTER_WIDTH_M = 3.0f;
static const float ROUTE_ARROW_SPACING_M = 20.0f;
static const float ROUTE_ARROW_SIZE_M = 2.5f;

static inline uint32_t mapReadU32(const uint8_t* p) { uint32_t v; memcpy(&v, p, 4); return v; }
static inline uint16_t mapReadU16(const uint8_t* p) { uint16_t v; memcpy(&v, p, 2); return v; }
static inline int16_t  mapReadI16(const uint8_t* p) { int16_t v; memcpy(&v, p, 2); return v; }

// posX/posY: current position in meters relative to the map origin (home).
// headingDeg: degrees clockwise from north — the map rotates so this is always "up".
// viewRadiusM: how many meters from posX/posY are visible at the screen edge.
// routePts/routeCount: the active route overlay, or nullptr/0 if none.
void drawMap(TFT_eSprite &frame, float posX, float posY, float headingDeg, float viewRadiusM,
             const RoutePoint* routePts, uint16_t routeCount) {
  const float pxPerM = (float)MAP_SCREEN_CX / viewRadiusM;
  const float theta = -headingDeg * DEG_TO_RAD;
  const float cosT = cosf(theta);
  const float sinT = sinf(theta);

  // World meters (relative to home) -> screen pixels, heading-up, focus-shifted.
  auto toScreenX = [&](float wx, float wy) -> float {
    float lx = wx - posX, ly = wy - posY;
    return MAP_FOCUS_X + (lx * cosT - ly * sinT) * pxPerM;
  };
  auto toScreenY = [&](float wx, float wy) -> float {
    float lx = wx - posX, ly = wy - posY;
    return MAP_FOCUS_Y - (lx * sinT + ly * cosT) * pxPerM;
  };

  const uint8_t* p = MAP_DATA;
  const uint8_t* end = MAP_DATA + MAP_DATA_LEN;

  // --- Section 1: filled areas (bottom layer) ---
  uint32_t polyCount = mapReadU32(p);
  p += 4;
  for (uint32_t i = 0; i < polyCount && p < end; i++) {
    uint8_t cls = p[0];
    int16_t cx = mapReadI16(p + 1);
    int16_t cy = mapReadI16(p + 3);
    uint16_t radius = mapReadU16(p + 5);
    uint16_t triCount = mapReadU16(p + 7);
    p += 9;

    float dx = (float)cx - posX;
    float dy = (float)cy - posY;
    float reach = viewRadiusM + (float)radius;
    bool visible = (dx * dx + dy * dy) <= (reach * reach);

    if (!visible) {
      p += (size_t)triCount * 12;
      continue;
    }

    uint16_t color = POLY_FILL_COLORS[cls];
    for (uint16_t t = 0; t < triCount; t++) {
      float ax = (float)mapReadI16(p), ay = (float)mapReadI16(p + 2);
      float bx = (float)mapReadI16(p + 4), by = (float)mapReadI16(p + 6);
      float cxp = (float)mapReadI16(p + 8), cyp = (float)mapReadI16(p + 10);
      p += 12;
      frame.fillTriangle(toScreenX(ax, ay), toScreenY(ax, ay),
                          toScreenX(bx, by), toScreenY(bx, by),
                          toScreenX(cxp, cyp), toScreenY(cxp, cyp),
                          color);
    }
  }

  // --- Section 2: line ways (drawn on top of areas) ---
  uint32_t wayCount = mapReadU32(p);
  p += 4;
  for (uint32_t i = 0; i < wayCount && p < end; i++) {
    uint8_t cls = p[0];
    int16_t cx = mapReadI16(p + 1);
    int16_t cy = mapReadI16(p + 3);
    uint16_t radius = mapReadU16(p + 5);
    uint16_t pointCount = mapReadU16(p + 7);
    p += 9;

    float dx = (float)cx - posX;
    float dy = (float)cy - posY;
    float reach = viewRadiusM + (float)radius;
    bool visible = (dx * dx + dy * dy) <= (reach * reach);

    if (!visible) {
      p += (size_t)pointCount * 4;
      continue;
    }

    const RoadStyle &style = ROAD_STYLES[cls];
    float widthPx = style.widthM * pxPerM;
    if (widthPx < MIN_ROAD_WIDTH_PX) widthPx = MIN_ROAD_WIDTH_PX;
    float prevSx = 0, prevSy = 0;
    bool havePrev = false;
    for (uint16_t j = 0; j < pointCount; j++) {
      float wx = (float)mapReadI16(p), wy = (float)mapReadI16(p + 2);
      p += 4;
      float sx = toScreenX(wx, wy), sy = toScreenY(wx, wy);

      if (havePrev) {
        frame.drawWideLine(prevSx, prevSy, sx, sy, widthPx, style.color);
      }
      prevSx = sx;
      prevSy = sy;
      havePrev = true;
    }
  }

  // --- Route overlay (drawn on top of the base map, under the "you are here" marker) ---
  // Capped at a few hundred points (see ROUTE_MAX_POINTS in src.ino) so no per-route
  // culling is needed — TFT_eSPI's own sprite clipping handles the off-screen parts cheaply.
  if (routePts != nullptr && routeCount >= 2) {
    float prevSx = toScreenX(routePts[0].x, routePts[0].y);
    float prevSy = toScreenY(routePts[0].x, routePts[0].y);
    for (uint16_t i = 1; i < routeCount; i++) {
      float sx = toScreenX(routePts[i].x, routePts[i].y);
      float sy = toScreenY(routePts[i].x, routePts[i].y);
      frame.drawWideLine(prevSx, prevSy, sx, sy, ROUTE_CASING_WIDTH_M * pxPerM, COLOR_ROUTE_CASING);
      prevSx = sx;
      prevSy = sy;
    }
    prevSx = toScreenX(routePts[0].x, routePts[0].y);
    prevSy = toScreenY(routePts[0].x, routePts[0].y);
    for (uint16_t i = 1; i < routeCount; i++) {
      float sx = toScreenX(routePts[i].x, routePts[i].y);
      float sy = toScreenY(routePts[i].x, routePts[i].y);
      frame.drawWideLine(prevSx, prevSy, sx, sy, ROUTE_CENTER_WIDTH_M * pxPerM, COLOR_ROUTE_CENTER);
      prevSx = sx;
      prevSy = sy;
    }

    // Direction arrows every ROUTE_ARROW_SPACING_M of arc length, built in world
    // meters (like everything else) then transformed — keeps them consistent with
    // the zoom scaling every other shape on the map already gets.
    float distSinceArrow = ROUTE_ARROW_SPACING_M;  // draw one near the start too
    for (uint16_t i = 1; i < routeCount; i++) {
      float x0 = routePts[i - 1].x, y0 = routePts[i - 1].y;
      float x1 = routePts[i].x, y1 = routePts[i].y;
      float segLen = sqrtf((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
      if (segLen == 0) continue;
      distSinceArrow += segLen;
      if (distSinceArrow < ROUTE_ARROW_SPACING_M) continue;
      distSinceArrow = 0;

      float ux = (x1 - x0) / segLen, uy = (y1 - y0) / segLen;
      float mx = (x0 + x1) * 0.5f, my = (y0 + y1) * 0.5f;
      float tipX = mx + ux * ROUTE_ARROW_SIZE_M, tipY = my + uy * ROUTE_ARROW_SIZE_M;
      float backX = mx - ux * ROUTE_ARROW_SIZE_M, backY = my - uy * ROUTE_ARROW_SIZE_M;
      float lx = -uy, ly = ux;  // perpendicular, world-space
      float leftX = backX + lx * ROUTE_ARROW_SIZE_M * 0.6f, leftY = backY + ly * ROUTE_ARROW_SIZE_M * 0.6f;
      float rightX = backX - lx * ROUTE_ARROW_SIZE_M * 0.6f, rightY = backY - ly * ROUTE_ARROW_SIZE_M * 0.6f;
      frame.fillTriangle(toScreenX(tipX, tipY), toScreenY(tipX, tipY),
                          toScreenX(leftX, leftY), toScreenY(leftX, leftY),
                          toScreenX(rightX, rightY), toScreenY(rightX, rightY),
                          COLOR_BG);
    }
  }

  // "you are here" — fixed at the focus point, pointing up (heading-up mode).
  frame.fillTriangle(MAP_FOCUS_X, MAP_FOCUS_Y - 16,
                      MAP_FOCUS_X - 10, MAP_FOCUS_Y + 12,
                      MAP_FOCUS_X + 10, MAP_FOCUS_Y + 12,
                      YOU_ARE_HERE_COLOR);
}
