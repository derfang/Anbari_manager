import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'room_selection_screen.dart';
import 'dashboard_screen.dart';

class RoomGateWrapper extends StatelessWidget {
  const RoomGateWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text("Authentication Error")));
    }

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(body: Center(child: Text("Database Error: ${snapshot.error}. You may need to logout and log back in.")));
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        if (!snapshot.hasData || !snapshot.data!.exists) {
          // User document doesn't exist yet, they definitely don't have a room
          return const RoomSelectionScreen();
        }

        final data = snapshot.data!.data() as Map<String, dynamic>;
        
        // Check for roomIds array (new architecture) or fallback to single roomId
        List<dynamic> roomIds = data['roomIds'] ?? [];
        if (roomIds.isEmpty && data['roomId'] != null && data['roomId'].toString().isNotEmpty) {
          roomIds = [data['roomId']]; // Migrate legacy users seamlessly
        }

        if (roomIds.isEmpty) {
          return const RoomSelectionScreen();
        }

        // They belong to at least one room! Check if they have an active currentRoomId selected
        String? currentRoomId = data['currentRoomId'];
        if (currentRoomId == null || !roomIds.contains(currentRoomId)) {
          // Fallback to the first room in their array
          currentRoomId = roomIds.first.toString();
          // Silently update it so it's consistent
          FirebaseFirestore.instance.collection('users').doc(user.uid).update({'currentRoomId': currentRoomId});
        }

        // Drop them straight into the Dashboard of their active room!
        return DashboardScreen(roomId: currentRoomId);
      },
    );
  }
}
