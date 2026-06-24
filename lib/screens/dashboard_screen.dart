import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'manage_chores_screen.dart';
import 'auth_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  
  String? _roomId;
  bool _isLoading = true;

  // The custom regional week layout (Saturday to Friday)
  final List<String> _weekDays = [
    'Saturday',
    'Sunday',
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday'
  ];

  @override
  void initState() {
    super.initState();
    _loadUserRoom();
  }

  // Fetch the current user's assigned room from Firestore
  Future<void> _loadUserRoom() async {
    final user = _auth.currentUser;
    if (user != null) {
      final doc = await _db.collection('users').doc(user.uid).get();
      if (mounted) {
        setState(() {
          _roomId = doc['roomId'];
          _isLoading = false;
        });
      }
    }
  }

  // Securely log the user out and clear the navigation stack
  Future<void> _logout() async {
    await _auth.signOut();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const AuthScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show a loader while we fetch the Room ID
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Apartment Dashboard"),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: "Manage Chores",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ManageChoresScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: "Logout",
            onPressed: _logout,
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- SECTION 1: Personal Tasks ---
            const Text(
              "My Chores This Week",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            
            // Temporary static card until we wire up the personal assignment filter
            Card(
              elevation: 2,
              child: ListTile(
                leading: const Icon(Icons.delete_outline, size: 36, color: Colors.teal),
                title: const Text("Take out the Trash", style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text("Due: Wednesday"),
                trailing: FilledButton(
                  onPressed: () {},
                  child: const Text("Done"),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // --- SECTION 2: The Room Matrix ---
            const Text(
              "Saturday-to-Friday Matrix",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            
            // The Interactive Grid Matrix
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                // Stream 1: Listen for the list of available chores in this room
                stream: _db.collection('chores').where('roomId', isEqualTo: _roomId).snapshots(),
                builder: (context, choreSnapshot) {
                  if (!choreSnapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final chores = choreSnapshot.data!.docs;

                  if (chores.isEmpty) {
                    return const Center(
                      child: Text(
                        "No chores found.\nTap the settings gear to add some!", 
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      )
                    );
                  }

                  return StreamBuilder<QuerySnapshot>(
                    // Stream 2: Listen for the actual assignments linking people to chores
                    stream: _db.collection('assignments').where('roomId', isEqualTo: _roomId).snapshots(),
                    builder: (context, assignmentSnapshot) {
                      if (!assignmentSnapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final assignments = assignmentSnapshot.data!.docs;

                      // Helper map to lookup assignment names quickly: "choreId_day" -> "Roommate Name"
                      Map<String, String> assignmentMap = {};
                      for (var doc in assignments) {
                        String key = "${doc['choreId']}_${doc['day']}";
                        assignmentMap[key] = doc['assignedToName'] ?? 'Unassigned';
                      }

                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.vertical,
                          child: DataTable(
                            border: TableBorder.all(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(8)),
                            headingRowColor: WidgetStateProperty.all(Colors.teal.withOpacity(0.1)),
                            columns: [
                              const DataColumn(label: Text('Chore', style: TextStyle(fontWeight: FontWeight.bold))),
                              // Generate columns dynamically for Sat -> Fri
                              ..._weekDays.map((day) => DataColumn(
                                    label: Text(day.substring(0, 3), style: const TextStyle(fontWeight: FontWeight.bold)),
                                  )),
                            ],
                            rows: chores.map((chore) {
                              return DataRow(
                                cells: [
                                  DataCell(
                                    Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(chore['title'], style: const TextStyle(fontWeight: FontWeight.w600)),
                                        Text("${chore['points']} pts", style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                                      ],
                                    ),
                                  ),
                                  // Generate the inner cells intersecting chores with days
                                  ..._weekDays.map((day) {
                                    String lookupKey = "${chore.id}_$day";
                                    String assignedName = assignmentMap[lookupKey] ?? '-';
                                    
                                    return DataCell(
                                      Center(
                                        child: Text(
                                          assignedName,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: assignedName != '-' ? FontWeight.bold : FontWeight.normal,
                                            color: assignedName != '-' ? Colors.teal.shade700 : Colors.grey,
                                          ),
                                        ),
                                      ),
                                    );
                                  }),
                                ],
                              );
                            }).toList(),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}