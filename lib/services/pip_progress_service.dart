import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =============================================================================
// PICTURE-IN-PICTURE SERVICE (funktioniert auf allen Samsung Geräten!)
// =============================================================================
class PipProgressService {
  static const platform = MethodChannel('com.qualitylink/pip');
  static bool _isServiceRunning = false;
  static bool _isPipActive = false;
  
  static Future<void> startWithPip({
    required String status,
    required double progress,
    required String mode,
  }) async {
    if (!Platform.isAndroid) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pip_status', status);
    await prefs.setDouble('pip_progress', progress);
    await prefs.setString('pip_mode', mode);
    await prefs.setBool('pip_active', true);

    // Starte Foreground Service für Notification
    if (!_isServiceRunning) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'qualitylink_pip',
          channelName: 'QualityLink Transfer',
          channelDescription: 'Shows transfer progress',
          channelImportance: NotificationChannelImportance.HIGH,
          priority: NotificationPriority.HIGH,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(1000),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: false,
        ),
      );

      await FlutterForegroundTask.startService(
        notificationTitle: 'Transfer Active',
        notificationText: '$status - ${(progress * 100).toInt()}%',
        callback: pipServiceCallback,
      );
      
      _isServiceRunning = true;
      print("✅ PiP Service started");
    }

    // Aktiviere Picture-in-Picture Mode
    try {
      await platform.invokeMethod('enterPipMode');
      _isPipActive = true;
      print("✅ Entered PiP mode");
    } catch (e) {
      print("⚠️ PiP not available: $e");
      print("📱 Using notification only (works fine!)");
    }
  }

  static Future<void> updateProgress({
    required String status,
    required double progress,
    required String mode,
  }) async {
    if (!Platform.isAndroid) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pip_status', status);
    await prefs.setDouble('pip_progress', progress);
    await prefs.setString('pip_mode', mode);

    // Update Notification (das sehen wir IMMER)
    if (_isServiceRunning) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Transfer Active',
        notificationText: '$status - ${(progress * 100).toInt()}%',
      );
      print("📤 Progress updated: $status (${(progress * 100).toInt()}%)");
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pip_active', false);

    // Exit PiP
    if (_isPipActive) {
      try {
        await platform.invokeMethod('exitPipMode');
        _isPipActive = false;
        print("✅ Exited PiP mode");
      } catch (e) {
        print("⚠️ PiP exit error: $e");
      }
    }

    // Stop Service
    if (_isServiceRunning) {
      await FlutterForegroundTask.stopService();
      _isServiceRunning = false;
      print("✅ PiP Service stopped");
    }
  }

  static Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    return _isServiceRunning;
  }
}

// =============================================================================
// SERVICE CALLBACK
// =============================================================================
@pragma('vm:entry-point')
void pipServiceCallback() {
  FlutterForegroundTask.setTaskHandler(PipTaskHandler());
}

class PipTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print("🔥 PiP Service Started");
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _handleRepeatEvent();
  }

  Future<void> _handleRepeatEvent() async {
    final prefs = await SharedPreferences.getInstance();
    final shouldBeActive = prefs.getBool('pip_active') ?? false;
    
    if (!shouldBeActive) {
      print("ℹ️ PiP should be inactive, stopping...");
      await FlutterForegroundTask.stopService();
      return;
    }
    
    // Notification wird automatisch aktualisiert durch updateProgress()
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    print("🛑 PiP Service Destroyed");
  }

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onNotificationDismissed() {}
}