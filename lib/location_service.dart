import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocationService {
  /// Fetches system coordinates or returns a status map indicating the source state
  static Future<Map<String, dynamic>> getSavedOrLiveLocation() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool useManual = prefs.getBool('use_manual_location') ?? false;

    // 1. Manual Profile Override Mode
    if (useManual) {
      return {
        'latitude': prefs.getDouble('manual_lat') ?? 32.6160,  // Default to Karbala Lat if unconfigured
        'longitude': prefs.getDouble('manual_lng') ?? 44.0248, // Default to Karbala Lng if unconfigured
        'status': 'manual',
      };
    }

    // 2. Live GPS Mode
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      LocationPermission permission = await Geolocator.checkPermission();
      
      // If permission is denied (the default install state), prompt the user immediately!
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
	  
      // If location master switch is off or permissions are missing, trigger smart cache fallback
      if (!serviceEnabled || permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return await _getFallbackLocation();
      }

      // STEP A: Attempt to pull instant cached location from system logs
      Position? position = await Geolocator.getLastKnownPosition();

      // STEP B: If no cached position exists, request a fresh location lock with an extended 12s window
      if (position == null) {
        print(">>> No last known position found. Requesting fresh satellite lock...");
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.low,
          timeLimit: const Duration(seconds: 12), // Extended to survive indoor/hardware cold starts
        );
      }

      // 🌟 STATE STORAGE: Cache successful coordinates to shield background isolate threads
      await prefs.setDouble('last_known_gps_lat', position.latitude);
      await prefs.setDouble('last_known_gps_lng', position.longitude);

      return {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'status': 'gps_success',
      };
    } catch (e) {
      print("!!! Live coordinates retrieval failed: $e");
      
      // STEP C: Last line of defense safety net before giving up on active tracking logs
      try {
        Position? backupPosition = await Geolocator.getLastKnownPosition();
        if (backupPosition != null) {
          await prefs.setDouble('last_known_gps_lat', backupPosition.latitude);
          await prefs.setDouble('last_known_gps_lng', backupPosition.longitude);
          return {
            'latitude': backupPosition.latitude,
            'longitude': backupPosition.longitude,
            'status': 'gps_success',
          };
        }
      } catch (_) {}
      
      return await _getFallbackLocation();
    }
  }

  /// Checks if background or foreground location tracking is allowed
  static Future<bool> isPermissionGranted() async {
    LocationPermission permission = await Geolocator.checkPermission();
    return permission == LocationPermission.always || 
           permission == LocationPermission.whileInUse;
  }

  /// Forces the OS to launch the system application management console for this app
  static Future<void> openAppSettingsMenu() async {
    await Geolocator.openAppSettings();
  }

  /// Resolves the text label based on state and geocoding availability
  static Future<String> getCityName(double lat, double lng, String status) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    if (status == 'manual') {
      return prefs.getString('manual_city_name') ?? "كربلاء المقدسة (Karbala)";
    }

    if (status == 'gps_failed') {
      return "كربلاء المقدسة (Karbala)";
    }

    // 🌟 STATE RETRIEVAL: Display last validated city name if operating on cached backup parameters
    if (status == 'gps_fallback_cached') {
      return prefs.getString('last_known_gps_city') ?? "Live GPS Location";
    }

    // Attempt online reverse-geocoding only if coordinates were successfully fetched
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isNotEmpty && placemarks.first.locality != null && placemarks.first.locality!.isNotEmpty) {
        final String resolvedCity = placemarks.first.locality!;
        // 🌟 CACHE CITY NAME: Save alongside the lat/long data points
        await prefs.setString('last_known_gps_city', resolvedCity);
        return resolvedCity;
      }
      return "Live GPS Location";
    } catch (e) {
      print("!!! Reverse geocoding lookup failed: $e");
      return prefs.getString('last_known_gps_city') ?? "Live GPS Location"; 
    }
  }

  /// 🌟 ROBUST FALLBACK ENGINE: Pulls the last validated user coordinates before resorting to default coordinates
  static Future<Map<String, dynamic>> _getFallbackLocation() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final double? lastLat = prefs.getDouble('last_known_gps_lat');
    final double? lastLng = prefs.getDouble('last_known_gps_lng');

    if (lastLat != null && lastLng != null) {
      return {
        'latitude': lastLat,
        'longitude': lastLng,
        'status': 'gps_fallback_cached',
      };
    }

    // Absolute fallback value if application has never achieved a single GPS lock
    return {
      'latitude': 32.6160,
      'longitude': 44.0248,
      'status': 'gps_failed',
    };
  }
}