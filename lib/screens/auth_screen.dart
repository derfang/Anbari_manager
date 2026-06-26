import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  bool _isLoading = false;

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      if (kIsWeb) {
        GoogleAuthProvider authProvider = GoogleAuthProvider();
        final result = await _auth.signInWithPopup(authProvider);
        if (result.user != null) {
          print("Google Sign In Success: ${result.user?.email}");
        }
      } else {
        try {
          await GoogleSignIn.instance.initialize();
        } catch (e) {}
        
        final GoogleSignInAccount? googleUser = await GoogleSignIn.instance.authenticate();
        if (googleUser == null) {
          if (mounted) setState(() => _isLoading = false);
          return; 
        }

        final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
        final AuthCredential credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
        );

        await _auth.signInWithCredential(credential);
      }
      // Give the stream a moment to update
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Google Sign-In Failed: $e")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.teal.shade50,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.home_work_rounded, size: 80, color: Colors.teal),
              const SizedBox(height: 24),
              const Text("Roommate Chores", style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.teal)),
              const SizedBox(height: 12),
              const Text("Manage your apartment peaceably.", style: TextStyle(fontSize: 16, color: Colors.blueGrey)),
              const SizedBox(height: 60),
              if (_isLoading)
                const CircularProgressIndicator()
              else
                FilledButton.icon(
                  icon: const Icon(Icons.login),
                  label: const Text("Sign in with Google", style: TextStyle(fontSize: 18)),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  onPressed: _signInWithGoogle,
                ),
            ],
          ),
        ),
      ),
    );
  }
}