import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'create_room_screen.dart';
import 'join_room_screen.dart';
import 'auth_screen.dart';

class RoomSelectionScreen extends StatefulWidget {
  const RoomSelectionScreen({super.key});

  @override
  State<RoomSelectionScreen> createState() => _RoomSelectionScreenState();
}

class _RoomSelectionScreenState extends State<RoomSelectionScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> _logout() async {
    await _auth.signOut();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const AuthScreen()),
      (route) => false,
    );
  }

  Future<void> _switchRoom(String roomId) async {
    await _db.collection('users').doc(_auth.currentUser!.uid).update({
      'currentRoomId': roomId,
    });
    if (!mounted) return;
    // We just pop back. If we were pushed from Dashboard, this returns to Dashboard (which will rebuild if listening to Stream, or we might need to force a rebuild. 
    // Actually, AuthWrapper -> RoomGateWrapper is sitting at the root! 
    // If we pop back to the root, RoomGateWrapper will see the new currentRoomId and automatically load the new Dashboard!
    // But wait, if we are pushed ON TOP of Dashboard, we should pop.
    // If we are pushed ON TOP of RoomGateWrapper (which we aren't, RoomGateWrapper RETURNS RoomSelectionScreen directly), we don't pop.
    // To handle both:
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    if (user == null) return const Scaffold();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Your Apartments"),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
            tooltip: "Logout",
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _db.collection('users').doc(user.uid).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          
          Map<String, dynamic>? userData = snapshot.data!.data() as Map<String, dynamic>?;
          List<dynamic> roomIds = userData?['roomIds'] ?? [];
          if (roomIds.isEmpty && userData?['roomId'] != null) {
            roomIds = [userData!['roomId']];
          }

          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text("Welcome, ${user.displayName ?? 'Roommate'}!", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                
                if (roomIds.isNotEmpty) ...[
                  const Text("Select a Room:", style: TextStyle(fontSize: 18, color: Colors.grey)),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: roomIds.length,
                      itemBuilder: (context, index) {
                        String rId = roomIds[index];
                        return FutureBuilder<DocumentSnapshot>(
                          future: _db.collection('rooms').doc(rId).get(),
                          builder: (context, roomSnap) {
                            if (!roomSnap.hasData) return const Card(child: ListTile(title: Text("Loading...")));
                            if (!roomSnap.data!.exists) return const SizedBox.shrink();

                            final roomData = roomSnap.data!.data() as Map<String, dynamic>;
                            final isCurrent = rId == userData?['currentRoomId'];

                            return Card(
                              elevation: isCurrent ? 4 : 1,
                              color: isCurrent ? Colors.teal.shade50 : null,
                              child: ListTile(
                                leading: Icon(Icons.apartment, color: isCurrent ? Colors.teal : Colors.grey),
                                title: Text(roomData['name'] ?? 'Unknown Room', style: const TextStyle(fontWeight: FontWeight.bold)),
                                subtitle: Text("Room Code: $rId"),
                                trailing: isCurrent 
                                  ? const Chip(label: Text("Active", style: TextStyle(color: Colors.white, fontSize: 12)), backgroundColor: Colors.teal)
                                  : const Icon(Icons.arrow_forward_ios, size: 16),
                                onTap: () => _switchRoom(rId),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ] else ...[
                  const Expanded(
                    child: Center(
                      child: Text("You don't belong to any rooms yet.\nCreate or join one below!", textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Colors.grey)),
                    ),
                  ),
                ],
                
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text("Create a New Room"),
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(
                      builder: (context) => CreateRoomScreen(
                        creatorId: user.uid, 
                        creatorName: user.displayName ?? 'Unknown',
                      ),
                    ));
                  },
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text("Join an Existing Room"),
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(16)),
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(
                      builder: (context) => JoinRoomScreen(
                        userId: user.uid,
                        userName: user.displayName ?? 'Unknown',
                      ),
                    ));
                  },
                ),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }
}
