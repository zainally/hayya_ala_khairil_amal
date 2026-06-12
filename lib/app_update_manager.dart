// app_update_manager.dart

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppUpdateManager {
  static const String _versionKey = 'installs_completed_build_number';

  static Future<void> handleAppUpdateMigration() async {
    final prefs = await SharedPreferences.getInstance();
    final packageInfo = await PackageInfo.fromPlatform();
    
    String currentVersionCode = packageInfo.buildNumber;
    String? lastKnownVersionCode = prefs.getString(_versionKey);

    if (lastKnownVersionCode == null) {
      // Scenario A: Fresh install or total storage wipe
      await prefs.setString(_versionKey, currentVersionCode);
    } else if (lastKnownVersionCode != currentVersionCode) {
      // Scenario B: User upgraded from an older version!
      await _executeCleanMigration(prefs, currentVersionCode);
    }
  }

  static Future<void> _executeCleanMigration(SharedPreferences prefs, String currentVersionCode) async {
    print(">>> App update detected! Executing clean migrations into build $currentVersionCode...");

    // 🌟 TARGETED CLEANUP: Do NOT use prefs.clear() here. 
    // We clean only temporary data while preserving user configurations (like voice choice or manual city settings).
    
    // Clear out background GPS coordinate cache so the next refresh cycles force an immediate, fresh calculations profile.
    await prefs.remove('last_known_gps_lat');
    await prefs.remove('last_known_gps_lng');
    await prefs.remove('last_known_gps_city');

    // 3. Update the tracking registry flag so this doesn't run again on the next boot
    await prefs.setString(_versionKey, currentVersionCode);
    
    print(">>> App successfully migrated and cleaned for version code: $currentVersionCode");
  }
}