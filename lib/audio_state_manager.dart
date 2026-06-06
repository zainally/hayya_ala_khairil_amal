import 'dart:ui';
import 'dart:isolate';
import 'package:just_audio/just_audio.dart';

class AudioStateManager {
  static final AudioPlayer globalPlayer = AudioPlayer();

  static void notifyDashboard(bool isPlaying) {
    final SendPort? sendPort = IsolateNameServer.lookupPortByName('azan_playback_port');
    sendPort?.send(isPlaying);
  }

  static Future<void> stopEverything() async {
    // 1. Instantly silence the foreground player if running a settings preview
    try {
      if (globalPlayer.playing) {
        await globalPlayer.stop();
      }
    } catch (e) {
      print("Global player stop exception: $e");
    }

    // 2. 🌟 THE FIX: Fire a direct reverse memory shot straight into the background isolate port
    final SendPort? bgCommandPort = IsolateNameServer.lookupPortByName('azan_commands_port');
    bgCommandPort?.send('STOP');

    // 3. Clear UI layouts
    notifyDashboard(false);
  }
}