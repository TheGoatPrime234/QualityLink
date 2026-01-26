import 'dart:async';
import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart' as ft;
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/notification_helper.dart';

class OverlayForegroundService {
  static int _updateCounter = 0;
  static DateTime _lastUpdateTime = DateTime.now();
  
  static Future<void> startWithOverlay({
  required String status,
  required double progress,
  required String mode,
}) async {
  if (!Platform.isAndroid) return;

  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('status', status);
  await prefs.setDouble('progress', progress);
  await prefs.setString('mode', mode);
  await prefs.setBool('active', true);

  // ✅ Wenn Service läuft, NUR UPDATE - KEIN RESTART!
  if (await ft.FlutterForegroundTask.isRunningService) {
    print("🔄 Service already running, updating notification...");
    
    String emoji = '📦';
    if(mode == 'zipping') emoji = '🗜️';
    else if(mode == 'uploading') emoji = '📤';
    
    await ft.FlutterForegroundTask.updateService(
      notificationTitle: '$emoji $status',
      notificationText: '${(progress * 100).toInt()}% completed',
    );
    
    // Overlay auch updaten
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.shareData({
          'status': status,
          'progress': progress,
          'mode': mode,
        });
      } else {
        await _showWindow(status);
      }
    } catch (e) {
      print("⚠️ Overlay Error: $e");
    }
    
    return; // ← WICHTIG: Hier aufhören!
  }
  
  // ✅ Ab hier nur noch Code für den ERSTEN Start
  print("🚀 Starting Service (First Time)...");
  
  final notificationPermission = await ft.FlutterForegroundTask.checkNotificationPermission();
  print("📢 Notification permission: $notificationPermission");
  
  if (notificationPermission != ft.NotificationPermission.granted) {
    print("⚠️ Requesting notification permission...");
    final result = await ft.FlutterForegroundTask.requestNotificationPermission();
    print("📢 Permission result: $result");
    if (result != ft.NotificationPermission.granted) {
      print("❌ Notification permission denied!");
      return;
    }
  }
  
  ft.FlutterForegroundTask.init(
    androidNotificationOptions: ft.AndroidNotificationOptions(
      channelId: 'qualitylink_transfer_v2', 
      channelName: 'QualityLink Transfer',
      channelDescription: 'Active Transfer Progress',
      channelImportance: ft.NotificationChannelImportance.MAX, 
      priority: ft.NotificationPriority.MAX,
      playSound: false, // Kein Sound bei Updates
      enableVibration: false, // Keine Vibration bei Updates
      showWhen: true,
    ),
    iosNotificationOptions: const ft.IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ft.ForegroundTaskOptions(
      eventAction: ft.ForegroundTaskEventAction.repeat(2000), 
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );

  await Future.delayed(const Duration(milliseconds: 300));

  final serviceResult = await ft.FlutterForegroundTask.startService(
    notificationTitle: '🚀 Transfer Started',
    notificationText: status,
    callback: overlayServiceCallback,
  );
  
  print("📢 Start service result: $serviceResult");
  
  await Future.delayed(const Duration(milliseconds: 500));
  
  final stillRunning = await ft.FlutterForegroundTask.isRunningService;
  print("🔍 Service still running after start: $stillRunning");
  
  if (!stillRunning) {
    print("❌ Service died immediately after start!");
    return;
  }
  
  await _showWindow(status);
}

  static Future<void> _showWindow(String status) async {
    try {
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: "Transfer",
        overlayContent: status,
        flag: OverlayFlag.defaultFlag, 
        visibility: NotificationVisibility.visibilityPublic, 
        alignment: OverlayAlignment.topCenter,
        positionGravity: PositionGravity.auto,
        height: 180, 
        width: WindowSize.matchParent,
      );
    } catch (e) {
      print("⚠️ Overlay Error: $e");
    }
  }

  static Future<void> updateOverlay({
    required String status,
    required double progress,
    required String mode,
  }) async {
    if (!Platform.isAndroid) return;

    final now = DateTime.now();
    if (now.difference(_lastUpdateTime) < const Duration(milliseconds: 500) && progress < 1.0) {
      return; 
    }
    _lastUpdateTime = now;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('status', status);
    await prefs.setDouble('progress', progress);
    await prefs.setString('mode', mode);
    await prefs.setInt('update_counter', ++_updateCounter);

    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.shareData({
          'status': status,
          'progress': progress,
          'mode': mode,
        });
      }
    } catch (e) { /* silent */ }

    if (await ft.FlutterForegroundTask.isRunningService) {
       String emoji = '📦';
       if(mode == 'zipping') emoji = '🗜️';
       else if(mode == 'uploading') emoji = '📤';
       
       await ft.FlutterForegroundTask.updateService(
        notificationTitle: '$emoji $status',
        notificationText: '${(progress * 100).toInt()}% completed',
      );
    }
  }

  static Future<void> showCompletionNotification(String message) async {
    if (!Platform.isAndroid) return;
    
    print("🔔 Showing completion notification: $message");
    
    // ✅ Verwende separate Notification mit Sound & Vibration
    await NotificationHelper.showCompletionNotification(
      title: '✅ Transfer Complete!',
      body: message,
    );
    
    // Optional: Auch Service-Notification updaten
    if (await ft.FlutterForegroundTask.isRunningService) {
      await ft.FlutterForegroundTask.updateService(
        notificationTitle: '✅ Complete!',
        notificationText: message,
      );
    }
  }
  
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('active', false);

    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
      }
    } catch (e) {}

    if (await ft.FlutterForegroundTask.isRunningService) {
      await ft.FlutterForegroundTask.stopService();
    }
  }
}

// =============================================================================
// BACKGROUND ISOLATE
// =============================================================================
@pragma('vm:entry-point')
void overlayServiceCallback() {
  ft.FlutterForegroundTask.setTaskHandler(OverlayTaskHandler());
}

class OverlayTaskHandler extends ft.TaskHandler {
  int _lastCounter = 0;
  
  @override
  Future<void> onStart(DateTime timestamp, ft.TaskStarter starter) async {
    print("🔥 Service Isolate Started");
  }

  @override
  void onRepeatEvent(DateTime timestamp) async {
    // DO NOTHING - just keep the service alive
    // The main app will call updateOverlay() to update the notification
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    print("🛑 Service Isolate Destroyed");
  }

  @override
  void onNotificationPressed() { ft.FlutterForegroundTask.launchApp('/'); }
  @override
  void onNotificationDismissed() {}
  @override
  void onNotificationButtonPressed(String id) {}
}