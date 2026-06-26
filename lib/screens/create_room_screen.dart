import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math';
import 'dashboard_screen.dart';

class CreateRoomScreen extends StatefulWidget {
  final String creatorId;
  final String creatorName;

  const CreateRoomScreen({
    super.key,
    required this.creatorId,
    required this.creatorName,
  });

  @override
  State<CreateRoomScreen> createState() => _CreateRoomScreenState();
}

class _CreateRoomScreenState extends State<CreateRoomScreen> {
  final TextEditingController _roomNameController = TextEditingController();
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  bool _isLoading = false;

  // Helper method to generate a short, unique 6-character alphanumeric room code
  String _generateRoomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // Excluded easily confused letters like I, O, 1, 0
    final random = Random();
    return List.generate(6, (index) => chars[random.nextInt(chars.length)]).join();
  }

  // Inject a starter pack of chores into the database for this new room
  Future<void> _generateDefaultChores(String roomId) async {
    final List<Map<String, dynamic>> defaultTasks = [
      {'title': 'Take out the Trash', 'icon': 'delete', 'points': 1.0, 'crew': 1, 'frequencyDays': 7, 'roomId': roomId},
      {'title': 'Clean the Bathroom', 'icon': 'shower', 'points': 3.0, 'crew': 1, 'frequencyDays': 7, 'roomId': roomId},
      {'title': 'Sweep & Mop Floors', 'icon': 'wash', 'points': 2.0, 'crew': 1, 'frequencyDays': 7, 'roomId': roomId},
      {'title': 'Wipe Kitchen Counters', 'icon': 'kitchen', 'points': 1.0, 'crew': 1, 'frequencyDays': 1, 'roomId': roomId},
      {'title': 'Vacuum the Apartment', 'icon': 'cleaning_services', 'points': 2.0, 'crew': 1, 'frequencyDays': 7, 'roomId': roomId},
    ];

    final batch = _db.batch();
    
    for (var task in defaultTasks) {
      final docRef = _db.collection('chores').doc();
      batch.set(docRef, task);
    }
    
    await batch.commit();
  }

  Future<void> _handleCreateRoom() async {
    final roomName = _roomNameController.text.trim();
    if (roomName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter an apartment or room name!")),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final String roomId = _generateRoomCode();
      final String roomPassword = _generateRoomCode();

      // 1. Create the master room entry
      await _db.collection('rooms').doc(roomId).set({
        'id': roomId,
        'name': roomName,
        'password': roomPassword,
        'creatorId': widget.creatorId,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // 2. Link the current user to this room and assign them as Admin
      await _db.collection('users').doc(widget.creatorId).set({
        'uid': widget.creatorId,
        'name': widget.creatorName,
        'roomId': roomId, // legacy fallback
        'currentRoomId': roomId,
        'roomIds': FieldValue.arrayUnion([roomId]),
        'roles': {roomId: 'admin'}, // map role per room
        'joinedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 3. Inject the standard default chores automatically
      await _generateDefaultChores(roomId);

      if (!mounted) return;

      // 4. Pop the Create Screen. RoomGateWrapper will automatically route them to the new Dashboard!
      if (Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to create room: $e")),
      );
    }
  }

  @override
  void dispose() {
    _roomNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Setup Your Apartment"),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(
              Icons.home_work_outlined,
              size: 80,
              color: Colors.teal,
            ),
            const SizedBox(height: 24),
            const Text(
              "Create a New Room",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              "Hey ${widget.creatorName}, name your apartment space below. We'll generate a unique code for your roommates to join.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _roomNameController,
              decoration: const InputDecoration(
                labelText: "Apartment Name (e.g., Unit 4B, Dorm 202)",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.edit_road),
              ),
              textCapitalization: TextCapitalization.words,
              maxLength: 25,
              enabled: !_isLoading,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _isLoading ? null : _handleCreateRoom,
              icon: _isLoading 
                  ? const SizedBox(
                      width: 20, 
                      height: 20, 
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Icon(Icons.gite_outlined),
              label: Text(_isLoading ? "Generating Space..." : "Generate Room & Default Chores"),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}