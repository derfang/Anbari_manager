import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/chore_service.dart';

class RoomSettingsScreen extends StatefulWidget {
  const RoomSettingsScreen({super.key});

  @override
  State<RoomSettingsScreen> createState() => _RoomSettingsScreenState();
}

class _RoomSettingsScreenState extends State<RoomSettingsScreen> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ChoreService _choreService = ChoreService();

  String? _roomId;
  String? _roomPassword;
  bool _isAdmin = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRoomDetails();
  }

  Future<void> _loadRoomDetails() async {
    final user = _auth.currentUser;
    if (user == null) return;

    final userDoc = await _db.collection('users').doc(user.uid).get();
    if (userDoc.exists) {
      final userData = userDoc.data() as Map<String, dynamic>?;
      final roomId = userData?['currentRoomId'] ?? userData?['roomId'];
      
      bool isAdmin = false;
      if (roomId != null && userData?['roles'] != null && userData!['roles'][roomId] != null) {
        isAdmin = userData['roles'][roomId] == 'admin';
      } else {
        isAdmin = userData != null && (userData['role'] == 'admin' || userData['isAdmin'] == true);
      }

      final roomDoc = await _db.collection('rooms').doc(roomId).get();
      
      String? password;
      try {
        final data = roomDoc.data() as Map<String, dynamic>?;
        if (data != null && data.containsKey('password')) {
          password = data['password'];
        } else {
          throw Exception("Missing password field");
        }
      } catch (e) {
        // Fallback: auto-generate and save a password for legacy rooms
        password = "admin${DateTime.now().millisecond}";
        await _db.collection('rooms').doc(roomId).update({'password': password});
      }
      
      if (mounted) {
        setState(() {
          _roomId = roomId;
          _roomPassword = password;
          _isAdmin = isAdmin;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _removeUser(String userId, String userName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Remove Roommate?"),
        content: Text("Are you sure you want to remove $userName from the room? Their upcoming chores will be re-assigned."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(context, true), 
            child: const Text("Remove", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);
    try {
      final start = DateTime.now();
      final end = start.add(const Duration(days: 7));
      await _choreService.removeUserAndRecalculate(
        userId: userId,
        roomId: _roomId!,
        startDate: start,
        endDate: end,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Roommate removed and schedule updated.")));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_roomId == null || _roomPassword == null) {
      return const Scaffold(body: Center(child: Text("Error loading room details.")));
    }

    final qrData = "$_roomId|$_roomPassword";

    return Scaffold(
      appBar: AppBar(title: const Text("Room Settings")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text(
              "Invite Roommates",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "Have your roommates scan this QR code on the 'Join Room' screen to join.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Center(
              child: Card(
                elevation: 4,
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: QrImageView(
                    data: qrData,
                    version: QrVersions.auto,
                    size: 200.0,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Room Members",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: _db.collection('users').where('roomId', isEqualTo: _roomId).snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final users = snapshot.data!.docs;

                  return ListView.builder(
                    itemCount: users.length,
                    itemBuilder: (context, index) {
                      final doc = users[index];
                      final data = doc.data() as Map<String, dynamic>;
                      final isMe = doc.id == _auth.currentUser?.uid;
                      final isUserAdmin = data['role'] == 'admin' || data['isAdmin'] == true;

                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.teal,
                            child: Text(
                              data['name']?.substring(0, 1).toUpperCase() ?? "?",
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          title: Row(
                            children: [
                              Text(data['name'] ?? "Unknown", style: const TextStyle(fontWeight: FontWeight.bold)),
                              if (isUserAdmin)
                                const Padding(
                                  padding: EdgeInsets.only(left: 8.0),
                                  child: Icon(Icons.star, color: Colors.orange, size: 16),
                                ),
                            ],
                          ),
                          subtitle: Text("${data['points']?.toStringAsFixed(1) ?? '0.0'} pts"),
                          trailing: isMe 
                            ? const Chip(label: Text("You"))
                            : (_isAdmin ? PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'remove') {
                                    _removeUser(doc.id, data['name']);
                                  } else if (value == 'absent') {
                                    _markAbsent(doc.id, data['name'] ?? 'Unknown');
                                  }
                                },
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'absent',
                                    child: Row(children: [Icon(Icons.date_range, color: Colors.orange, size: 20), SizedBox(width: 8), Text("Mark Absent")]),
                                  ),
                                  const PopupMenuItem(
                                    value: 'remove',
                                    child: Row(children: [Icon(Icons.person_remove, color: Colors.red, size: 20), SizedBox(width: 8), Text("Remove User", style: TextStyle(color: Colors.red))]),
                                  ),
                                ],
                              ) : null),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            if (_isAdmin) ...[
              const SizedBox(height: 24),
              const Divider(color: Colors.redAccent),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Danger Zone",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.redAccent),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _resetRoom,
                  icon: const Icon(Icons.warning_amber_rounded, color: Colors.red),
                  label: const Text("Reset Room Leaderboard & Schedule", style: TextStyle(color: Colors.red)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _markAbsent(String userId, String userName) async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (picked != null) {
      setState(() => _isLoading = true);
      try {
        final docRef = await _db.collection('absences').add({
          'userId': userId,
          'userName': userName,
          'roomId': _roomId,
          'startDate': Timestamp.fromDate(picked.start),
          'endDate': Timestamp.fromDate(picked.end),
          'status': 'approved',
          'createdAt': FieldValue.serverTimestamp(),
        });
        
        await _choreService.approveAbsenceAndRecalculate(
          absenceDocRef: docRef,
          roomId: _roomId!,
          currentUserId: _auth.currentUser!.uid,
          startDate: picked.start,
          endDate: picked.end,
        );
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$userName marked as absent.")));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
        }
      }
      setState(() => _isLoading = false);
    }
  }

  Future<void> _resetRoom() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Reset Room?"),
        content: const Text(
          "Are you sure you want to reset this room? This will set all roommate points to 0, wipe all generated chores, and clear all dispute reports.\n\nChores themselves and absences will be preserved.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(context, true), 
            child: const Text("Reset", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);

    try {
      final batch = _db.batch();

      // 1. Reset points for all users in this room
      final usersSnapshot = await _db.collection('users')
          .where(Filter.or(Filter('roomId', isEqualTo: _roomId), Filter('roomIds', arrayContains: _roomId)))
          .get();
      for (var doc in usersSnapshot.docs) {
        batch.update(doc.reference, {'points': 0.0});
      }

      // 2. Wipe all assignments
      final assignmentsSnapshot = await _db.collection('assignments').where('roomId', isEqualTo: _roomId).get();
      for (var doc in assignmentsSnapshot.docs) {
        batch.delete(doc.reference);
      }

      // 3. Wipe all reports
      final reportsSnapshot = await _db.collection('reports').where('roomId', isEqualTo: _roomId).get();
      for (var doc in reportsSnapshot.docs) {
        batch.delete(doc.reference);
      }

      // 4. Wipe all history
      final historySnapshot = await _db.collection('chore_history').where('roomId', isEqualTo: _roomId).get();
      for (var doc in historySnapshot.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();

      // Regenerate the clean schedule
      await _choreService.recalculateSchedule(_roomId!);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Room has been successfully reset!")));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error resetting room: $e")));
      }
    }

    if (mounted) setState(() => _isLoading = false);
  }
}
