import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class FCMService {
  static const String _cloudflareWorkerUrl = 'https://anbarimanager.erfanps6.workers.dev/';

  /// Send an FCM message using the Cloudflare Worker
  static Future<void> sendPushMessage({
    required String targetFcmToken,
    required String title,
    required String body,
  }) async {
    try {
      final payload = {
        'token': targetFcmToken,
        'title': title,
        'body': body,
      };

      final response = await http.post(
        Uri.parse(_cloudflareWorkerUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        debugPrint('Successfully sent push notification via Cloudflare');
      } else {
        debugPrint('Failed to send push notification: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Error sending FCM push: $e');
    }
  }

  /// Looks up a user's FCM token and sends them a push notification
  static Future<void> sendPushToUser({
    required String uid,
    required String title,
    required String body,
  }) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        final token = data['fcmToken'];
        if (token != null && token.isNotEmpty) {
          await sendPushMessage(targetFcmToken: token, title: title, body: body);
        }
      }
    } catch (e) {
      debugPrint("Error sending push to user: $e");
    }
  }
}
