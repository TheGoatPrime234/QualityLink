import 'dart:ui';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:io';

class NotificationHelper {
  static final FlutterLocalNotificationsPlugin _notifications = 
      FlutterLocalNotificationsPlugin();
  
  static Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    
    await _notifications.initialize(initSettings);
    
    // Foreground Service Channel (ohne Sound/Vibration)
    const foregroundChannel = AndroidNotificationChannel(
      'qualitylink_transfer_v2',
      'QualityLink Transfer',
      description: 'Shows transfer progress',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );
    
    // ✅ Completion Channel (MIT Sound/Vibration für Heads-Up)
    const completionChannel = AndroidNotificationChannel(
      'qualitylink_completion',
      'Transfer Complete',
      description: 'Notifications when transfers complete',
      importance: Importance.high, // ✅ HIGH für Heads-Up
      playSound: true, // ✅ Sound
      enableVibration: true, // ✅ Vibration
      enableLights: true,
      ledColor: Color(0xFF00FF41),
    );
    
    final plugin = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    
    await plugin?.createNotificationChannel(foregroundChannel);
    await plugin?.createNotificationChannel(completionChannel);
    
    print("✅ Notification channels created");
  }
  
  // ✅ NEU: Separate Methode für Completion Notifications mit Sound & Vibration
  static Future<void> showCompletionNotification({
    required String title,
    required String body,
  }) async {
    if (!Platform.isAndroid) return;
    
    final androidDetails = AndroidNotificationDetails(
      'qualitylink_completion', // ✅ Nutzt den Completion Channel
      'Transfer Complete',
      channelDescription: 'Notifications when transfers complete',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      enableLights: true,
      color: const Color(0xFF00FF41),
      ledColor: const Color(0xFF00FF41),
      ledOnMs: 1000,
      ledOffMs: 500,
      styleInformation: BigTextStyleInformation(body),
      icon: '@mipmap/ic_launcher',
      // ✅ Zeige als Heads-Up Notification
      visibility: NotificationVisibility.public,
      category: AndroidNotificationCategory.status,
    );
    
    final notificationDetails = NotificationDetails(android: androidDetails);
    
    // Generiere unique ID basierend auf Timestamp
    final id = DateTime.now().millisecondsSinceEpoch.remainder(100000);
    
    await _notifications.show(
      id,
      title,
      body,
      notificationDetails,
    );
    
    print("🔔 Completion notification shown: $title - $body");
  }
}