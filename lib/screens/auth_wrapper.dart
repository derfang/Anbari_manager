import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'auth_screen.dart';
import 'dashboard_screen.dart';
import 'room_gate_wrapper.dart';

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      // This stream listens to Firebase. It fires immediately on app boot.
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // If the connection is loading, show a blank screen or loader
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        
        // If Firebase found a saved login token, check their rooms!
        if (snapshot.hasData) {
          return const RoomGateWrapper();
        }
        
        // Otherwise, they are completely logged out. Show the login screen.
        return const AuthScreen();
      },
    );
  }
}