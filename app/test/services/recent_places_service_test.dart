import 'package:bike_navigation/services/recent_places_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RecentPlacesService', () {
    test('returns an empty list when nothing has been saved', () async {
      final service = RecentPlacesService();
      expect(await service.getRecent(), isEmpty);
    });

    test('most recently added place comes first', () async {
      final service = RecentPlacesService();
      await service.addRecent(const SelectedPlace(description: 'A', lat: 1, lng: 1));
      await service.addRecent(const SelectedPlace(description: 'B', lat: 2, lng: 2));

      final recent = await service.getRecent();
      expect(recent.map((p) => p.description), ['B', 'A']);
    });

    test('re-adding an existing place moves it to the front instead of duplicating', () async {
      final service = RecentPlacesService();
      await service.addRecent(const SelectedPlace(description: 'A', lat: 1, lng: 1));
      await service.addRecent(const SelectedPlace(description: 'B', lat: 2, lng: 2));
      await service.addRecent(const SelectedPlace(description: 'A', lat: 1, lng: 1));

      final recent = await service.getRecent();
      expect(recent.map((p) => p.description), ['A', 'B']);
    });

    test('caps the stored list at 8 entries', () async {
      final service = RecentPlacesService();
      for (var i = 0; i < 10; i++) {
        await service.addRecent(SelectedPlace(description: 'Place $i', lat: i.toDouble(), lng: i.toDouble()));
      }

      final recent = await service.getRecent();
      expect(recent.length, 8);
      expect(recent.first.description, 'Place 9');
    });
  });
}
