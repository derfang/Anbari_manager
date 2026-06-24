import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/chore_service.dart';
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

      // 4. Recalculate the current week so the new user gets chores immediately
      await ChoreService().recalculateWeek(roomId);

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

  final TextEditingController _roomIdController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _showScanner = true;

  @override
  void dispose() {
    _roomIdController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _manualJoin() async {
    final roomId = _roomIdController.text.trim();
    final password = _passwordController.text.trim();

    if (roomId.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please enter both Room ID and Password.")));
      return;
    }

    await _processScannedCode("$roomId|$password");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_showScanner ? "Scan Room QR" : "Enter Room Code"),
        actions: [
          TextButton(
            onPressed: () => setState(() => _showScanner = !_showScanner),
            child: Text(_showScanner ? "Manual Entry" : "Scan QR", style: const TextStyle(color: Colors.white)),
          )
        ],
      ),
      body: Stack(
        children: [
          if (_showScanner)
            MobileScanner(
              onDetect: (capture) {
                final List<Barcode> barcodes = capture.barcodes;
                for (final barcode in barcodes) {
                  if (barcode.rawValue != null) {
                    _processScannedCode(barcode.rawValue!);
                    break;
                  }
                }
              },
            )
          else
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.meeting_room, size: 80, color: Colors.teal),
                  const SizedBox(height: 24),
                  const Text("Join via Code", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text("Enter the Room ID and Password provided by your Admin.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _roomIdController,
                    decoration: const InputDecoration(labelText: "Room ID", border: OutlineInputBorder()),
                    enabled: !_isProcessing,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordController,
                    decoration: const InputDecoration(labelText: "Password", border: OutlineInputBorder()),
                    enabled: !_isProcessing,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isProcessing ? null : _manualJoin,
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                      child: const Text("Join Room"),
                    ),
                  )
                ],
              ),
            ),
          
          if (_isProcessing) 
            Container(
              color: Colors.black54,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
