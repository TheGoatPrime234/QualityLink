import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// Server Config - Anpassen!
const String serverBaseUrl = 'http://100.109.221.18:8000';

// =============================================================================
// CLIPBOARD BACKGROUND SERVICE (Flutter Foreground Task 8.17.0)
// =============================================================================

class ClipboardBackgroundService {
  
  static Future<void> startService(String clientId, String deviceName) async {
    if (!Platform.isAndroid) return;

    if (await FlutterForegroundTask.isRunningService) {
      print('⚠️ Service already running');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bg_client_id', clientId);
    await prefs.setString('bg_device_name', deviceName);

    // Initialisierung für Version 8.17.0
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'qualitylink_clipboard',
        channelName: 'QualityLink Clipboard Sync',
        channelDescription: 'Keeps clipboard synced across devices',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(15000), 
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );

    // Service starten
    await FlutterForegroundTask.startService(
      notificationTitle: 'QualityLink Active',
      notificationText: 'Clipboard sync is running',
      callback: startCallback,
    );

    print('✅ Clipboard service started');
  }

  static Future<void> stopService() async {
    if (!Platform.isAndroid) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    
    await FlutterForegroundTask.stopService();
    print('🛑 Clipboard service stopped');
  }

  static Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    return await FlutterForegroundTask.isRunningService;
  }
}

// =============================================================================
// TOP-LEVEL CALLBACK
// =============================================================================
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(ClipboardTaskHandler());
}

// =============================================================================
// TASK HANDLER (Version 8.17.0 kompatibel)
// =============================================================================
class ClipboardTaskHandler extends TaskHandler {
  String? _lastClipboardContent;
  String? _lastReceivedContent;
  int _errorCount = 0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print('📋 Background clipboard service started');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _performBackgroundSync();
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    print('📋 Background clipboard service stopped');
  }

  @override
  void onNotificationButtonPressed(String id) {
    print('🔘 Notification button pressed: $id');
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onNotificationDismissed() {
    print('🚫 Notification dismissed');
  }

  Future<void> _performBackgroundSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final clientId = prefs.getString('bg_client_id');
      final deviceName = prefs.getString('bg_device_name');
      final autoSync = prefs.getBool('clipboard_auto_sync') ?? true;
      final autoCopy = prefs.getBool('clipboard_auto_copy') ?? false;

      if (clientId == null || deviceName == null || !autoSync) return;

      // 1. PUSH LOCAL CLIPBOARD
      if (Platform.isAndroid) {
        try {
          final clipData = await Clipboard.getData(Clipboard.kTextPlain);
          final content = clipData?.text?.trim();

          if (content != null &&
              content.isNotEmpty &&
              content != _lastClipboardContent &&
              content != _lastReceivedContent) {
            
            _lastClipboardContent = content;
            await _pushToServer(clientId, deviceName, content);

            FlutterForegroundTask.updateService(
              notificationTitle: 'QualityLink Active',
              notificationText: '📤 Synced: ${content.substring(0, min(20, content.length))}...',
            );
          }
        } catch (e) {
          print('❌ Clipboard read error: $e');
        }
      }

      // 2. PULL & AUTO-COPY
      if (autoCopy) {
        try {
          final response = await http
              .get(Uri.parse('$serverBaseUrl/clipboard/pull'))
              .timeout(const Duration(seconds: 5));

          if (response.statusCode == 200) {
            final data = json.decode(response.body);
            final List<dynamic> entries = data['entries'];

            if (entries.isNotEmpty) {
              final newest = entries.first;
              
              if (newest['client_id'] != clientId) {
                final content = newest['content'] as String;
                
                if (content != _lastReceivedContent && 
                    content != _lastClipboardContent) {
                  _lastReceivedContent = content;
                  _lastClipboardContent = content;
                  
                  try {
                    await Clipboard.setData(ClipboardData(text: content));
                    print('📄 Auto-copied: ${content.substring(0, min(30, content.length))}...');
                  } catch (e) {
                    print('⚠️ Cannot set clipboard in background (Android 10+)');
                  }
                  FlutterForegroundTask.updateService(
                    notificationTitle: '📥 New Clip (${newest['client_name'] ?? 'Device'})',
                    notificationText: 'Tap to copy: ${content.substring(0, min(30, content.length))}...',
                  );
                }
              }
            }
          }
          _errorCount = 0;
        } catch (e) {
          _errorCount++;
          if (_errorCount % 10 == 0) {
            print('❌ Sync Error ($_errorCount): $e');
          }
          
          if (_errorCount >= 20) {
            FlutterForegroundTask.updateService(
              notificationTitle: 'QualityLink Active',
              notificationText: '⚠️ Connection issues. Retrying...',
            );
          }
        }
      }
    } catch (e) {
      print('❌ Task Error: $e');
    }
  }

  Future<void> _pushToServer(String clientId, String deviceName, String content) async {
    try {
      final contentType = _detectContentType(content);
      
      final response = await http.post(
        Uri.parse('$serverBaseUrl/clipboard/push'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "client_id": clientId,
          "client_name": deviceName,
          "content": content,
          "content_type": contentType,
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        print('📋 Pushed: ${content.substring(0, min(50, content.length))}...');
      }
    } catch (e) {
      print('❌ Push failed: $e');
    }
  }

  String _detectContentType(String content) {
    if (content.startsWith('http://') || content.startsWith('https://')) {
      return 'url';
    } else if (content.contains('import ') || 
               content.contains('function ') || 
               content.contains('class ')) {
      return 'code';
    }
    return 'text';
  }
}