import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_widget/home_widget.dart';
import 'location_service.dart';
import 'prayer_time_service.dart';
import 'hijri_calendar_helper.dart';

class WidgetService {
  /// Refreshes all cached prayer times, Islamic dates, and dynamic Salawat/Event text strings
  static Future<void> refreshWidgetData() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int hijriOffset = prefs.getInt('hijri_offset') ?? 0;

      // 1. Fetch current coordinates to accurately align Maghrib rollover states
      final coordinates = await LocationService.getSavedOrLiveLocation();
      final double lat = coordinates['latitude']!;
      final double lng = coordinates['longitude']!;

      final today = DateTime.now();
      final Map<String, DateTime> calculatedTimes = PrayerTimeService.calculateJafariTimes(
        latitude: lat,
        longitude: lng,
        date: today,
      );

      // 2. Determine if the current time has transitioned into the next Islamic day
      bool isCurrentlyAfterMaghrib = false;
      if (calculatedTimes.containsKey('maghrib')) {
        isCurrentlyAfterMaghrib = today.isAfter(calculatedTimes['maghrib']!);
      }

      final DateTime activeCalendarTarget = isCurrentlyAfterMaghrib
          ? today.add(Duration(days: 1 + hijriOffset))
          : today.add(Duration(days: hijriOffset));

      // 3. Extract the current day's events from the Hijri Helper
      final calendarData = HijriCalendarHelper.getHijriDateAndEvent(activeCalendarTarget);
      final String islamicDateStr = calendarData['formatted'] ?? "";
      final String shiaEventStr = calendarData['event'] ?? "";

      // 4. Dynamically build the Salawat text block matching your rules
      const String salawatBase = "اللَّهُمَّ صَلِّ عَلَى مُحَمَّدٍ وَآلِ مُحَمَّدٍ وَعَجِّلْ فَرَجَهُمْ";
      String dynamicWidgetFooter = salawatBase;

      if (shiaEventStr.trim().isNotEmpty) {
        dynamicWidgetFooter = "$salawatBase\n\n$shiaEventStr";
      }

      // 5. Commit structured key-value maps to native system memory pipelines
      await HomeWidget.saveWidgetData('hijri_date_text', islamicDateStr);
      await HomeWidget.saveWidgetData('salawat_display_text', dynamicWidgetFooter);

      // Save individual prayer times if your widget lists them
      calculatedTimes.forEach((key, value) {
        // Formats to string (e.g., "05:12 AM")
        final String formattedTime = "${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}";
        HomeWidget.saveWidgetData('widget_${key}_time', formattedTime);
      });

      // 6. Request OS native home screen container element repaint loop
      await HomeWidget.updateWidget(
        androidName: 'PrayerTimeWidgetProvider', // Must precisely match your Android Manifest receiver name
      );
      
      print(">>> Native Home Screen Widget synced successfully. Event status included: ${shiaEventStr.isNotEmpty}");
    } catch (e) {
      print("!!! Exception handling native widget layout pipeline update execution: $e");
    }
  }
}