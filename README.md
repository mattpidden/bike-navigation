# Bike Navigation

A DIY bike computer: a 3D-printed, handlebar-mounted display (ESP32-S3 + round LCD) paired over Bluetooth to a phone app, showing a live, rendered map with your position and route — no phone screen required once you're riding.

<p>
  <!-- TODO: add a photo of the assembled device / a screenshot of the app here -->
</p>

## How it works

- **The app** (Flutter, Android/iOS) gets your GPS location and, when you pick a destination, a cycling route from Google Directions. It streams your position, heading, and route to the bike-mounted display over Bluetooth Low Energy.
- **The display** (ESP32-S3 + round LCD, twist-locked onto a handlebar mount) renders an offline vector map — roads, water, parks — baked into its own flash storage, and draws your live position/route on top of it. It doesn't need a network connection or GPS of its own; the phone supplies the data.
- **The map data** for both the display and the app's own on-screen map comes from OpenStreetMap, processed by a small Python pipeline in `maps/` into a compact custom binary format.

This is a hobby project, not a product — expect some rough edges, and treat the build instructions below as "this is how I did it," not a fully productised guide.

## Disclaimer

This is a hobbyist project, not a certified navigation or safety device. Route/map data can be wrong, outdated, or missing entirely, and Google's routing has no awareness of this project's hardware or your specific bike. Always use your own judgement: check a route before and while riding, don't follow it onto roads you shouldn't be cycling on (motorways, etc.), and obey local traffic laws regardless of what's on the screen. You use this project, and build/ride with it, entirely at your own risk — the author(s) accept no liability for any injury, damage, or other consequence arising from its use.

## Repo layout

```
app/       Flutter app (Android/iOS)
firmware/  ESP32-S3 firmware (Arduino)
maps/      OSM -> map.bin data pipeline + a pygame preview tool
cad/       3D-printable enclosure (STL files)
```

## Hardware

- [Waveshare ESP32-S3-Touch-LCD-1.28](https://www.waveshare.com/esp32-s3-touch-lcd-1.28.htm) — ESP32-S3 with a built-in 240×240 round GC9A01 LCD and QMI8658 IMU. This board's built-in battery-voltage ADC is used for the battery indicator; the IMU isn't currently used for anything (heading comes from the phone's GPS instead). ([buy](https://www.amazon.co.uk/dp/B0CSFFHNWT))
- A LiPo battery compatible with the board's JST connector. ([buy](https://www.amazon.co.uk/dp/B08215WQMQ))
- An on/off switch. These aren't commonly sold individually — the linked product is a multi-pack of assorted switches, of which you only need one. ([buy](https://www.amazon.co.uk/dp/B0817GD1Y8))
- The 3D-printed enclosure in `cad/`: `Concept Body` and `Concept Lid` house the electronics and twist-lock onto `Concept Mount`, which screws into the stem cap bolt in the center of your handlebars (the same mounting point Garmin/Wahoo-style quarter-turn bike computer mounts use). No particular print settings are prescribed — just make sure the LCD cutout, port openings, and the twist-lock tolerance line up with your printer before committing to a full print.

CAD design and enclosure by Tom Pidden.

## 1. Set up a Google Maps API key

The app uses Google's **Directions API** and **Places API** for routing and destination search.

1. Create a project in the [Google Cloud Console](https://console.cloud.google.com/).
2. Enable **Directions API** and **Places API** for that project (APIs & Services → Library).
3. Create an API key (APIs & Services → Credentials → Create Credentials → API key).
4. Set up billing on the project — Google requires a billing account even to stay within the free monthly credit.
5. **Set API restrictions** (Credentials → your key → API restrictions → Restrict key) to just **Directions API** and **Places API** — the only two this app calls. This limits the blast radius if the key ever leaks: it can only be used to call these two APIs, nothing else on your account.
6. **Application restrictions**: the app calls these APIs with plain HTTP requests (`http.get`) rather than through Google's native Android/iOS SDKs, so it doesn't send the package-name/cert headers that an "Android apps" or "iOS apps" restriction checks for — setting one would just break the app's requests. There isn't a clean restriction option for this key's actual usage pattern (a mobile app making direct REST calls); API restrictions above are your main protection. If you want tighter control, the real fix is routing these calls through your own backend and keeping the key server-side (restricted by IP) instead of embedding it in the app — this project doesn't do that today.

You'll use this key in step 3.

## 2. Flash the firmware

1. Install the [Arduino IDE](https://www.arduino.cc/en/software) and the ESP32 board support package (Boards Manager → search "esp32", install the Espressif package). Select an **ESP32S3 Dev Module** board profile with PSRAM enabled.
2. Install the [TFT_eSPI](https://github.com/Bodmer/TFT_eSPI) library (Library Manager → search "TFT_eSPI" by Bodmer) — this repo doesn't vendor it.
3. Point TFT_eSPI at this project's display config: copy `firmware/libaries/TFT_eSPI_Setups/Setup207_GC9A01.h` into the `User_Setups/` folder of your installed TFT_eSPI library, then edit that library's `User_Setup_Select.h` to `#include <User_Setups/Setup207_GC9A01.h>` instead of whatever's active by default. This file has the exact pin mapping for the Waveshare ESP32-S3-Touch-LCD-1.28's GC9A01 display.
4. Open `firmware/src/src.ino` in the Arduino IDE, select your board and port, and upload.
   - The baked map (`firmware/src/map_data.h`) already covers Central London out of the box (see step 4 below to build your own). If the sketch doesn't fit, try a "Huge APP" partition scheme (Tools → Partition Scheme).
5. On first boot the display shows "Waiting for GPS..." until the app connects and sends a location.

## 3. Build the app

1. Install [Flutter](https://docs.flutter.dev/get-started/install) and its Android/iOS toolchains.
2. `cd app && flutter pub get`
3. Copy `app/assets/.env.example` to `app/assets/.env` and fill in your API key from step 1:
   ```
   GOOGLE_MAPS_API_KEY=your_key_here
   ```
4. `flutter run` (with a device/emulator connected), or `flutter build apk` / `flutter build ios` for a release build.
5. `flutter test` runs the test suite.

**iOS only**: the bundle identifier and signing team in `app/ios/Runner.xcodeproj` are set to generic placeholders (`com.example.bikenavigation`, no team). Open `app/ios/Runner.xcworkspace` in Xcode and set your own bundle ID and Apple Developer Team under Runner → Signing & Capabilities before building for a real device — `flutter build ios`/`flutter run` on a device will fail without this. The Android build has no such step; it already ships with Flutter's generic `com.example.bike_navigation` and debug signing.

The app also bundles `maps/map.bin` directly (`pubspec.yaml` references it via a relative path outside `app/`) for its own on-screen map — no separate copy step needed, but it does mean `maps/map.bin` must exist (it's committed, covering Central London by default).

## 4. Building your own area's map (optional)

The repo ships with `maps/map.bin` pre-built for Central London. To cover your own area instead:

1. Download an OSM extract for your area from [BBBike's extract service](https://extract.bbbike.org/) in **`.osm.pbf`** format. A city-sized extract is plenty — this pipeline isn't built for anything continent-sized.
2. Put the downloaded file in `maps/`, and in `maps/build_map.py`, update:
   - `PBF` to point to your downloaded file.
   - `ORIGIN_LAT` / `ORIGIN_LON` to a point near the center of your area — everything is stored as meters relative to this point.
3. **Also update the matching origin constants in `app/lib/services/ble_protocol.dart`** (`originLat`/`originLon`) to the exact same values. The app projects GPS coordinates into this same local coordinate frame before sending them to the display — if the two origins don't match, your live position won't line up with the map.
4. Install [GDAL](https://gdal.org/) (provides the `ogr2ogr` command-line tool the pipeline shells out to) and Python 3.
5. `cd maps && python3 build_map.py` — this produces the new `map.bin`.
6. `python3 export_firmware.py` — converts `map.bin` into `firmware/src/map_data.h`; re-flash the firmware afterwards.
7. Optionally preview your map before flashing: `pip install pygame && python3 visualiser.py` opens an interactive pygame window at the same 240×240 geometry as the real display (WASD to move, Q/E to rotate, Z/X to zoom — see the script's docstring for the full control list). `python3 visualiser.py --snapshot out.png` renders one static frame without opening a window.

Note: the Thames polygon in the default map data comes from a separate, small OS OpenMap Local extract (`maps/thames_tidal_os.geojson`), not from OSM — the relevant OSM relation didn't reconstruct cleanly from a bbox-clipped extract. If your area includes a similarly large water body and OSM's polygon for it looks broken/missing in the visualiser, you may need to source an equivalent polygon yourself; `build_map.py`'s comments around `THAMES_TIDAL_GEOJSON` explain the shape it expects.

## Contributing

Issues and PRs are welcome. A few things worth knowing:

- There are effectively **three renderers of the same map data** that need to stay visually consistent: the firmware (`firmware/src/MapRenderer.h`, C++), the pygame preview (`maps/visualiser.py`, Python), and the app's own map view (`app/lib/widgets/offline_map_view.dart` and `app/lib/widgets/device_preview_map.dart`, Dart). If you change map styling (colors, widths, the route chevrons, etc.), it's worth checking whether the change should apply to all three.
- `maps/map_format.py` is the canonical spec/parser for the binary map format — start there if you need to understand or change the on-disk layout.
- The app has a real test suite (`app/test/`) covering the BLE protocol, route tracking, coordinate projection, and map parsing — `flutter test` before opening a PR.
- The Python pipeline has no test suite; the visualiser is the main way to sanity-check changes to it.

## License

[MIT](LICENSE) — covers the whole repo, including the CAD files.
