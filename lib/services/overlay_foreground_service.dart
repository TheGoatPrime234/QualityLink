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
      await updateOverlay(status: status, progress: progress, mode: mode);
      return; 
    }
    
    // ✅ Ab hier nur noch Code für den ERSTEN Start
    print("🚀 Starting Service (First Time)...");
    
    final notificationPermission = await ft.FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != ft.NotificationPermission.granted) {
      print("⚠️ Requesting notification permission...");
      final result = await ft.FlutterForegroundTask.requestNotificationPermission();
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
        playSound: false, // Kein Sound bei Updates des Services
        enableVibration: false, 
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

    // Throttling: Updates nur alle 500ms, außer bei Start/Ende
    final now = DateTime.now();
    if (now.difference(_lastUpdateTime) < const Duration(milliseconds: 500) && 
        progress < 1.0 && progress > 0.0) {
      return; 
    }
    _lastUpdateTime = now;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('status', status);
    await prefs.setDouble('progress', progress);
    await prefs.setString('mode', mode);
    await prefs.setInt('update_counter', ++_updateCounter);

    // 1. Overlay Fenster updaten (falls aktiv)
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.shareData({
          'status': status,
          'progress': progress,
          'mode': mode,
        });
      }
    } catch (e) { /* silent */ }

    // 2. Notification Service updaten
    if (await ft.FlutterForegroundTask.isRunningService) {
       String emoji = '📦';
       if(mode == 'zipping') emoji = '🗜️';
       else if(mode == 'uploading') emoji = '📤';
       else if(mode == 'downloading') emoji = '⬇️';
       else if(mode == 'idle') emoji = '✨'; // ✅ Neuer Status
       else if(mode == 'success') emoji = '✅'; // ✅ Neuer Status
       
       String text = '${(progress * 100).toInt()}% completed';
       if (mode == 'idle') text = 'Ready for transfers';
       if (mode == 'success') text = 'Transfer finished';
       
       await ft.FlutterForegroundTask.updateService(
        notificationTitle: '$emoji $status',
        notificationText: text,
      );
    }
  }

  // ✅ Neue Methode: Sendet NUR eine laute Benachrichtigung (für Start/Fehler)
  static Future<void> showStatusNotification({
    required String title,
    required String body,
  }) async {
    if (!Platform.isAndroid) return;
    await NotificationHelper.showCompletionNotification(
      title: title,
      body: body,
    );
  }

  // ✅ WICHTIG: Stoppt den Service NICHT mehr automatisch!
  static Future<void> showCompletionNotification(String message) async {
    if (!Platform.isAndroid) return;
    
    print("🔔 Showing completion notification: $message");
    
    // 1. Laute Heads-Up Notification (Sound/Vibration) via Helper
    await NotificationHelper.showCompletionNotification(
      title: '✅ Transfer Complete!',
      body: message,
      timeoutMs: 60000,
    );
    
    if (await ft.FlutterForegroundTask.isRunningService) {
      await updateOverlay(
        status: "QualityLink Ready",
        progress: 0.0,
        mode: "idle",
      );
      
      // Optional: Nach 5 Sekunden auf "Idle" zurücksetzen, damit "Ready" steht
      Future.delayed(const Duration(seconds: 5), () {
        updateOverlay(
          status: "QualityLink Ready",
          progress: 0.0,
          mode: "idle",
        );
      });
    }
  }
  
  // stop() bleibt erhalten (für App-Exit), wird aber im Transfer-Flow nicht mehr gerufen
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