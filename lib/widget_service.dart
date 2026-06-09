import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_widget/home_widget.dart';
import 'location_service.dart';
import 'prayer_time_service.dart';
import 'hijri_calendar_helper.dart';

class WidgetService {
  /// Refreshes home screen widget data using validated data or background fallbacks
  static Future<void> refreshWidgetData({
    Map<String, DateTime>? preCalculatedTimes,
    String? preCalculatedHijriDate,
    String? preCalculatedShiaEvent,
  }) async {
    try {
      Map<String, DateTime> calculatedTimes;
      String islamicDateStr = "";
      String shiaEventStr = "";

      // 1. If foreground data is provided, use it directly to bypass type-casting risks
      if (preCalculatedTimes != null && preCalculatedHijriDate != null) {
        calculatedTimes = preCalculatedTimes;
        islamicDateStr = preCalculatedHijriDate;
        shiaEventStr = preCalculatedShiaEvent ?? "";
      } else {
        // Background isolate fallback execution loop
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        final int hijriOffset = prefs.getInt('hijri_offset') ?? 0;

        final coordinates = await LocationService.getSavedOrLiveLocation();
        final double lat = coordinates['latitude']!;
        final double lng = coordinates['longitude']!;

        final today = DateTime.now();
        
        // 🌟 Fixed: Cast explicitly to resolve background type mismatch exceptions safely
        calculatedTimes = Map<String, DateTime>.from(
          PrayerTimeService.calculateJafariTimes(
            latitude: lat,
            longitude: lng,
            date: today,
          )
        );

        bool isCurrentlyAfterMaghrib = false;
        if (calculatedTimes.containsKey('maghrib')) {
          isCurrentlyAfterMaghrib = today.isAfter(calculatedTimes['maghrib']!);
        }

        final DateTime activeCalendarTarget = isCurrentlyAfterMaghrib
            ? today.add(Duration(days: 1 + hijriOffset))
            : today.add(Duration(days: hijriOffset));

        final calendarData = HijriCalendarHelper.getHijriDateAndEvent(activeCalendarTarget);
        islamicDateStr = calendarData['formatted'] ?? "";
        shiaEventStr = calendarData['event'] ?? "";
      }

      // 2. Formulate dynamic combination footer string
      const String salawatBase = "اللَّهُمَّ صَلِّ عَلَى مُحَمَّدٍ وَآلِ مُحَمَّدٍ وَعَجِّلْ فَرَجَهُمْ";
      String dynamicWidgetFooter = salawatBase;

      if (shiaEventStr.trim().isNotEmpty) {
        dynamicWidgetFooter = "$salawatBase\n\n$shiaEventStr";
      }

      // 3. Serialize formatted prayer strings into native layout view targets
      final listTimeFormat = DateFormat('hh:mm a');
      final coreWidgetPrayers = ['fajr', 'dhuhr', 'asr', 'maghrib', 'isha'];

      for (var prayer in coreWidgetPrayers) {
        if (calculatedTimes.containsKey(prayer)) {
          final timeStr = listTimeFormat.format(calculatedTimes[prayer]!);
          await HomeWidget.saveWidgetData('time_$prayer', timeStr);
        }
      }

      // 4. Calculate active row color highlight index
      String nextPrayerKey = "";
      final now = DateTime.now();
      DateTime? nextTime;

      for (var prayer in coreWidgetPrayers) {
        if (calculatedTimes.containsKey(prayer)) {
          final pTime = calculatedTimes[prayer]!;
          if (pTime.isAfter(now)) {
            if (nextTime == null || pTime.isBefore(nextTime)) {
              nextTime = pTime;
              nextPrayerKey = prayer;
            }
          }
        }
      }

      if (nextPrayerKey.isEmpty) {
        nextPrayerKey = "fajr";
      }

      // 5. Commit persistent memory entries matching native layout fields
      await HomeWidget.saveWidgetData('hijri_date', islamicDateStr);
      await HomeWidget.saveWidgetData('next_prayer', nextPrayerKey);
      await HomeWidget.saveWidgetData('salawat_display_text', dynamicWidgetFooter);

      // 6. Signal OS native remote views update loop
      await HomeWidget.updateWidget(
        androidName: 'PrayerWidgetProvider',
      );
      print(">>> Home Widget dataset written and synchronized successfully.");
    } catch (e) {
      print("!!! Exception updating native widget layout pipeline: $e");
    }
  }
}