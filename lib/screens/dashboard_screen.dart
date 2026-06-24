import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'manage_chores_screen.dart';
import 'auth_screen.dart';
import 'absence_screen.dart';
import 'room_settings_screen.dart';
import '../services/chore_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ChoreService _choreService = ChoreService();
  
  String? _roomId;
  bool _isLoading = true;
  bool _isAdmin = false;
  int _weekOffset = 0;

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
          final data = doc.data() as Map<String, dynamic>?;
          _isAdmin = data != null && (data['role'] == 'admin' || data['isAdmin'] == true);
          _isLoading = false;
        });
        
        // Background cleanup of old weeks
        if (_roomId != null && _roomId!.isNotEmpty) {
          _choreService.cleanOldAssignments(_roomId!);
        }
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
          // Removed manual calendar generation icon as schedule generation is now fully automated
          IconButton(
            icon: const Icon(Icons.flight_takeoff),
            tooltip: "Absences",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AbsenceScreen()),
              );
            },
          ),
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
          if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.group),
              tooltip: "Room Settings",
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const RoomSettingsScreen()),
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
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- SECTION 0: Pending Absences ---
            StreamBuilder<QuerySnapshot>(
              stream: _db.collection('absences')
                .where('roomId', isEqualTo: _roomId)
                .where('status', isEqualTo: 'pending')
                .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return const SizedBox.shrink();
                final pendingDocs = snapshot.data!.docs.where((doc) => (doc.data() as Map<String, dynamic>)['userId'] != _auth.currentUser?.uid).toList();
                if (pendingDocs.isEmpty) return const SizedBox.shrink();

                return Column(
                  children: pendingDocs.map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final start = (data['startDate'] as Timestamp).toDate();
                    final end = (data['endDate'] as Timestamp).toDate();
                    return MaterialBanner(
                      backgroundColor: Colors.orange.shade100,
                      leading: const Icon(Icons.notification_important, color: Colors.orange),
                      content: Text("${data['userName']} requested absence from ${start.month}/${start.day} to ${end.month}/${end.day}."),
                      actions: [
                        TextButton(
                          onPressed: () async {
                            try {
                              await _choreService.approveAbsenceAndRecalculate(
                                absenceDocRef: doc.reference,
                                roomId: _roomId!,
                                currentUserId: _auth.currentUser!.uid,
                                startDate: start,
                                endDate: end,
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Absence approved and schedule updated!")));
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
                              }
                            }
                          },
                          child: const Text("APPROVE"),
                        ),
                      ],
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 12),

            // --- SECTION 1: Personal Tasks ---
            const Text(
              "My Chores This Week",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            
            StreamBuilder<QuerySnapshot>(
              stream: _db.collection('assignments')
                .where('roomId', isEqualTo: _roomId)
                .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text("Error loading chores: ${snapshot.error}", style: const TextStyle(color: Colors.red)),
                  );
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                
                final currentWeekBounds = _choreService.getWeekBounds(0);
                final startBounds = currentWeekBounds[0];
                final endBounds = currentWeekBounds[1];

                final allTasks = snapshot.hasData ? snapshot.data!.docs : [];
                var myTasks = allTasks.where((doc) {
                  try {
                    final data = doc.data() as Map<String, dynamic>;
                    if (data['assignedToUserId'] != _auth.currentUser?.uid) return false;
                    if (data['isCompleted'] == true) return false;

                    final date = (data['date'] as Timestamp).toDate();
                    return date.compareTo(startBounds) >= 0 && date.compareTo(endBounds) <= 0;
                  } catch (e) {
                    return false;
                  }
                }).toList();

                // Sort by date ascending
                myTasks.sort((a, b) {
                  final dateA = (a['date'] as Timestamp).toDate();
                  final dateB = (b['date'] as Timestamp).toDate();
                  return dateA.compareTo(dateB);
                });

                // Deduplicate by choreId
                final seenChores = <String>{};
                myTasks = myTasks.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final choreId = data['choreId'] as String;
                  if (seenChores.contains(choreId)) return false;
                  seenChores.add(choreId);
                  return true;
                }).toList();

                if (myTasks.isEmpty) {
                  return const Card(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text("You have no pending chores! Time to relax on the couch. 🛋️"),
                    ),
                  );
                }

                return Column(
                  children: myTasks.map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    bool isSubmitting = false;

                    return StatefulBuilder(
                      builder: (context, setBtnState) {
                        return Card(
                          elevation: 2,
                          margin: const EdgeInsets.only(bottom: 12),
                          child: ListTile(
                            leading: const Icon(Icons.cleaning_services, size: 36, color: Colors.teal),
                            title: Text(data['choreTitle'] ?? data['choreId'], style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text("Due: ${data['dayOfWeek'] ?? data['day']}"),
                            trailing: FilledButton(
                              onPressed: isSubmitting ? null : () async {
                                setBtnState(() => isSubmitting = true);
                                try {
                                  await _choreService.completeChore(
                                    roomId: _roomId!,
                                    choreId: data['choreId'],
                                    doerIds: [data['assignedToUserId']],
                                  );
                                  await doc.reference.update({'isCompleted': true});
                                } catch (e) {
                                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
                                }
                                if (context.mounted) setBtnState(() => isSubmitting = false);
                              },
                              child: isSubmitting 
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
                                : const Text("Done"),
                            ),
                          ),
                        );
                      }
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 24),

            // --- SECTION 2: The Room Matrix ---
            Builder(
              builder: (context) {
                final bounds = _choreService.getWeekBounds(_weekOffset);
                final startFormat = DateFormat('MMM d').format(bounds[0]);
                final endFormat = DateFormat('MMM d').format(bounds[1]);

                return Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left), 
                          onPressed: _weekOffset > -1 ? () => setState(() => _weekOffset--) : null,
                        ),
                        Text(
                          "Matrix: $startFormat - $endFormat",
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right), 
                          onPressed: _weekOffset < 1 ? () => setState(() => _weekOffset++) : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                );
              }
            ),
            
            // The Interactive Grid Matrix
            StreamBuilder<QuerySnapshot>(
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
                    // Stream 2: Listen for the actual assignments (filtered locally to avoid index errors)
                    stream: _db.collection('assignments')
                        .where('roomId', isEqualTo: _roomId)
                        .snapshots(),
                    builder: (context, assignmentSnapshot) {
                      if (!assignmentSnapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final startBounds = _choreService.getWeekBounds(_weekOffset)[0];
                      final endBounds = _choreService.getWeekBounds(_weekOffset)[1];
                      
                      final assignments = assignmentSnapshot.data!.docs.where((doc) {
                        try {
                          final date = (doc['date'] as Timestamp).toDate();
                          return date.compareTo(startBounds) >= 0 && date.compareTo(endBounds) <= 0;
                        } catch (e) {
                          return false;
                        }
                      }).toList();

                      if (assignments.isEmpty) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16.0),
                            child: Text("No chores scheduled for this week.", style: TextStyle(color: Colors.grey, fontSize: 16)),
                          ),
                        );
                      }

                      // Helper maps: "choreId_dayOfWeek" -> name / isCompleted
                      Map<String, String> assignmentMap = {};
                      Map<String, bool> completionMap = {};
                      for (var doc in assignments) {
                        String key = "${doc['choreId']}_${doc['dayOfWeek']}";
                        assignmentMap[key] = doc['assignedToName'] ?? 'Unassigned';
                        completionMap[key] = doc['isCompleted'] == true;
                      }

                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
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
                                    bool isDone = completionMap[lookupKey] ?? false;

                                    return DataCell(
                                      Container(
                                        width: double.infinity,
                                        color: isDone ? Colors.green.shade200 : null,
                                        alignment: Alignment.center,
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
                      );
                    },
                  );
                },
              ),
          ],
        ),
      ),
      ),
    );
  }
}