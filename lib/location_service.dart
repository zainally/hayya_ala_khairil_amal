import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocationService {
  static Future<Map<String, double>> getSavedOrLiveLocation() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    // 1. Check for manual location override profile first
    bool useManual = prefs.getBool('use_manual_location') ?? false;
    if (useManual) {
      double manualLat = prefs.getDouble('manual_lat') ?? 24.8607; 
      double manualLng = prefs.getDouble('manual_lng') ?? 67.0011;
      return {'latitude': manualLat, 'longitude': manualLng};
    }

    // 2. Validate hardware status if manual override is inactive
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      double savedLat = prefs.getDouble('last_lat') ?? 32.6160;
      double savedLng = prefs.getDouble('last_lng') ?? 44.0248;
      return {'latitude': savedLat, 'longitude': savedLng};
    }

    // 3. Validate App-Level Permissions
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        double savedLat = prefs.getDouble('last_lat') ?? 32.6160;
        double savedLng = prefs.getDouble('last_lng') ?? 44.0248;
        return {'latitude': savedLat, 'longitude': savedLng};
      }
    }

    if (permission == LocationPermission.deniedForever) {
      double savedLat = prefs.getDouble('last_lat') ?? 32.6160;
      double savedLng = prefs.getDouble('last_lng') ?? 44.0248;
      return {'latitude': savedLat, 'longitude': savedLng};
    }

    // 4. Secure Live GPS Stream with updated v11 signatures
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );

      await prefs.setDouble('last_lat', position.latitude);
      await prefs.setDouble('last_lng', position.longitude);

      return {'latitude': position.latitude, 'longitude': position.longitude};
    } catch (_) {
      double savedLat = prefs.getDouble('last_lat') ?? 32.6160;
      double savedLng = prefs.getDouble('last_lng') ?? 44.0248;
      return {'latitude': savedLat, 'longitude': savedLng};
    }
  }

  static Future<String> getCityName(double lat, double lng) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    bool useManual = prefs.getBool('use_manual_location') ?? false;
    
    if (useManual) {
      return prefs.getString('manual_city_name') ?? "Karachi (Manual)";
    }

    if (lat == 32.6160 && lng == 44.0248) {
      return "كربلاء المقدسة (Karbala)";
    }
    
    return prefs.getString('manual_city_name') ?? "Karachi";
  }
}