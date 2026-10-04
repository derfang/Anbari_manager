
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
// removed unused imports

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (e) {
    // Ignore if already initialized
  }
  final FlutterLocalNotificationsPlugin localNotifs = FlutterLocalNotificationsPlugin();
  
  const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
  const InitializationSettings initSettings = InitializationSettings(android: androidSettings, iOS: iosSettings);
  await localNotifs.initialize(settings: initSettings);

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'roommate_chores_channel_v3',
    'Roommate Chores Notifications',
    description: 'Notifications for chores and expenses',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('new_notification'),
  );
  
  await localNotifs
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await _showLocalNotification(message, localNotifs);
}

Future<void> _showLocalNotification(RemoteMessage message, FlutterLocalNotificationsPlugin plugin) async {
  String? title = message.data['title'];
  String? body = message.data['body'];
  
  if (title != null && body != null) {
    StyleInformation? styleInfo;
    String? imageName = message.data['image'];
    
    // Fallback: If backend didn't specify an image, let the app decide!
    if (imageName == null || imageName.isEmpty) {
      final lowerTitle = title.toLowerCase();
      final lowerBody = body.toLowerCase();
      if (lowerTitle.contains('expense') || lowerTitle.contains('approval') || lowerTitle.contains('declined') || lowerTitle.contains('charge') || lowerBody.contains('charge')) {
        imageName = 'new_expense';
      } else if (lowerTitle.contains('trash') || lowerBody.contains('trash')) {
        imageName = 'chore_trash';
      } else if (lowerTitle.contains('bathroom') || lowerBody.contains('bathroom')) {
        imageName = 'chore_bathroom';
      } else if (lowerTitle.contains('mop') || lowerBody.contains('mop') || lowerTitle.contains('sweep') || lowerBody.contains('sweep')) {
        imageName = 'chore_mop';
      } else if (lowerTitle.contains('kitchen') || lowerBody.contains('kitchen')) {
        imageName = 'chore_kitchen';
      } else if (lowerTitle.contains('vacuum') || lowerBody.contains('vacuum')) {
        imageName = 'chore_vacuum';
      } else {
        imageName = 'chore_reminder';
      }
    }
    
    if (title != null && body != null) {
      styleInfo = BigTextStyleInformation(
        body,
        contentTitle: title,
      );
    }

    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'roommate_chores_channel_v3', 
      'Roommate Chores Notifications',
      channelDescription: 'Notifications for chores and expenses',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      playSound: true,
      sound: const RawResourceAndroidNotificationSound('new_notification'),
      styleInformation: styleInfo,
      largeIcon: imageName != null && imageName.isNotEmpty 
          ? DrawableResourceAndroidBitmap(imageName) 
          : null,
    );

    final platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    await plugin.show(
      id: message.hashCode,
      title: title,
      body: body,
      notificationDetails: platformChannelSpecifics,
    );
  }
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifs = FlutterLocalNotificationsPlugin();
  
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    
    // Initialize timezone for scheduled notifications
    tz.initializeTimeZones();
    try {
      final String currentTimeZone = (await FlutterTimezone.getLocalTimezone()).identifier;
      tz.setLocalLocation(tz.getLocation(currentTimeZone));
    } catch (e) {
      debugPrint("Failed to get local timezone: $e");
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    // Setup local notifications
    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
    const InitializationSettings initSettings = InitializationSettings(android: androidSettings, iOS: iosSettings);
    
    await _localNotifs.initialize(settings: initSettings);

    // Explicitly create the channel so background FCM messages can use it!
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'roommate_chores_channel_v3',
      'Roommate Chores Notifications',
      description: 'Notifications for chores and expenses',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('new_notification'),
    );
    
    await _localNotifs
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    // Request permissions for push
    NotificationSettings settings = await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      debugPrint('User granted notification permission');
      await _saveTokenToDatabase();
    }

    // Set up Firebase Messaging foreground listener
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      _showLocalNotification(message, _localNotifs);
    });

    // Set up Firebase Messaging background listener
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    _initialized = true;
  }

  Future<void> _saveTokenToDatabase() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      String? token = await _fcm.getToken();
      if (token != null) {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
          'fcmToken': token,
        });
        debugPrint('FCM Token saved: $token');
      }

      // Listen for token refreshes
      _fcm.onTokenRefresh.listen((newToken) {
        FirebaseFirestore.instance.collection('users').doc(user.uid).update({
          'fcmToken': newToken,
        });
      });
    } catch (e) {
      debugPrint("Error saving FCM token: $e");
    }
  }

  /// Schedule a local reminder for 7 PM today.
  Future<void> scheduleDailyReminder({required String choreName, required String body}) async {
    // We cancel any existing reminder first to avoid duplicates
    await _localNotifs.cancel(id: 1); // 1 is the ID for the daily reminder

    final now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(tz.local, now.year, now.month, now.day, 19, 0); // 7:00 PM
    
    if (scheduledDate.isBefore(now)) {
      // If it's already past 7 PM, don't schedule it for today.
      return; 
    }

    const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'daily_reminders',
      'Daily Reminders',
      channelDescription: 'Reminders for unfinished chores',
      importance: Importance.max,
      priority: Priority.high,
    );
    const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    await _localNotifs.zonedSchedule(
      id: 1,
      title: 'Duolingo Owl 🦉',
      body: body,
      scheduledDate: scheduledDate,
      notificationDetails: platformChannelSpecifics,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
    
    debugPrint("Scheduled local notification for $scheduledDate");
  }

  /// Cancel the daily reminder (e.g. if the user completes their chore early)
  Future<void> cancelDailyReminder() async {
    await _localNotifs.cancel(id: 1);
    debugPrint("Cancelled daily reminder");
  }
}
