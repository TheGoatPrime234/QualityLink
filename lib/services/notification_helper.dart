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
    
    // Erstelle Notification Channel
    const channel = AndroidNotificationChannel(
      'qualitylink_transfer',
      'QualityLink Transfer',
      description: 'Shows transfer progress',
      importance: Importance.high,
      playSound: false,
      enableVibration: false,
    );
    
    await _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    
    print("✅ Notification channel created");
  }
}