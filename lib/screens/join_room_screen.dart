import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dashboard_screen.dart';

class JoinRoomScreen extends StatefulWidget {
  final String userId;
  final String userName;

  const JoinRoomScreen({
    super.key,
    required this.userId,
    required this.userName,
  });

  @override
  State<JoinRoomScreen> createState() => _JoinRoomScreenState();
}

class _JoinRoomScreenState extends State<JoinRoomScreen> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  bool _isProcessing = false;

  Future<void> _processScannedCode(String scannedData) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      // 1. Split the data: roomId|password
      List<String> parts = scannedData.split('|');
      if (parts.length != 2) throw Exception("Invalid QR Code format.");

      String roomId = parts[0];
      String password = parts[1];

      // 2. Verify the room exists and password matches
      DocumentSnapshot roomDoc = await _db
          .collection('rooms')
          .doc(roomId)
          .get();
      if (!roomDoc.exists || roomDoc['password'] != password) {
        throw Exception("Room not found or invalid password.");
      }

      // 3. Create the roommate's profile in the database
      await _db.collection('users').doc(widget.userId).set({
        'name': widget.userName,
        'roomId': roomId,
        'points': 0.0,
        'isAdmin': false,
        'isAbsent': false,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Successfully joined the room!")),
      );

      // Navigate to Dashboard
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const DashboardScreen()),
        (route) => false,
      );

    } catch (e) {
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error: ${e.toString()}")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Scan Room QR")),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              final List<Barcode> barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                if (barcode.rawValue != null) {
                  _processScannedCode(barcode.rawValue!);
                  break; // Stop scanning once we get a hit
                }
              }
            },
          ),
          if (_isProcessing) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
