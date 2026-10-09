
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
    
    // Create notification channels for reminders
    final androidPlugin = _localNotifs.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(channel);
      await androidPlugin.createNotificationChannel(const AndroidNotificationChannel(
        'daily_reminders',
        'Daily Reminders',
        description: 'Reminders for unfinished daily chores',
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('new_notification'),
      ));
      await androidPlugin.createNotificationChannel(const AndroidNotificationChannel(
        'weekly_summary',
        'Weekly Summaries',
        description: 'Saturday summary of upcoming chores for the week',
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('new_notification'),
      ));
      await androidPlugin.createNotificationChannel(const AndroidNotificationChannel(
        'expense_reminders',
        'Expense Reminders',
        description: 'Bi-weekly reminders to settle roommate expenses',
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('new_notification'),
      ));
    }

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

  /// Maps chore title to guilt-tripping playful copy & matching drawable picture
  Map<String, String> getChoreReminderCopy(String choreTitle) {
    final lower = choreTitle.toLowerCase();
    if (lower.contains('trash')) {
      return {
        'title': 'The Trash is on Strike! 🪧',
        'body': "It won't walk itself out. Take it out before it gains sentience and starts paying rent!",
        'image': 'chore_trash',
      };
    } else if (lower.contains('bathroom')) {
      return {
        'title': 'Biological Hazard Warning ☣️',
        'body': 'A new ecosystem is forming in the bathroom. Clean it before your roommates disown you!',
        'image': 'chore_bathroom',
      };
    } else if (lower.contains('kitchen') || lower.contains('counter')) {
      return {
        'title': 'Sticky with Regret 🍳',
        'body': 'The kitchen counters are calling for help. Wipe them down before the ants sign a lease!',
        'image': 'chore_kitchen',
      };
    } else if (lower.contains('vacuum')) {
      return {
        'title': 'The Dust Bunnies are Plotting 🐰',
        'body': "The floors won't clean themselves. Time to vacuum before the apartment turns into a desert!",
        'image': 'chore_vacuum',
      };
    } else if (lower.contains('mop') || lower.contains('sweep')) {
      return {
        'title': 'The Dust Bunnies are Plotting 🐰',
        'body': "The floors won't clean themselves. Time to sweep & mop before the apartment turns into a desert!",
        'image': 'chore_mop',
      };
    }
    return {
      'title': 'Your Roommates are Watching... 👀',
      'body': 'You still haven\'t finished "$choreTitle" today. Don\'t let your score tank into the negatives!',
      'image': 'chore_reminder',
    };
  }

  /// 1. Schedule a local reminder for 7 PM today if an uncompleted chore is due today (Alarm ID 1)
  Future<void> scheduleDailyChoreReminder(String? choreTitle) async {
    await _localNotifs.cancel(id: 1);

    if (choreTitle == null || choreTitle.isEmpty) {
      debugPrint("No unfinished chore due today; daily 7 PM reminder cleared.");
      return;
    }

    final now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(tz.local, now.year, now.month, now.day, 19, 0); // 7:00 PM today

    if (scheduledDate.isBefore(now)) {
      // Already past 7 PM today
      return;
    }

    final copy = getChoreReminderCopy(choreTitle);

    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'daily_reminders',
      'Daily Reminders',
      channelDescription: 'Reminders for unfinished daily chores',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      sound: const RawResourceAndroidNotificationSound('new_notification'),
      largeIcon: DrawableResourceAndroidBitmap(copy['image']!),
      styleInformation: BigTextStyleInformation(copy['body']!, contentTitle: copy['title']!),
    );

    final platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    await _localNotifs.zonedSchedule(
      id: 1,
      title: copy['title'],
      body: copy['body'],
      scheduledDate: scheduledDate,
      notificationDetails: platformChannelSpecifics,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );

    debugPrint("Scheduled daily chore reminder for $scheduledDate with image ${copy['image']}");
  }

  /// 2. Schedule Saturday 6:50 PM weekly chore summary (Alarm ID 2)
  Future<void> scheduleSaturdayWeeklySummary({required int count, required List<String> choreTitles}) async {
    await _localNotifs.cancel(id: 2);

    final now = tz.TZDateTime.now(tz.local);

    int daysUntilSaturday = (DateTime.saturday - now.weekday + 7) % 7;
    var scheduledDate = tz.TZDateTime(tz.local, now.year, now.month, now.day + daysUntilSaturday, 18, 50); // 6:50 PM

    // If today is Saturday and it's already past 6:50 PM, schedule for next Saturday
    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 7));
    }

    String title;
    String body;
    if (count > 0) {
      final listStr = choreTitles.take(3).join(', ');
      title = 'Fate Has Spoken 📋';
      body = 'You have $count chore(s) lined up this week ($listStr). Time to earn your keep and save your points!';
    } else {
      title = 'Living the High Life 🛋️';
      body = 'Zero chores assigned to you this week! Sit back, relax, and watch your roommates do all the work.';
    }

    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'weekly_summary',
      'Weekly Summaries',
      channelDescription: 'Saturday summary of upcoming chores for the week',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      sound: const RawResourceAndroidNotificationSound('new_notification'),
      largeIcon: const DrawableResourceAndroidBitmap('chore_reminder'),
      styleInformation: BigTextStyleInformation(body, contentTitle: title),
    );

    final platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    await _localNotifs.zonedSchedule(
      id: 2,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      notificationDetails: platformChannelSpecifics,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );

    debugPrint("Scheduled Saturday weekly summary for $scheduledDate");
  }

  /// 3. Schedule bi-weekly Friday 6:00 PM expense settle-up starting 1st of Aban (October 23, 2026) (Alarm ID 3)
  Future<void> scheduleBiWeeklyFridaySettleUp() async {
    await _localNotifs.cancel(id: 3);

    final now = tz.TZDateTime.now(tz.local);

    // Anchor: Friday, October 23, 2026 (1st of Aban 1405) at 18:00
    final anchor = tz.TZDateTime(tz.local, 2026, 10, 23, 18, 0);

    tz.TZDateTime scheduledDate;
    if (now.isBefore(anchor)) {
      scheduledDate = anchor;
    } else {
      final daysSinceAnchor = now.difference(anchor).inDays;
      final int periodsPassed = daysSinceAnchor ~/ 14;
      var candidate = anchor.add(Duration(days: periodsPassed * 14));
      if (!candidate.isAfter(now)) {
        candidate = candidate.add(const Duration(days: 14));
      }
      scheduledDate = candidate;
    }

    const title = 'Pay Your Debts! 💰';
    const body = 'Friendship is priceless, but rent and groceries aren\'t. Open Finances to review expenses and square up balances!';

    final androidPlatformChannelSpecifics = const AndroidNotificationDetails(
      'expense_reminders',
      'Expense Reminders',
      channelDescription: 'Bi-weekly reminders to settle roommate expenses',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('new_notification'),
      largeIcon: DrawableResourceAndroidBitmap('new_expense'),
      styleInformation: BigTextStyleInformation(body, contentTitle: title),
    );

    final platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    await _localNotifs.zonedSchedule(
      id: 3,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      notificationDetails: platformChannelSpecifics,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );

    debugPrint("Scheduled bi-weekly Friday settle-up for $scheduledDate");
  }

  /// Unified sync method to schedule all 3 notifications
  Future<void> syncAllReminders({
    required String? todayChoreTitle,
    required int weekChoresCount,
    required List<String> weekChoreTitles,
  }) async {
    await scheduleDailyChoreReminder(todayChoreTitle);
    await scheduleSaturdayWeeklySummary(count: weekChoresCount, choreTitles: weekChoreTitles);
    await scheduleBiWeeklyFridaySettleUp();
  }

  /// Cancel the daily reminder (e.g. if the user completes their chore early)
  Future<void> cancelDailyReminder() async {
    await _localNotifs.cancel(id: 1);
    debugPrint("Cancelled daily reminder");
  }
}
