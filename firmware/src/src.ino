/*
  This sketch demonstrates the use of the horizontal and vertical gradient
  rectangle fill functions.

  Example for library:
  https://github.com/Bodmer/TFT_eSPI

  Created by Bodmer 27/1/22
*/
#include "QMI8658.h"
#include <TFT_eSPI.h>       // Include the graphics library
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include "MapRenderer.h"


// Global variables
TFT_eSPI tft = TFT_eSPI();  // Create object "tft"
TFT_eSprite frame = TFT_eSprite(&tft);
bool deviceConnected = false;
enum AppState {
  STATE_HOME,
  STATE_NAVIGATION,
  STATE_ARRIVED
};
AppState currentState = STATE_HOME;

// Live telemetry from the phone (BLE TELEMETRY packets) — meters relative to the
// same home origin as the baked map data; frozen at last-known value on disconnect
// rather than reset, since a glanced-at wearable benefits from "last known view"
// over a blank one.
float currentPosX = 0, currentPosY = 0;
float currentHeadingDeg = 0;
bool telemetryReceived = false;

// Live route overlay (BLE ROUTE_START/ROUTE_CHUNK/ROUTE_END/ROUTE_CLEAR) — session
// data, not baked map data, so it lives in RAM as a fixed-size buffer rather than
// flash. "build" fills up as chunks arrive; ROUTE_END atomically swaps it into
// "active" so a route is never drawn mid-transfer.
#define ROUTE_MAX_POINTS 400
RoutePoint routeBuildBuf[ROUTE_MAX_POINTS];
RoutePoint routeActiveBuf[ROUTE_MAX_POINTS];
uint16_t routeBuildCount = 0;
uint16_t routeActiveCount = 0;
bool routeReady = false;

// Phone Icon
const unsigned char ble_bitmap [] PROGMEM = {
  // '191, 20x20px
  0x07, 0xfe, 0x00, 0x0f, 0x0f, 0x00, 0x0c, 0x03, 0x00, 0x0c, 0x01, 0x00, 0x0c, 0x01, 0x00, 0x0c, 
  0x01, 0x00, 0x0c, 0x01, 0x00, 0x0c, 0x01, 0x00, 0x0c, 0x01, 0x00, 0x0c, 0x01, 0x00, 0x0c, 0x01, 
  0x00, 0x0c, 0x01, 0x00, 0x0c, 0x01, 0x00, 0x0c, 0x01, 0x00, 0x0c, 0x01, 0x00, 0x0f, 0xff, 0x00, 
  0x0f, 0xff, 0x00, 0x0f, 0x9f, 0x00, 0x0f, 0xff, 0x00, 0x07, 0xfe, 0x00
};

String batteryStatus;
unsigned long lastWriteTime = 0;
BLEServer* pServer;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    Serial.print("Connected to phone...");
    lastWriteTime = millis();
    deviceConnected = true;
  }
  void onDisconnect(BLEServer* pServer) {
    Serial.print("Disconnected...");
    pServer->startAdvertising();
    deviceConnected = false;
  }
};


// Binary BLE protocol (little-endian, matches ESP32/Xtensa native order — no byte
// swapping needed). First byte of every write is the packet type:
//   0x01 TELEMETRY   {x_cm:i32, y_cm:i32, heading_decideg:i16, mode:u8}      12B
//   0x02 ROUTE_START {total_points:u16}                                      3B
//   0x03 ROUTE_CHUNK {seq:u16, count:u8, (x_cm:i32,y_cm:i32)*count}      4+8*count B
//   0x04 ROUTE_END   {}                                                      1B
//   0x05 ROUTE_CLEAR {}                                                      1B
// Positions are centimeters relative to the same home-origin local frame the
// baked map data uses (see maps/build_map.py) — converted to meters on receipt.
class MyCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) override {
    lastWriteTime = millis();
    String value = pCharacteristic->getValue();
    size_t len = value.length();
    if (len < 1) return;
    const uint8_t* d = (const uint8_t*)value.c_str();
    uint8_t type = d[0];

    switch (type) {
      case 0x01: {  // TELEMETRY
        if (len != 12) {
          Serial.println("TELEMETRY: bad length, dropping");
          break;
        }
        int32_t xCm, yCm;
        int16_t headingDd;
        memcpy(&xCm, d + 1, 4);
        memcpy(&yCm, d + 5, 4);
        memcpy(&headingDd, d + 9, 2);
        uint8_t mode = d[11];

        currentPosX = xCm / 100.0f;
        currentPosY = yCm / 100.0f;
        currentHeadingDeg = headingDd / 10.0f;
        telemetryReceived = true;

        switch (mode) {
          case 0: currentState = STATE_HOME; break;
          case 1: currentState = STATE_NAVIGATION; break;
          case 2: currentState = STATE_ARRIVED; break;
          default:
            Serial.println("TELEMETRY: unknown mode, defaulting to home");
            currentState = STATE_HOME;
        }
        break;
      }

      case 0x02: {  // ROUTE_START — reset the build buffer; active route stays visible
        if (len != 3) {
          Serial.println("ROUTE_START: bad length, dropping");
          break;
        }
        routeBuildCount = 0;
        break;
      }

      case 0x03: {  // ROUTE_CHUNK
        if (len < 4) {
          Serial.println("ROUTE_CHUNK: bad length, dropping");
          break;
        }
        uint8_t count = d[3];
        if (len != (size_t)(4 + count * 8)) {
          Serial.println("ROUTE_CHUNK: length mismatch, dropping");
          break;
        }
        for (uint8_t i = 0; i < count && routeBuildCount < ROUTE_MAX_POINTS; i++) {
          int32_t xCm, yCm;
          memcpy(&xCm, d + 4 + i * 8, 4);
          memcpy(&yCm, d + 4 + i * 8 + 4, 4);
          routeBuildBuf[routeBuildCount].x = xCm / 100.0f;
          routeBuildBuf[routeBuildCount].y = yCm / 100.0f;
          routeBuildCount++;
        }
        break;
      }

      case 0x04: {  // ROUTE_END — atomic swap so a half-received route is never drawn
        memcpy(routeActiveBuf, routeBuildBuf, routeBuildCount * sizeof(RoutePoint));
        routeActiveCount = routeBuildCount;
        routeReady = (routeActiveCount >= 2);
        break;
      }

      case 0x05: {  // ROUTE_CLEAR
        routeActiveCount = 0;
        routeBuildCount = 0;
        routeReady = false;
        break;
      }

      default:
        Serial.print("Unknown BLE packet type: ");
        Serial.println(type);
    }
  }
};

void setupBLE() {
  BLEDevice::init("ESP32");
  BLEDevice::setMTU(517);  // request the max ATT MTU — default (~20B usable) would make ROUTE_CHUNK transfer crawl
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService *pService = pServer->createService("12345678-1234-1234-1234-1234567890ab");
  BLECharacteristic *pCharacteristic = pService->createCharacteristic(
      "87654321-4321-4321-4321-ba0987654321",
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR | BLECharacteristic::PROPERTY_READ);
  pCharacteristic->setCallbacks(new MyCallbacks());

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(pService->getUUID());
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMaxPreferred(0x12);
  pAdvertising->start();

  Serial.println("BLE ready.");
}

void drawCenteredText(String text, int y, int textsize, uint16_t color = TFT_WHITE) {
  frame.setTextColor(color);
  frame.setTextFont(2);
  frame.setTextSize(textsize);
  int16_t h = frame.fontHeight();
  int16_t w = frame.textWidth(text);
  frame.setCursor((240 - w) / 2, y - (h / 2));
  frame.print(text);
}


// -------------------------------------------------------------------------
// Setup
// -------------------------------------------------------------------------
void setup(void) {
  Serial.begin(115200);
  delay(5000);
  Serial.println("Board On!");
  Wire.begin(6, 7);   // SDA=6, SCL=7
  delay(200);
  QMI8658_init();      // starts IMU
  Serial.println("IMU On");
  tft.init();
  tft.setRotation(0);
  tft.fillScreen(COLOR_BG);
  Serial.println("Screen On!");
  frame.createSprite(240, 240);
  setupBLE();
  lastWriteTime = millis();
}


// -------------------------------------------------------------------------
// Main loop
// -------------------------------------------------------------------------
const float MAP_VIEW_RADIUS_M = 150.0f;

// The map is the universal screen now — STATE_NAVIGATION/STATE_ARRIVED just change
// what's overlaid on top of it (route, "ARRIVED" text) rather than swapping to a
// separate screen, so BLE-icon/battery drawing isn't duplicated three times.
void drawHomeScreen() {
  frame.fillSprite(COLOR_BG);

  if (!telemetryReceived) {
    drawMap(frame, 0, 0, 0, MAP_VIEW_RADIUS_M, nullptr, 0);
    drawCenteredText("Waiting for GPS...", 120, 1);
  } else {
    drawMap(frame, currentPosX, currentPosY, currentHeadingDeg, MAP_VIEW_RADIUS_M,
            routeReady ? routeActiveBuf : nullptr, routeReady ? routeActiveCount : 0);
    if (currentState == STATE_ARRIVED) {
      drawCenteredText("ARRIVED", 120, 2, COLOR_RED);
    }
  }

  if (deviceConnected) {
    frame.drawBitmap(110, 215, ble_bitmap, 20, 20, TFT_WHITE);
  } else if (telemetryReceived) {
    drawCenteredText("Reconnecting...", 225, 1);
  }
  drawCenteredText(batteryStatus, 15, 1);
  frame.pushSprite(0, 0);
}

static unsigned long lastBatteryUpdate = 0;

void loop() {
  if (deviceConnected && millis() - lastWriteTime > 10000) {
    Serial.println("No write received for 10s — disconnecting client");
    pServer->disconnect(pServer->getConnId());
    deviceConnected = false;
  }
  if (millis() - lastBatteryUpdate >= 1000) {  // every 1 second
    lastBatteryUpdate = millis();
    uint16_t result = DEC_ADC_Read();
    const float conversion_factor = 3.3f / 4095.0f * 3.8f;
    float voltage = result * conversion_factor;
    float percent = (voltage - 3.0f) / (4.1f - 3.0f) * 100.0f;
    percent = constrain(percent, 0.0f, 100.0f);
    batteryStatus = String(voltage, 2) + "V  (" + String(percent, 0) + "%)";
    Serial.println(batteryStatus);
  }
  // deviceConnected or not, currentState HOME/NAVIGATION/ARRIVED or not — it's
  // always the same map screen now, driven by whatever telemetry/route we last got.
  drawHomeScreen();
}
