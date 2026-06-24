import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'create_room_screen.dart';
import 'join_room_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final TextEditingController _nameController = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Future<void> _signInWithGoogle(bool isCreator) async {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter your name first!")),
      );
      return;
    }

    try {
      UserCredential userCred;

      if (kIsWeb) {
        // On Web, Firebase has built-in popup support which avoids the new Google Identity Services button requirement
        GoogleAuthProvider authProvider = GoogleAuthProvider();
        userCred = await _auth.signInWithPopup(authProvider);
      } else {
        // 1. Initialize the new Google Sign-In instance (handle if already initialized)
        try {
          await GoogleSignIn.instance.initialize();
        } catch (e) {
          // Ignored if already initialized
        }
        
        // 2. Trigger the new Authentication flow
        final GoogleSignInAccount? googleUser = await GoogleSignIn.instance.authenticate();
        if (googleUser == null) return; // User canceled the sign-in

        // 3. Obtain the auth details
        final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

        // 4. Create the Firebase credential
        final AuthCredential credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
        );

        // 5. Sign in to Firebase
        userCred = await _auth.signInWithCredential(credential);
      }

      String currentUserId = userCred.user!.uid;

      if (!mounted) return;

      // 6. Navigate exactly like before
      if (isCreator) {
        Navigator.push(context, MaterialPageRoute(
          builder: (context) => CreateRoomScreen(
            creatorId: currentUserId, 
            creatorName: _nameController.text.trim(),
          ),
        ));
      } else {
        Navigator.push(context, MaterialPageRoute(
          builder: (context) => JoinRoomScreen(
            userId: currentUserId,
            userName: _nameController.text.trim(),
          ),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Google Sign-In Failed: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text("Roommate Chores", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
            const SizedBox(height: 40),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: "What is your name?",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => _signInWithGoogle(true),
              child: const Text("Create a New Room"),
            ),
            TextButton(
              onPressed: () => _signInWithGoogle(false),
              child: const Text("Scan QR to Join Room"),
            ),
          ],
        ),
      ),
    );
  }
}