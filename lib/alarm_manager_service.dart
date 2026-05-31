import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'hijri_calendar_helper.dart';
import 'widget_service.dart';

class AlarmManagerService {
  static Future<void> initializeEngine() async {
    await AndroidAlarmManager.initialize();
  }

  // Extracts all track assets to native permanent storage (Executed in Foreground Main)
  static Future<void> primeAudioCache() async {
    final List<String> audioTracks = [
      'assets/audio/adhan_zadeh.mp3',
      'assets/audio/adhan_ghalwash.mp3',
      'assets/audio/adhan_ridhayan.mp3',
      'assets/audio/adhan_alhalawaji.mp3',
      'assets/audio/adhan_maytham.mp3',
      'assets/audio/adhan_ardabili.m4a',
    ];

    try {
      final Directory docDir = await getApplicationDocumentsDirectory();
      for (String assetPath in audioTracks) {
        final String fileName = assetPath.split('/').last;
        final File targetFile = File('${docDir.path}/$fileName');
        
        if (!await targetFile.exists()) {
          final ByteData bytePayload = await rootBundle.load(assetPath);
          final List<int> rawBytes = bytePayload.buffer.asUint8List(
            bytePayload.offsetInBytes, 
            bytePayload.lengthInBytes,
          );
          await targetFile.writeAsBytes(rawBytes, flush: true);
          print(">>> Permanent System Cache Synchronized: $fileName");
        }
      }
    } catch (e) {
      print("!!! Error building permanent foreground audio cache: $e");
    }
  }

  static Future<void> scheduleAzanAlarm({required int alarmId, required DateTime targetTime}) async {
    await AndroidAlarmManager.oneShotAt(
      targetTime,
      alarmId,
      hayyaBackgroundAzanExecutor,
      alarmClock: true,
      allowWhileIdle: true,
      exact: true,
    );
  }
}

@pragma('vm:entry-point')
void hayyaBackgroundAzanExecutor(int id) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. BACKGROUND WIDGET SYNCHRONIZATION HOOK
  try {
    await WidgetService.refreshWidgetData(); 
  } catch (_) {}

  // 2. TEXT NOTIFICATION ENGINE: Fires a system banner for every single prayer time
  try {
    final FlutterLocalNotificationsPlugin localNotif = FlutterLocalNotificationsPlugin();
    const AndroidInitializationSettings initSettingsAndroid = AndroidInitializationSettings('@mipmap/launcher_icon');
    await localNotif.initialize(const InitializationSettings(android: initSettingsAndroid));

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'shia_calendar_channel',
      'Prayer & Holy Events',
      description: 'Broadcasts prayer alerts and daily Islamic milestones.',
      importance: Importance.max,
    );
    await localNotif
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    String prayerLabel = "";
    if (id == 1001) prayerLabel = "الْفَجْر (Fajr)";
    if (id == 1002) prayerLabel = "الظُّهْر (Dhuhr)";
    if (id == 1003) prayerLabel = "الْعَصْر (Asr)";
    if (id == 1004) prayerLabel = "الْمَغْرِب (Maghrib)";
    if (id == 1005) prayerLabel = "الْعِشَاء (Isha)";

    if (prayerLabel.isNotEmpty) {
      String notificationBody = 'حان الآن موعد أذان $prayerLabel';

      if (id == 1004) {
        final DateTime upcomingIslamicDay = DateTime.now().add(const Duration(days: 1));
        final calendarData = HijriCalendarHelper.getHijriDateAndEvent(upcomingIslamicDay);
        final String targetedEvent = calendarData['event'] ?? "";
        if (targetedEvent.isNotEmpty) {
          notificationBody += '\nمناسبة اليوم: $targetedEvent';
        }
      }

      const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'shia_calendar_channel',
        'Prayer Alerts',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true, 
      );

      await localNotif.show(
        id, 
        'أوقات الصلاة',
        notificationBody,
        const NotificationDetails(android: androidDetails),
      );
    }
  } catch (_) {}

  // 3. AUDIO PLAYER MODULE: Restricted strictly to Fajr (ID: 1001)
  if (id == 1001) {
    final AudioPlayer player = AudioPlayer();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String selectedVoice = prefs.getString('selected_azan_voice') ?? 'zadeh';

      // CORRECTIONS APPLIED BELOW

      // FIX 1: Enforce physical stream utilization attributes onto the audio player instance
      await player.setAndroidAudioAttributes(const AndroidAudioAttributes(
        usage: AndroidAudioUsage.alarm, // Forces routing onto native hardware STREAM_ALARM
        contentType: AndroidAudioContentType.music,
      ));

      // FIX 2: Enforce audio session registration parameters and trigger activation loop
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        androidAudioAttributes: AndroidAudioAttributes(
          usage: AndroidAudioUsage.alarm,
          contentType: AndroidAudioContentType.music,
        ),
      ));
      await session.setActive(true); // Commits hardware channel priority mapping changes directly to the OS

      String fileName;
      switch (selectedVoice) {
        case 'ghalwash': fileName = 'adhan_ghalwash.mp3'; break;
        case 'ridhayan': fileName = 'adhan_ridhayan.mp3'; break;
        case 'alhalawaji': fileName = 'adhan_alhalawaji.mp3'; break;
        case 'tammar': fileName = 'adhan_maytham.mp3'; break;
        case 'ardabili': fileName = 'adhan_ardabili.m4a'; break;
        case 'zadeh':
        default: fileName = 'adhan_zadeh.mp3'; break;
      }

      final Directory docDir = await getApplicationDocumentsDirectory();
      final File localPlaybackFile = File('${docDir.path}/$fileName');
      
      if (await localPlaybackFile.exists()) {
        await player.setAudioSource(AudioSource.file(localPlaybackFile.path));
        await player.play();
        
        await Future.delayed(const Duration(minutes: 5));
        await player.stop();
      }
      await player.dispose();
    } catch (error, stackTrace) {
      print("!!! BACKGROUND ISOLATE AUDIO EXCEPTION: $error");
      print(stackTrace);
      player.dispose();
    }
  }
}