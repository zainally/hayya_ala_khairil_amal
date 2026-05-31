import 'package:intl/intl.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'prayer_time_service.dart';
import 'hijri_calendar_helper.dart';

class WidgetService {
  static Future<void> refreshWidgetData() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      
      bool useManual = prefs.getBool('use_manual_location') ?? false;
      double lat = useManual ? (prefs.getDouble('manual_lat') ?? 24.8607) : (prefs.getDouble('last_lat') ?? 24.8607);
      double lng = useManual ? (prefs.getDouble('manual_lng') ?? 67.0011) : (prefs.getDouble('last_lng') ?? 67.0011);
      int offset = prefs.getInt('hijri_offset') ?? 0;

      final today = DateTime.now();
      final calculatedTimes = PrayerTimeService.calculateJafariTimes(latitude: lat, longitude: lng, date: today);
      
      bool isPastMaghrib = today.isAfter(calculatedTimes['maghrib'] ?? today);
      final DateTime targetDate = isPastMaghrib ? today.add(Duration(days: 1 + offset)) : today.add(Duration(days: offset));
      
      final calendarData = HijriCalendarHelper.getHijriDateAndEvent(targetDate);
      final String hijriStr = calendarData['formatted']!;

      // Generate the Gregorian string to match the header design layout
      final String gregorianStr = DateFormat('EEEE d MMMM').format(today);

      final DateFormat formatter = DateFormat('hh:mm a');

      String nextPrayerKey = "fajr"; 
      final List<String> trackingKeys = ["fajr", "dhuhr", "asr", "maghrib", "isha"];

      for (String key in trackingKeys) {
        if (calculatedTimes[key] != null && calculatedTimes[key]!.isAfter(today)) {
          nextPrayerKey = key;
          break;
        }
      }

      // Append data arrays down the platform channel
      await HomeWidget.saveWidgetData('gregorian_date', gregorianStr);
      await HomeWidget.saveWidgetData('hijri_date', hijriStr);
      await HomeWidget.saveWidgetData('next_prayer', nextPrayerKey);
      await HomeWidget.saveWidgetData('time_fajr', formatter.format(calculatedTimes['fajr']!));
      await HomeWidget.saveWidgetData('time_dhuhr', formatter.format(calculatedTimes['dhuhr']!));
      await HomeWidget.saveWidgetData('time_asr', formatter.format(calculatedTimes['asr']!));
      await HomeWidget.saveWidgetData('time_maghrib', formatter.format(calculatedTimes['maghrib']!));
      await HomeWidget.saveWidgetData('time_isha', formatter.format(calculatedTimes['isha']!));

      await HomeWidget.updateWidget(
        name: 'PrayerWidgetProvider',
        androidName: 'PrayerWidgetProvider',
      );
    } catch (e) {
      print("!!! Widget service sync failure: $e");
    }
  }
}