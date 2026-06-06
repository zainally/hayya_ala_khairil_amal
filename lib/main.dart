import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection; 
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'location_service.dart';
import 'prayer_time_service.dart';
import 'alarm_manager_service.dart';
import 'hijri_calendar_helper.dart';
import 'widget_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AlarmManagerService.initializeEngine();
  await AlarmManagerService.primeAudioCache();
  runApp(const HayyaAlaKhairilAmalApp());
}

// 🌟 GLOBAL HELPER METHOD: Safely stops background and preview audio streams
Future<void> globallyStopAzanPlayback(AudioPlayer? activeUiTestPlayer) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  
  // 1. Tell the background isolate executor loop to terminate immediately
  await prefs.setBool('is_azan_playing_now', false);
  
  // 2. Kill the foreground test player instance if it is active
  if (activeUiTestPlayer != null && activeUiTestPlayer.playing) {
    await activeUiTestPlayer.stop();
  }
}

class HayyaAlaKhairilAmalApp extends StatelessWidget {
  const HayyaAlaKhairilAmalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'أَوْقَاتُ الصَّلَاةِ الْجَعْفَرِيَّة',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.teal,
        useMaterial3: true,
      ),
      home: const PrayerDashboardScreen(),
    );
  }
}

class PrayerDashboardScreen extends StatefulWidget {
  const PrayerDashboardScreen({super.key});

  @override
  State<PrayerDashboardScreen> createState() => _PrayerDashboardScreenState();
}

class _PrayerDashboardScreenState extends State<PrayerDashboardScreen> {
  bool _isLoading = true;
  bool _isFajrAlarm = true; 
  int _hijriOffset = 0; 
  String _cityName = "جاري تحديد الموقع..."; 
  Map<String, DateTime> _prayerTimes = {};
  double? _lat;
  double? _lng;

  Timer? _countdownTimer;
  Timer? _livePlaybackChecker; // 🌟 Polling loop for active stop-button checks
  final ValueNotifier<bool> _isAzanCurrentlySounding = ValueNotifier<bool>(false);

  String _nextPrayerKey = "imsak";
  String _countdownText = "00:00:00";
  int _calculatedDay = DateTime.now().day;

  String _hijriDateStr = "";
  String _shiaEventStr = "";

  final Map<String, String> _prayerArabicNames = {
    'imsak': 'الْإِمْسَاك',
    'fajr': 'الْفَجْر',
    'sunrise': 'الشُّروق',
    'dhuhr': 'الظُّهْر',
    'asr': 'الْعَصْر',
    'maghrib': 'الْمَغْرِب',
    'isha': 'الْعِشَاء',
    'midnight': 'مُنْتَصَفُ اللَّيْل',
  };

  final Map<String, IconData> _prayerIcons = {
    'imsak': Icons.timer_outlined,
    'fajr': Icons.wb_twilight,
    'sunrise': Icons.wb_sunny_outlined,
    'dhuhr': Icons.wb_sunny,
    'asr': Icons.sunny,
    'maghrib': Icons.nightlight_round,
    'isha': Icons.nights_stay,
    'midnight': Icons.gavel,
  };

  final Map<String, int> _taqeebatTabsMap = {
    'fajr': 0,
    'dhuhr': 1,
    'asr': 2,
    'maghrib': 3,
    'isha': 4,
  };

  @override
  void initState() {
    super.initState();
    _loadPreferencesAndTimes();
    _startLivePlaybackListener();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _livePlaybackChecker?.cancel();
    _isAzanCurrentlySounding.dispose();
    super.dispose();
  }

  // 🌟 Real-time disk listener loop for state synchronizations
  void _startLivePlaybackListener() {
    _livePlaybackChecker = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final bool currentStatus = prefs.getBool('is_azan_playing_now') ?? false;
      if (_isAzanCurrentlySounding.value != currentStatus) {
        _isAzanCurrentlySounding.value = currentStatus;
      }
    });
  }

  Future<void> _loadPreferencesAndTimes() async {
    final FlutterLocalNotificationsPlugin notifPlugin = FlutterLocalNotificationsPlugin();
    await notifPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isFajrAlarm = prefs.getBool('is_fajr_alarm_on') ?? true;
        _hijriOffset = prefs.getInt('hijri_offset') ?? 0; 
      });
    }
    await _loadAndCalculateTimes();
  }

  Future<void> _toggleFajrAlarm(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_fajr_alarm_on', value);
    setState(() {
      _isFajrAlarm = value;
    });
    
    if (!value) {
      await AndroidAlarmManager.cancel(1001); 
    }
    await _loadAndCalculateTimes();
  }

  Future<void> _loadAndCalculateTimes() async {
    final coordinates = await LocationService.getSavedOrLiveLocation();
    final double targetLat = coordinates['latitude']!;
    final double targetLng = coordinates['longitude']!;

    final String resolvedCity = await LocationService.getCityName(targetLat, targetLng);
    final today = DateTime.now();

    final Map<String, DateTime> calculatedTimes = Map<String, DateTime>.from(
      PrayerTimeService.calculateJafariTimes(
        latitude: targetLat,
        longitude: targetLng,
        date: today,
      )
    );

    if (calculatedTimes.containsKey('fajr')) {
      calculatedTimes['imsak'] = calculatedTimes['fajr']!.subtract(const Duration(minutes: 10));
    }

    if (calculatedTimes.containsKey('maghrib') && calculatedTimes.containsKey('fajr')) {
      final DateTime maghribTime = calculatedTimes['maghrib']!;
      DateTime nextFajrTime = calculatedTimes['fajr']!;
      
      if (nextFajrTime.isBefore(maghribTime)) {
        nextFajrTime = nextFajrTime.add(const Duration(days: 1));
      }
      
      final Duration nightTotalDuration = nextFajrTime.difference(maghribTime);
      final DateTime shariMidnight = maghribTime.add(nightTotalDuration ~/ 2);
      
      calculatedTimes['midnight'] = shariMidnight;
    }

    final List<MapEntry<String, DateTime>> sortedEntriesList = calculatedTimes.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final Map<String, DateTime> structuredChronologicalTimes = {for (var e in sortedEntriesList) e.key: e.value};

    bool isCurrentlyAfterMaghrib = false;
    if (structuredChronologicalTimes.containsKey('maghrib')) {
      isCurrentlyAfterMaghrib = today.isAfter(structuredChronologicalTimes['maghrib']!);
    }
    
    final DateTime activeCalendarTarget = isCurrentlyAfterMaghrib 
        ? today.add(Duration(days: 1 + _hijriOffset)) 
        : today.add(Duration(days: _hijriOffset));
        
    final calendarData = HijriCalendarHelper.getHijriDateAndEvent(activeCalendarTarget);

    final Map<String, int> prayerAlarmIds = {
      'fajr': 1001,
      'dhuhr': 1002,
      'asr': 1003,
      'maghrib': 1004,
      'isha': 1005,
    };

    final now = DateTime.now();
    for (var entry in structuredChronologicalTimes.entries) {
      final prayerName = entry.key;
      final prayerTime = entry.value;

      if (prayerName == 'sunrise' || prayerName == 'midnight' || prayerName == 'imsak') continue;
      if (prayerName == 'fajr' && !_isFajrAlarm) continue; 

      if (prayerTime.isAfter(now)) {
        await AlarmManagerService.scheduleAzanAlarm(
          alarmId: prayerAlarmIds[prayerName]!,
          targetTime: prayerTime,
        );
      }
    }

    if (mounted) {
      setState(() {
        _lat = targetLat;
        _lng = targetLng;
        _cityName = resolvedCity;
        _prayerTimes = structuredChronologicalTimes; 
        _hijriDateStr = calendarData['formatted']!;
        _shiaEventStr = calendarData['event']!;
        _calculatedDay = today.day;
        _isLoading = false;
      });

      _startCountdownEngine();
      await WidgetService.refreshWidgetData(); 
    }
  }

  void _startCountdownEngine() {
    _countdownTimer?.cancel();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_prayerTimes.isEmpty) return;

      final now = DateTime.now();
      
      if (now.day != _calculatedDay) {
        _loadAndCalculateTimes();
        return; 
      }

      if (_prayerTimes.containsKey('maghrib')) {
        final bool checkAfterMaghrib = now.isAfter(_prayerTimes['maghrib']!);
        final DateTime liveTarget = checkAfterMaghrib 
            ? now.add(Duration(days: 1 + _hijriOffset)) 
            : now.add(Duration(days: _hijriOffset));
            
        final liveCalendar = HijriCalendarHelper.getHijriDateAndEvent(liveTarget);
        
        if (_hijriDateStr != liveCalendar['formatted'] || _shiaEventStr != liveCalendar['event']) {
          setState(() {
            _hijriDateStr = liveCalendar['formatted']!;
            _shiaEventStr = liveCalendar['event']!;
          });
        }
      }

      String? nextName;
      DateTime? nextTime;

      final targetPrayers = Map<String, DateTime>.from(_prayerTimes)..remove('sunrise');

      for (var entry in targetPrayers.entries) {
        if (entry.value.isAfter(now)) {
          if (nextTime == null || entry.value.isBefore(nextTime)) {
            nextTime = entry.value;
            nextName = entry.key;
          }
        }
      }

      if (nextTime == null) {
        nextName = _prayerTimes.containsKey('imsak') ? 'imsak' : 'fajr';
        nextTime = _prayerTimes[nextName]!.add(const Duration(days: 1));
      }

      final difference = nextTime.difference(now);
      final hours = difference.inHours.toString().padLeft(2, '0');
      final minutes = (difference.inMinutes % 60).toString().padLeft(2, '0');
      final seconds = (difference.inSeconds % 60).toString().padLeft(2, '0');

      if (mounted) {
        setState(() {
          _nextPrayerKey = nextName!;
          _countdownText = "$hours:$minutes:$seconds";
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final listTimeFormat = DateFormat('hh:mm a'); 
    final String currentArabicNextName = _prayerArabicNames[_nextPrayerKey] ?? "";
    
    final String countdownHeader = _nextPrayerKey == 'midnight' 
        ? 'مُنْتَصَفُ اللَّيْل (قَضَاء الْعِشَاء)' 
        : 'الْأَذَان التَّالِي: $currentArabicNextName';

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'أَوْقَاتُ الصَّلَاةِ الْجَعْفَرِيَّة',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18, color: Colors.white70, letterSpacing: 0.5),
        ),
        centerTitle: true,
        backgroundColor: Colors.black.withOpacity(0.5),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.tealAccent),
            tooltip: "Settings",
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
              _loadPreferencesAndTimes();
            },
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          Image.asset(
            'assets/images/karbala.jpg',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),
          Container(color: Colors.black.withOpacity(0.48)),
          
          _isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.tealAccent))
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Card(
                          color: Colors.black.withOpacity(0.4),
                          shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.white10, width: 0.5), borderRadius: BorderRadius.circular(8)),
                          child: Padding(
                            padding: const EdgeInsets.all(10.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.location_on, color: Colors.tealAccent, size: 18),
                                const SizedBox(width: 8),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Text(_cityName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                                    const SizedBox(height: 2),
                                    Text('Lat: ${_lat?.toStringAsFixed(4)} | Lng: ${_lng?.toStringAsFixed(4)}', style: const TextStyle(color: Colors.white60, fontSize: 10)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),

                        Card(
                          color: Colors.teal.shade900.withOpacity(0.25),
                          shape: RoundedRectangleBorder(side: BorderSide(color: Colors.teal.shade700, width: 0.5), borderRadius: BorderRadius.circular(8)),
                          child: Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Column(
                              children: [
                                Text(
                                  _hijriDateStr,
                                  textAlign: TextAlign.center,
                                  textDirection: TextDirection.rtl,
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.tealAccent),
                                ),
                                if (_shiaEventStr.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    _shiaEventStr,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.orangeAccent),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),

                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4.0),
                          child: Text(
                            'حَيَّ عَلَى خَيْرِ الْعَمَلِ',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: Colors.tealAccent),
                          ),
                        ),
                        const SizedBox(height: 4),

                        Card(
                          color: Colors.black.withOpacity(0.3),
                          shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.white10, width: 0.5), borderRadius: BorderRadius.circular(8)),
                          child: SwitchListTile(
                            title: const Text('أذان الفجر', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                            subtitle: const Text('Fajr Alarm Notification', style: TextStyle(fontSize: 12, color: Colors.white60)),
                            secondary: Icon(Icons.alarm, color: _isFajrAlarm ? Colors.tealAccent : Colors.white30),
                            value: _isFajrAlarm,
                            activeColor: Colors.tealAccent,
                            onChanged: _toggleFajrAlarm,
                          ),
                        ),
                        const SizedBox(height: 4),

                        Card(
                          elevation: 4,
                          color: Colors.black.withOpacity(0.55),
                          shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.teal, width: 1.0), borderRadius: BorderRadius.circular(10)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10.0),
                            child: Column(
                              children: [
                                Text(countdownHeader, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70)),
                                const SizedBox(height: 4),
                                Text(_countdownText, style: const TextStyle(fontSize: 38, fontWeight: FontWeight.bold, fontFamily: 'monospace', color: Colors.tealAccent)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),

                        // 🌟 DYNAMIC STOP CONSOLE PANEL BLOCK: Evaluates disk state and drops panic switch if active
                        ValueListenableBuilder<bool>(
                          valueListenable: _isAzanCurrentlySounding,
                          builder: (context, isSounding, child) {
                            if (!isSounding) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2.0),
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red.shade900.withOpacity(0.85),
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(color: Colors.redAccent, width: 1.0),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                icon: const Icon(Icons.stop_circle, color: Colors.white, size: 22),
                                label: const Text(
                                  'إيقاف الأذان (Stop Azan Playback)', 
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 0.3)
                                ),
                                onPressed: () async {
                                  await globallyStopAzanPlayback(null);
                                },
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 2),
                        
                        Expanded(
                          child: ListView(
                            padding: EdgeInsets.zero,
                            children: _prayerTimes.entries.map((entry) {
                              final String key = entry.key;
                              final String arabicTitle = _prayerArabicNames[key] ?? key.toUpperCase();
                              final String formattedTime = listTimeFormat.format(entry.value);
                              final bool isNext = (key == _nextPrayerKey);
                              final bool isMidnightRow = (key == 'midnight');
                              final IconData rowIcon = _prayerIcons[key] ?? Icons.access_time;

                              final bool hasTaqeebatLink = _taqeebatTabsMap.containsKey(key);

                              return Card(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                color: isNext 
                                    ? Colors.teal.shade900.withOpacity(0.6) 
                                    : (isMidnightRow ? Colors.red.shade900.withOpacity(0.2) : Colors.black.withOpacity(0.3)),
                                shape: RoundedRectangleBorder(
                                  side: BorderSide(
                                    color: isNext 
                                        ? Colors.tealAccent 
                                        : (isMidnightRow ? Colors.redAccent.withOpacity(0.2) : Colors.white10), 
                                    width: isNext ? 1.0 : 0.5
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.only(left: 16, right: 4, top: 2, bottom: 2),
                                  leading: Icon(
                                    rowIcon, 
                                    color: isNext 
                                        ? Colors.tealAccent 
                                        : (isMidnightRow ? Colors.redAccent.withOpacity(0.6) : Colors.teal.shade400),
                                    size: 20,
                                  ),
                                  title: Text(arabicTitle, style: TextStyle(fontSize: 16, fontWeight: isNext ? FontWeight.bold : FontWeight.w500, color: isNext ? Colors.tealAccent : (isMidnightRow ? Colors.white70 : Colors.white))),
                                  
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(formattedTime, style: TextStyle(fontSize: 15, fontWeight: isNext ? FontWeight.bold : FontWeight.w500, color: isNext ? Colors.tealAccent : Colors.white)),
                                      if (hasTaqeebatLink) ...[
                                        const SizedBox(width: 4),
                                        IconButton(
                                          icon: Icon(Icons.auto_stories, size: 18, color: isNext ? Colors.tealAccent : Colors.white60),
                                          tooltip: "View Taqeebat",
                                          onPressed: () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (context) => TaqeebatScreen(initialIndex: _taqeebatTabsMap[key]!),
                                              ),
                                            );
                                          },
                                        ),
                                      ] else ...[
                                        const SizedBox(width: 44), 
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),

                        Padding(
                          padding: const EdgeInsets.only(top: 6.0, bottom: 4.0),
                          child: Column(
                            children: [
                              Text(
                                'Developed by Zain Ally & Google Gemini',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w400, color: Colors.white.withOpacity(0.4), letterSpacing: 0.8),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Version 2.0.4', // 🌟 BUMPED INCREMENT COMPLIANCE METADATA TARGET
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.tealAccent.withOpacity(0.5), letterSpacing: 1.0),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

class TaqeebatScreen extends StatelessWidget {
  final int initialIndex;
  
  const TaqeebatScreen({super.key, this.initialIndex = 0});

  Widget _buildCommonTasbihSection() {
    return Card(
      color: Colors.teal.shade900.withOpacity(0.15),
      shape: RoundedRectangleBorder(side: BorderSide(color: Colors.teal.shade700, width: 0.5), borderRadius: BorderRadius.circular(8)),
      margin: const EdgeInsets.only(bottom: 16),
      child: const Padding(
        padding: EdgeInsets.all(12.0),
        child: Column(
          children: [
            Text('تَسْبِيح فَاطِمَةَ الزَّهْرَاءِ (عليها السلام)', style: TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 14)),
            SizedBox(height: 6),
            Text(
              '٣٤ مرّة: اللَّهُ أَكْبَرُ\n٣٣ مرّة: الْحَمْدُ لِلَّهِ\n٣٣ مرّة: سُبْحَانَ اللَّهِ',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, height: 1.5, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScrollablePrayerText(List<Widget> children) {
    return ListView(
      padding: const EdgeInsets.all(14.0),
      children: [
        _buildCommonTasbihSection(),
        ...children,
      ],
    );
  }

  Widget _buildDuaCard({
    required String titleEnglish, 
    required String arabicText, 
    required String transliterationText, 
    required String translationText
  }) {
    return Card(
      color: Colors.black.withOpacity(0.3),
      shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.white10), borderRadius: BorderRadius.circular(8)),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(titleEnglish, style: const TextStyle(fontSize: 12, color: Colors.tealAccent, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
            const Divider(color: Colors.white10, height: 16),
            Text(
              arabicText,
              textDirection: TextDirection.rtl,
              style: const TextStyle(fontSize: 18, height: 1.8, color: Colors.white, fontFamily: 'serif', letterSpacing: 0.2),
            ),
            const SizedBox(height: 12),
            Text(
              transliterationText,
              style: TextStyle(fontSize: 13, height: 1.5, color: Colors.teal.shade200, fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 12),
            Text(
              translationText,
              style: const TextStyle(fontSize: 13, height: 1.5, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      initialIndex: initialIndex,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تعقيبات الصلوات العامة', style: TextStyle(fontSize: 16, color: Colors.white70)),
          backgroundColor: const Color(0xFF121212),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.tealAccent),
            onPressed: () => Navigator.pop(context),
          ),
          bottom: const TabBar(
            isScrollable: true,
            indicatorColor: Colors.tealAccent,
            labelColor: Colors.tealAccent,
            unselectedLabelColor: Colors.white38,
            labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            tabs: [
              Tab(text: "Fajr"),
              Tab(text: "Dhuhr"),
              Tab(text: "Asr"),
              Tab(text: "Maghrib"),
              Tab(text: "Isha"),
            ],
          ),
        ),
        body: Container(
          color: const Color(0xFF121212),
          child: TabBarView(
            children: [
              // 1. FAJR TAQEEBAT
              _buildScrollablePrayerText([
                _buildDuaCard(
                  titleEnglish: "Post-Fajr Supplication",
                  arabicText: "اَللَّهُمَّ إِنِّي أَسْأَلُكَ بِحَقِّ مُحَمَّدٍ وَآلِ مُحَمَّدٍ عَلَيْكَ\n"
                      "صَلِّ عَلَىٰ مُحَمَّدٍ وَآلِ مُحَمَّدٍ\n"
                      "وَٱجْعَلِ ٱلنُّورَ فِي بَصَرِي\n"
                      "وَٱلْبَصِيرَةَ فِي دِينِي\n"
                      "وَٱلْيَقِينَ فِي قَلْبِي\n"
                      "وَٱلإِخْلاَصَ فِي عَمَلِي\n"
                      "وَٱالسَّلَامَةَ فِي نَفْسِي\n"
                      "وَٱالسَّعَةَ فِي رِزْقِي\n"
                      "وَٱلشُّكْرَ لَكَ أَبَداً مَا أَبْقَيْتَنِي",
                  transliterationText: "allahumma inni as'aluka bihaqqi muhammadin wa ali muhammadin `alayka\n"
                      "salli `ala muhammadin wa ali muhammadin\n"
                      "waj`al alnnura fi basari\n"
                      "walbasirata fi dini\n"
                      "wal-yaqina fi qalbi\n"
                      "wal-ikhlasa fi `amali\n"
                      "walssalamata fi nafsi\n"
                      "walssa`ata fi rizqi\n"
                      "walshshukra laka abadan ma abqaytani",
                  translationText: "O Allah, I do beseech You, in the name of the right of Muhammad and the Household of Muhammad that is incumbent upon You\n"
                      "to send blessings to Muhammad and the Household of Muhammad\n"
                      "and to give light to my insight,\n"
                      "make me discerning in my religion,\n"
                      "have conviction in my heart,\n"
                      "sincerity in my deeds,\n"
                      "safety in my self,\n"
                      "vastness in my sustenance,\n"
                      "and perpetual thankfulness for You as long as you keep me alive.",
                ),
              ]),

              // 2. DHUHR TAQEEBAT
              _buildScrollablePrayerText([
                _buildDuaCard(
                  titleEnglish: "Post-Dhuhr Protection Supplication",
                  arabicText: "لاَ إِلٰهَ إِلاَّ ٱللَّهُ ٱلْعَظِيمُ ٱلْحَلِيمُ\n"
                      "لاَ إِلٰهَ إِلاَّ ٱللَّهُ رَبُّ ٱلْعَرْشِ ٱلْكَرِي-مِ\n"
                      "اَلْحَمْدُ لِلَّهِ رَبِّ ٱلْعَالَمينَ\n"
                      "اَللَّهُمَّ إِنِّي أَسْأَلُكَ مُوجِبَاتِ رَحْمَتِكَ\n"
                      "وَعَزَائِمَ مَغْفِرَتِكَ\n"
                      "وَٱلْغَنيمَةَ مِنْ كُلِّ بِرِّ\n"
                      "وَٱالسَّلَامَةَ مِنْ كُلِّ إِثْمٍ\n"
                      "اَللَّهُمَّ لاَ تَدَعْ لِي ذَنْباً إِلاَّ غَفَرْتَهُ\n"
                      "وَلاَ هَمّاً إِلاَّ فَرَّجْتَهُ\n"
                      "وَلاَ سُقْماً إِلاَّ شَفَيْتَهُ\n"
                      "وَلاَ عَيْباً إِلاَّ سَتَرْتَهُ\n"
                      "وَلاَ رِزْقاً إِلاَّ بَسَطْتَهُ\n"
                      "وَلاَ خَوْفاً إِلاَّ آمَنْتَهُ\n"
                      "وَلاَ سُوءاً إِلاَّ صَرَفْتَهُ\n"
                      "وَلاَ حَاجَةً هِيَ لَكَ رِضاً وَلِيَ فيهَا صَلاَحٌ إِلاَّ قَضَيْتَهَا\n"
                      "يَا أَرْحَمَ ٱلرَّاحِمينَ\n"
                      "آمينَ رَبَّ ٱلْعَالَمينَ",
                  transliterationText: "la ilaha illa allahu al`azimu alhalimu\n"
                      "la ilaha illa allahu rabbu al`arshi alkarimu\n"
                      "alhamdu lillahi rabbi al`alamina\n"
                      "allahumma inni as'aluka mujibati rahmatika\n"
                      "wa `aza'ima maghfiratika\n"
                      "walghanimata min kulli birrin\n"
                      "walssalamata min kulli ithmin\n"
                      "allahumma la tada` li dhanban illa ghafartahu\n"
                      "wa la hamman illa farrajtahu\n"
                      "wa la suqman illa shafaytahu\n"
                      "wa la `ayban illa satartahu\n"
                      "wa la rizqan illa basattahu\n"
                      "wa la khawfan illa amantahu\n"
                      "wa la su'an illa saraftahu\n"
                      "wa la hajatan hiya laka ridan wa liya fiha salahun illa qadaytaha\n"
                      "ya arhama alrrahimina\n"
                      "amina rabba al`alamina",
                  translationText: "There is no god save Allah, the All-great and Most Forbearing.\n"
                      "There is no god save Allah, the Lord of the Throne of Honor.\n"
                      "All praise be to Allah, the Lord of the worlds.\n"
                      "O Allah, I ask You for the motives of Your mercy,\n"
                      "the determining causes of Your forgiveness,\n"
                      "the advantage of each act of kindness,\n"
                      "and the safeguarding against each and every sin.\n"
                      "O Allah, (please) do not leave any of my offenses unforgiven,\n"
                      "any of my misfortunes unrelieved,\n"
                      "any of my ailments unhealed,\n"
                      "any of my defects uncovered,\n"
                      "any (item of my) sustenance not including (me),\n"
                      "any fear (that I experience) unsecured,\n"
                      "any evil (that comes upon me) uncontrollable,\n"
                      "and any need that achieves Your satisfaction and my benefit unanswered.\n"
                      "O most Merciful of all those who show mercy.\n"
                      "(please) Respond, O Lord of the worlds.",
                ),
              ]),

              // 3. ASR TAQEEBAT
              _buildScrollablePrayerText([
                _buildDuaCard(
                  titleEnglish: "Post-Asr Submission Supplication",
                  arabicText: "أَسْتَغْفِرُ ٱللَّهَ ٱلَّذِي لاَ إِلٰهَ إِلاَّ هُوَ\n"
                      "ٱلْحَيُّ ٱلْقَيُّومُ\n"
                      "ٱلرَّحْمٰنُ ٱلرَّحِيمُ\n"
                      "ذُو ٱلْجَلاَلِ وَٱلإِكْرَامِ\n"
                      "وَ أَسْأَلُهُ أَنْ يَتُوبَ عَلَيَّ\n"
                      "تَوْبَةَ عَبْدٍ ذَلِيلٍ خَاضِعٍ\n"
                      "فَقِيرٍ بَائِسٍ\n"
                      "مِسْكِينٍ مُسْتَكِينٍ مُسْتَجِيرٍ\n"
                      "لاَ يَمْلِكُ لِنَفْسِهِ نَفْعَاً وَلاَ ضَرّاً\n"
                      "وَلاَ مَوْتاً وَلاَ حَيَاةً وَلاَ نُشُوراً",
                  transliterationText: "astaghfiru allaha alladhi la ilaha illa huwa\n"
                      "alhayyu alqayyumu\n"
                      "alrrahmani alrrahimu\n"
                      "dhu aljalali wal-ikrami\n"
                      "wa as'aluhu an yatuba `alayya\n"
                      "tawbata `abdin dhalilin khadi`in\n"
                      "faqirin ba'isin\n"
                      "miskinin mustakinin mustajirin\n"
                      "la yamliku linafsihi naf`an wa la darran\n"
                      "wa la mawtan wa la hayatan wa la nushuran",
                  translationText: "I pray the forgiveness of Allah; there is no god save Him,\n"
                      "the Ever-living, the Self-Subsisting,\n"
                      "the All-compassionate, the All-merciful,\n"
                      "and the Lord of Majesty and Honor.\n"
                      "And I ask Him to accept my repentance,\n"
                      "like His acceptance of the repentance of a slave who is submissive, acquiescent,\n"
                      "poor, miserable,\n"
                      "despondent, dejected, seeking refuge (with Him),\n"
                      "not controlling for himself any harm or profit,\n"
                      "and not controlling death nor life nor raising (the dead) to life.",
                ),
              ]),

              // 4. MAGHRIB TAQEEBAT
              _buildScrollablePrayerText([
                _buildDuaCard(
                  titleEnglish: "Post-Maghrib Supplication",
                  arabicText: "اللَّهُمَّ إِنِّي أَسْأَلُكَ مُوجِبَاتِ رَحْمَتِكَ\n"
                      "وَعَزَائِمِ مَغْفِرَتِكَ\n"
                      "وَٱالنَّجَاةَ مِنَ ٱلنَّارِ وَمِنْ كُلِّ بَلِيَّةٍ\n"
                      "وَٱلْفَوْزَ بِٱلْجَنَّةِ وَٱلرِّضْوَانَ في دَارِ ٱلسَّلاَمِ\n"
                      "وَجَوَارِ نَبِيِّكَ مُحَمَّدٍ عَلَيْهِ وَآلِهِ ٱلسَّلاَمُ\n"
                      "اَللَّهُمَّ مَا بِنَا مِنْ نِعْمَةٍ فَمِنْكَ\n"
                      "لاَ إِلٰهَ إِلاَّ أَنْتَ\n"
                      "أَسْتَغْفِرُكَ وَ أَتُوبُ إِلَيْكَ",
                  transliterationText: "allahumma inni as'aluka mujibati rahmatika\n"
                      "wa `aza'ima maghfiratika\n"
                      "walnnajata mina alnnari wa min kulli baliyyatin\n"
                      "walfawza biljannati walrridwani fi dari alssalami\n"
                      "wa jiwari nabiyyika muhammadin `alayhi wa alihi alssalamu\n"
                      "allahumma ma bina min ni`matin faminka\n"
                      "la ilaha illa anta\n"
                      "astaghfiruka wa atubu ilayka",
                  translationText: "O Allah! I beseech You for the motives of Your mercy,\n"
                      "the determining causes of Your forgiveness,\n"
                      "deliverance from Hellfire and all misfortunes,\n"
                      "winning Paradise,Divine Contentment in the Abode of Peace,\n"
                      "and the vicinity of Your Prophet Muhammad—peace be upon him and his Household.\n"
                      "O Allah, You are certainly the source of each and every favor that covers us.\n"
                      "There is no god save You.\n"
                      "I pray Your forgiveness and I repent before You.",
                ),
              ]),

              // 5. ISHA TAQEEBAT
              _buildScrollablePrayerText([
                _buildDuaCard(
                  titleEnglish: "Sustenance Expansion Supplication (Rizq)",
                  arabicText: "اَللَّهُمَّ إِنَّهُ لَيْسَ لِي عِلْمٌ بِمَوَاضِعِ رِزْقِي\n"
                      "وَإِنَّمَا أَطْلُبُهُ بِخَطَرَاتٍ تَخْطُرُ عَلَىٰ قَلْبِي\n"
                      "فَأَنَا فِي طَلَبِهِ ٱلْبُلْدَانَ\n"
                      "فَأَنَا فِيمَا أَنَا طَالِبٌ كَٱلْحَيْرَانِ\n"
                      "لاَ إِدْرِي أَفِي سَهْلٍ هُوَ أَمْ فِي جَبَلٍ\n"
                      "أَمْ فِي أَرْضٍ أَمْ فِي سَمَاءٍ\n"
                      "أَمْ فِي بَرٍّ أَمْ فِي بَحْرٍ\n"
                      "وَعَلَىٰ يَدَيْ مَنْ وَمِنْ قِبَلِ مَنْ\n"
                      "وَقَدْ عَلِمْتُ أَنَّ عِلْمَهُ عِنْدَكَ\n"
                      "وَأَسْبَابَهُ بِيَدِكَ\n"
                      "وَأَنْتَ ٱلَّذِي تَقْسِمُهُ بِلطْفِكَ\n"
                      "وَتُسَبِّبُهُ بِرَحْمَتِكَ\n"
                      "اَللَّهُمَّ فَصَلِّ عَلَىٰ مُحَمَّدٍ وَآلِهِ\n"
                      "وَٱجْعَلْ يَا رَبِّ رِزْقَكَ لِي وَاسِعاً\n"
                      "وَمَطْلَبَهُ سَهْلاً\n"
                      "وَمَأْخَذَهُ قَرِيباً\n"
                      "وَلاَ تُعَنِّني بِطَلَبِ مَا لَمْ تُقَدِّرْ لِي فِيهِ رِزْقاً\n"
                      "فَإِنَّكَ غَنِيٌّ عَنْ عَذَابِي\n"
                      "وَأَنَا فَقِيرٌ إِلَىٰ رَحْمَتِكَ\n"
                      "فَصَلِّ عَلَىٰ مُحَمَّدٍ وَآلِهِ\n"
                      "وَجُدْ عَلَىٰ عَبْدِكَ بِفَضْلِكَ\n"
                      "إِنَّكَ ذُو فَضْلٍ عَظِيمٍ",
                  transliterationText: "allahumma innahu laysa li `ilmun bimawadi`i rizqi\n"
                      "wa innma atlubuhu bikhataratin takhturu `ala qalbi\n"
                      "fa-ajulu fi talabihu albuldana\n"
                      "fa-ana fima ana talibun kalhayrani\n"
                      "la adri afi sahlin huwa am fi jabalin\n"
                      "am fi ardin am fi sama'in\n"
                      "am fi barrin am fi bahrin\n"
                      "wa `ala yaday man\n"
                      "wa min qibali man\n"
                      "wa qad `alimtu anna `ilmahu `indaka\n"
                      "wa asbabahu biyadika\n"
                      "wa anta alladhi taqsimuhu bilutfika\n"
                      "wa tusabbibuhu birahmatika\n"
                      "allahumma fasalli `ala muhammadin wa alihi\n"
                      "waj`al ya rabbi rizqaka li wasi`an\n"
                      "wa matlabahu sahlan\n"
                      "wa ma'khadhahu qariban\n"
                      "wa la tu`annini bitalbi ma lam tuqaddiru li fihi rizqan\n"
                      "fa'innaka ghaniyyun `an `adhabi\n"
                      "wa ana faqirun ila rahmatika\n"
                      "fasalli `ala muhammadin wa alihi\n"
                      "wa jud `ala `abdika bifadlika\n"
                      "innaka dhu fadlin `azimin",
                  translationText: "O Allah! verily, I lack acquaintance with the place of my sustenance;\n"
                      "rather, I am seeking it owing to ideas that come upon my mind.\n"
                      "I consequently wander in countries searching for it.\n"
                      "By doing such, I am as confused as the confounded,\n"
                      "since I do not know whether my sustenance lies in a plain, on a mountain,\n"
                      "on the ground, in the air,\n"
                      "on lands, in seas,\n"
                      "at whose hands,\n"
                      "or who the source of it is.\n"
                      "I have full knowledge that You know all these,\n"
                      "the causes of them are in Your Hands,\n"
                      "and it is You Who distribute it out of Your compassion\n"
                      "and cause it out of Your mercy.\n"
                      "O Allah, please send blessings to Muhammad and his Household\n"
                      "and make, O Lord, Your sustenance that is provided (by You) to me expansive,\n"
                      "my seeking for it easy for me,\n"
                      "and its source close to me.\n"
                      "Please, do not fatigue me by seeking that which You have not decided for me to take,\n"
                      "because You are certainly in no need for tormenting me\n"
                      "while I am in full need for Your mercy.\n"
                      "(Please) Send blessings upon Muhammad and his Household\n"
                      "and confer liberally upon me, Your slave, out of Your graciousness.\n"
                      "You are surely the Lord of great favor.",
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _selectedVoice = "zadeh";
  int _hijriOffset = 0;
  AudioPlayer? _testPlayer;
  bool _isTestingAudio = false;

  bool _useManualLocation = false;
  String _selectedCityKey = "karachi";

  int _testDelaySeconds = 30; 

  final Map<String, String> _voiceLabels = {
    'zadeh': 'Moazenzadeh Ardabili',
    'ghalwash': 'Raghib Mustafa Ghalwash',
    'ridhayan': 'Hussein Ridhayan',
    'alhalawaji': 'Abaather Al-Halawaji',
    'ardabili': 'Shaikh Ardabili',
    'tammar': 'Maytham Al Tammar',
  };

  final Map<String, Map<String, dynamic>> _presetCities = {
    'abu_dhabi': {'name': 'Abu Dhabi (أبو ظبي)', 'lat': 24.4539, 'lng': 54.3773},
    'abuja': {'name': 'Abuja (أبوجا)', 'lat': 9.0765, 'lng': 7.3986},
    'amman': {'name': 'Amman (عمان)', 'lat': 31.9454, 'lng': 35.9284},
    'ankara': {'name': 'Ankara (أنقرة)', 'lat': 39.9334, 'lng': 32.8597},
    'ashgabat': {'name': 'Ashgabat (عشق آباد)', 'lat': 37.9601, 'lng': 58.3260},
    'astana': {'name': 'Astana (أستانا)', 'lat': 51.1605, 'lng': 71.4704},
    'baghdad': {'name': 'Baghdad (بغداد)', 'lat': 33.3152, 'lng': 44.3661},
    'baku': {'name': 'Baku (باكو)', 'lat': 40.4093, 'lng': 49.8671},
    'bamako': {'name': 'Bamako (باماكو)', 'lat': 12.6392, 'lng': -8.0029},
    'bandar_seri_begawan': {'name': 'Bandar Seri Begawan (بندر سري بكاوان)', 'lat': 4.9031, 'lng': 114.9398},
    'beirut': {'name': 'Beirut (بيروت)', 'lat': 33.8938, 'lng': 35.5018},
    'bishkek': {'name': 'Bishkek (بشكيك)', 'lat': 42.8746, 'lng': 74.5698},
    'cairo': {'name': 'Cairo (القاهرة)', 'lat': 30.0444, 'lng': 31.2357},
    'chicago': {'name': 'Chicago (شيكاغو)', 'lat': 41.8781, 'lng': -87.6298},
    'conakry': {'name': 'Conakry (كوناكري)', 'lat': 9.6412, 'lng': -13.5784},
    'daakar': {'name': 'Dakar (داكار)', 'lat': 14.7167, 'lng': -17.4677},
    'damascus': {'name': 'Damascus (دمشق)', 'lat': 33.5138, 'lng': 36.2765},
    'dhaka': {'name': 'Dhaka (دكا)', 'lat': 23.8103, 'lng': 90.4125},
    'djibouti': {'name': 'Djibouti (جيبوتي)', 'lat': 11.5884, 'lng': 43.1450},
    'doha': {'name': 'Doha (الدوحة)', 'lat': 25.2854, 'lng': 51.5310},
    'dhuashanbe': {'name': 'Dushanbe (دوشانبي)', 'lat': 38.5598, 'lng': 68.7870},
    'dubai': {'name': 'Dubai (دبي)', 'lat': 25.2048, 'lng': 55.2708},
    'freetown': {'name': 'Freetown (فريتاون)', 'lat': 8.4844, 'lng': -13.2344},
    'houston': {'name': 'Houston (هيوسطن)', 'lat': 29.7604, 'lng': -95.3698},
    'islamabad': {'name': 'Islamabad (إسلام آباد)', 'lat': 33.6844, 'lng': 73.0479},
    'jakarta': {'name': 'Jakarta (جاكرتا)', 'lat': -6.2088, 'lng': 106.8456},
    'jiddah': {'name': 'Jeddah (جدة)', 'lat': 21.5433, 'lng': 39.1728},
    'kabul': {'name': 'Kabul (كابل)', 'lat': 34.5553, 'lng': 69.1779},
    'kampala': {'name': 'Kampala (كامبالا)', 'lat': 0.3476, 'lng': 32.5825},
    'karachi': {'name': 'Karachi (كراتشي)', 'lat': 24.8607, 'lng': 67.0011},
    'karbala': {'name': 'Karbala (كربلاء المقدسة)', 'lat': 32.6160, 'lng': 44.0248},
    'khartoum': {'name': 'Khartoum (الخرطوم)', 'lat': 15.5007, 'lng': 32.5599},
    'kuala_lumpur': {'name': 'Kuala Lumpur (كوالالمبور)', 'lat': 3.1390, 'lng': 101.6869},
    'kuwait_city': {'name': 'Kuwait City (مدينة الكويت)', 'lat': 29.3759, 'lng': 47.9774},
    'london': {'name': 'London (لندن)', 'lat': 51.5074, 'lng': -0.1278},
    'los_angeles': {'name': 'Los Angeles (لوس أنجلوس)', 'lat': 34.0522, 'lng': -118.2437},
    'male': {'name': 'Malé (ماليه)', 'lat': 4.1755, 'lng': 73.5093},
    'manama': {'name': 'Manama (المنامة)', 'lat': 26.2285, 'lng': 50.5860},
    'mogadishu': {'name': 'Mogadishu (مقديشو)', 'lat': 2.0408, 'lng': 45.3426},
    'moroni': {'name': 'Moroni (موروني)', 'lat': -11.7022, 'lng': 43.2551},
    'muscat': {'name': 'Muscat (مسقط)', 'lat': 23.5859, 'lng': 58.4059},
    'najaf': {'name': 'Najaf (النجف الأشرَف)', 'lat': 31.9959, 'lng': 44.3516},
    'ndjamena': {'name': 'N\'Djamena (انجامينا)', 'lat': 12.1348, 'lng': 15.0557},
    'new_york': {'name': 'New York (نيويورك)', 'lat': 40.7128, 'lng': -74.0060},
    'niamey': {'name': 'Niamey (نيامي)', 'lat': 13.5116, 'lng': 2.1254},
    'nouakchott': {'name': 'Nouakchott (نواكشوط)', 'lat': 18.0835, 'lng': -15.9785},
    'ouagadougou': {'name': 'Ouagadوغو)', 'lat': 12.3714, 'lng': -1.5197},
    'phoenix': {'name': 'Phoenix (فينيكس)', 'lat': 33.4484, 'lng': -112.0740},
    'rabat': {'name': 'Rabat (الرباط)', 'lat': 34.0209, 'lng': -6.8416},
    'riyadh': {'name': 'Riyadh (الرياض)', 'lat': 24.7136, 'lng': 46.6753},
    'sanaa': {'name': 'Sana\'a (صنعاء)', 'lat': 15.3694, 'lng': 44.1910},
    'sarajevo': {'name': 'Sarajevo (سراييفو)', 'lat': 43.8563, 'lng': 18.4131},
    'tashkent': {'name': 'Tashkent (طشقند)', 'lat': 41.2995, 'lng': 69.2401},
    'tehran': {'name': 'Tehran (طهران)', 'lat': 35.6892, 'lng': 51.3890},
    'toronto': {'name': 'Toronto (تورونتو)', 'lat': 43.6532, 'lng': -79.3832},
    'tripoli': {'name': 'Tripoli (طرابلس)', 'lat': 32.8872, 'lng': 13.1913},
    'tunis': {'name': 'Tunis (تونس)', 'lat': 36.8065, 'lng': 10.1815},
    'washington_dc': {'name': 'Washington D.C. (واشنطن)', 'lat': 38.9072, 'lng': -77.0369},
  };

  @override
  void initState() {
    super.initState();
    _testPlayer = AudioPlayer();
    _loadSettings();
  }

  @override
  void dispose() {
    _testPlayer?.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedVoice = prefs.getString('selected_azan_voice') ?? 'zadeh';
      _hijriOffset = prefs.getInt('hijri_offset') ?? 0;
      _useManualLocation = prefs.getBool('use_manual_location') ?? false;
      
      String savedCity = prefs.getString('selected_city_key') ?? 'karachi';
      _selectedCityKey = _presetCities.containsKey(savedCity) ? savedCity : 'karachi';
    });
  }

  Future<void> _updateVoicePreference(String? newVoice) async {
    if (newVoice == null) return;
    if (_isTestingAudio) await _toggleAzanTest();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_azan_voice', newVoice);
    setState(() => _selectedVoice = newVoice);
  }

  Future<void> _updateHijriOffset(int shiftAmount) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('hijri_offset', shiftAmount);
    setState(() => _hijriOffset = shiftAmount);
  }

  Future<void> _toggleManualLocation(bool targetValue) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_manual_location', targetValue);
    setState(() {
      _useManualLocation = targetValue;
    });
    await _saveSelectedCityCoordinates(_selectedCityKey);
  }

  Future<void> _updateSelectedCity(String? cityKey) async {
    if (cityKey == null) return;
    setState(() => _selectedCityKey = cityKey);
    await _saveSelectedCityCoordinates(cityKey);
  }

  Future<void> _saveSelectedCityCoordinates(String cityKey) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final cityData = _presetCities[cityKey]!;
    await prefs.setString('selected_city_key', cityKey);
    await prefs.setString('manual_city_name', cityData['name']);
    await prefs.setDouble('manual_lat', cityData['lat']);
    await prefs.setDouble('manual_lng', cityData['lng']);
  }

  Future<void> _executeIsolateBackgroundTest() async {
    final DateTime targetTriggerTime = DateTime.now().add(Duration(seconds: _testDelaySeconds));
    
    await AlarmManagerService.scheduleAzanAlarm(
      alarmId: 1001, 
      targetTime: targetTriggerTime,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.teal.shade800,
          content: Text(
            'Test Scheduled in $_testDelaySeconds seconds. Please lock your device now.',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  // 🌟 SIMULATED ALARM AUDIO PREVIEW: Forces hardware routing over physical alarm channels
  Future<void> _toggleAzanTest() async {
    if (_isTestingAudio) {
      await globallyStopAzanPlayback(_testPlayer);
      setState(() => _isTestingAudio = false);
    } else {
      setState(() => _isTestingAudio = true);
      
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_azan_playing_now', true);

      String assetPath;
      switch (_selectedVoice) {
        case 'ghalwash': assetPath = 'assets/audio/adhan_ghalwash.mp3'; break;
        case 'ridhayan': assetPath = 'assets/audio/adhan_ridhayan.mp3'; break;
        case 'alhalawaji': assetPath = 'assets/audio/adhan_alhalawaji.mp3'; break;
        case 'tammar': assetPath = 'assets/audio/adhan_maytham.mp3'; break;
        case 'ardabili': assetPath = 'assets/audio/adhan_ardabili.m4a'; break;  
        case 'zadeh':
        default: assetPath = 'assets/audio/adhan_zadeh.mp3'; break;
      }

      try {
        // Enforce physical alarm stream routing parameters onto the preview player memory map
        await _testPlayer?.setAndroidAudioAttributes(const AndroidAudioAttributes(
          usage: AndroidAudioUsage.alarm, // Directs engine output straight into STREAM_ALARM
          contentType: AndroidAudioContentType.music,
        ));

        // Enforce active priority linkage overrides directly onto the native device thread session
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration(
          androidAudioAttributes: AndroidAudioAttributes(
            usage: AndroidAudioUsage.alarm,
            contentType: AndroidAudioContentType.music,
          ),
        ));
        await session.setActive(true); // Commits structural stream linkage updates to drop silent/vibrate switches

        await _testPlayer?.setAudioSource(AudioSource.asset(assetPath));
        _testPlayer?.play();
        _testPlayer?.playerStateStream.listen((state) async {
          if (state.processingState == ProcessingState.completed && mounted && _isTestingAudio) {
            await prefs.setBool('is_azan_playing_now', false);
            setState(() => _isTestingAudio = false);
          }
        });
      } catch (e) {
        print("!!! Native Audio Testing Instantiation Fault: $e");
        await prefs.setBool('is_azan_playing_now', false);
        setState(() => _isTestingAudio = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final String currentReciterLabel = _voiceLabels[_selectedVoice] ?? "Moazenzadeh Ardabili";

    return Scaffold(
      appBar: AppBar(
        title: const Text('الإعدادات (Settings)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18, color: Colors.white70)),
        centerTitle: true,
        backgroundColor: Colors.black.withOpacity(0.8),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.tealAccent),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        color: const Color(0xFF121212),
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            Card(
              color: Colors.black.withOpacity(0.3),
              shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.redAccent, width: 0.5), borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.all(14.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.science, color: Colors.redAccent, size: 20), 
                        SizedBox(width: 8),
                        Text('فحص المنظومة (Isolate Background Test)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white70)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Verifies if your device processes alarm intents and runs native files successfully while hidden. Set a delay, tap schedule, and turn off your screen instantly.',
                      style: TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _testDelaySeconds,
                            dropdownColor: const Color(0xFF1E1E1E),
                            decoration: InputDecoration(
                              labelText: "Execution Delay",
                              labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.white24), borderRadius: BorderRadius.circular(8)),
                              focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.tealAccent), borderRadius: BorderRadius.circular(8)),
                            ),
                            items: const [
                              DropdownMenuItem(value: 30, child: Text("30 Seconds", style: TextStyle(fontSize: 14))),
                              DropdownMenuItem(value: 60, child: Text("1 Minute", style: TextStyle(fontSize: 14))),
                              DropdownMenuItem(value: 120, child: Text("2 Minutes", style: TextStyle(fontSize: 14))),
                            ],
                            onChanged: (val) {
                              if (val != null) setState(() => _testDelaySeconds = val);
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton(
                          onPressed: _executeIsolateBackgroundTest,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade900.withOpacity(0.4),
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.redAccent, width: 0.8),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text('Schedule', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            Card(
              color: Colors.black.withOpacity(0.3),
              shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.white10, width: 0.5), borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.all(14.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.map_outlined, color: Colors.tealAccent, size: 20),
                        SizedBox(width: 8),
                        Text('موقع يدوي (Manual Location Profile)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white70)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Enable Fixed City Override', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                      subtitle: const Text('Bypasses the phone\'s live GPS tracking entirely.', style: TextStyle(fontSize: 11, color: Colors.white38)),
                      value: _useManualLocation,
                      activeColor: Colors.tealAccent,
                      onChanged: _toggleManualLocation,
                    ),
                    if (_useManualLocation) ...[
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        value: _selectedCityKey,
                        dropdownColor: const Color(0xFF1E1E1E),
                        isExpanded: true,
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.white24), borderRadius: BorderRadius.circular(8)),
                          focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.tealAccent), borderRadius: BorderRadius.circular(8)),
                        ),
                        items: _presetCities.entries.map((entry) {
                          return DropdownMenuItem<String>(
                            value: entry.key,
                            child: Text(entry.value['name'], style: const TextStyle(fontSize: 14), overflow: TextOverflow.ellipsis),
                          );
                        }).toList(),
                        onChanged: _updateSelectedCity,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            Card(
              color: Colors.black.withOpacity(0.3),
              shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.white10, width: 0.5), borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.all(14.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.record_voice_over, color: Colors.tealAccent, size: 20),
                        SizedBox(width: 8),
                        Text('صوت الأذان (Azan Voice Selection)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white70)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _selectedVoice,
                      dropdownColor: const Color(0xFF1E1E1E),
                      decoration: InputDecoration(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.white24), borderRadius: BorderRadius.circular(8)),
                        focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.tealAccent), borderRadius: BorderRadius.circular(8)),
                      ),
                      items: _voiceLabels.entries.map((entry) {
                        return DropdownMenuItem<String>(
                          value: entry.key,
                          child: Text(entry.value, style: const TextStyle(fontSize: 14)),
                        );
                      }).toList(),
                      onChanged: _updateVoicePreference,
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _toggleAzanTest,
                        icon: Icon(
                          _isTestingAudio ? Icons.stop_circle : Icons.play_circle_filled, 
                          color: _isTestingAudio ? Colors.redAccent : Colors.tealAccent,
                          size: 20,
                        ),
                        label: Text(
                          _isTestingAudio ? 'Stop Preview' : 'Test: $currentReciterLabel',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white.withOpacity(0.05),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            side: BorderSide(color: _isTestingAudio ? Colors.redAccent.withOpacity(0.5) : Colors.teal.shade700, width: 1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            Card(
              color: Colors.black.withOpacity(0.3),
              shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.white10, width: 0.5), borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.all(14.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.calendar_month, color: Colors.tealAccent, size: 20),
                        SizedBox(width: 8),
                        Text('تعديل التاريخ الهجري (Hijri Adjustment)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white70)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Adjust this value if local moon sightings differ from standard mathematical calculations.',
                      style: TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline, color: Colors.tealAccent, size: 24),
                          onPressed: () => _updateHijriOffset(_hijriOffset - 1),
                        ),
                        Text(
                          _hijriOffset == 0 
                              ? "Standard Day (0)" 
                              : (_hijriOffset > 0 ? "+$_hijriOffset Days" : "$_hijriOffset Days"),
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.tealAccent),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline, color: Colors.tealAccent, size: 24),
                          onPressed: () => _updateHijriOffset(_hijriOffset + 1),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}