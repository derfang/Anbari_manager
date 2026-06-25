import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'manage_chores_screen.dart';
import 'auth_screen.dart';
import 'absence_screen.dart';
import 'room_settings_screen.dart';
import '../services/chore_service.dart';
import 'room_selection_screen.dart';
import '../utils/chore_icons.dart';

class DashboardScreen extends StatefulWidget {
  final String? roomId;
  const DashboardScreen({super.key, this.roomId});

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
          final data = doc.data() as Map<String, dynamic>?;
          if (data != null) {
            _roomId = widget.roomId ?? data['currentRoomId'] ?? data['roomId'];
            
            // Check roles map first, fallback to legacy role/isAdmin fields
            if (data['roles'] != null && data['roles'][_roomId] != null) {
              _isAdmin = data['roles'][_roomId] == 'admin';
            } else {
              _isAdmin = (data['role'] == 'admin' || data['isAdmin'] == true);
            }
          }
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

  Future<void> _undoAssignment(String assignmentId) async {
    final doc = await _db.collection('assignments').doc(assignmentId).get();
    if (!doc.exists) return;
    
    final data = doc.data() as Map<String, dynamic>;
    final roomId = data['roomId'];
    final choreId = data['choreId'];
    final assignedToUserId = data['assignedToUserId'];

    try {
      // 1. Revert the math using ChoreService
      await _choreService.undoChore(
        roomId: roomId, 
        choreId: choreId, 
        doerIds: [assignedToUserId],
      );

      // 2. Mark the assignment as pending and disputed again
      await _db.collection('assignments').doc(assignmentId).update({
        'isCompleted': false,
        'disputed': true,
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error undoing chore: $e")));
    }
  }

  Future<void> _showFalseReportDialog({
    required String assignmentId,
    required String choreTitle,
    required String dayOfWeek,
  }) async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) return;

    final results = await Future.wait([
      _db.collection('reports')
          .where('assignmentId', isEqualTo: assignmentId)
          .where('type', isEqualTo: 'false_completion')
          .where('status', isEqualTo: 'pending')
          .limit(1).get(),
      _db.collection('reports')
          .where('assignmentId', isEqualTo: assignmentId)
          .where('type', isEqualTo: 'completion_request')
          .where('status', isEqualTo: 'resolved')
          .limit(1).get(),
      _db.collection('users').where('roomId', isEqualTo: _roomId).get(),
    ]);

    final reportQuery = results[0] as QuerySnapshot;
    final resolvedCompletionQuery = results[1] as QuerySnapshot;
    final usersSnapshot = results[2] as QuerySnapshot;
    final teamSize = usersSnapshot.docs.length;
    final threshold = (teamSize * 2 / 3).ceil();

    if (!mounted) return;

    // Prevent double-jeopardy: If the room voted it was done, it can't be reported as false again.
    if (resolvedCompletionQuery.docs.isNotEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Chore Verified"),
          content: const Text("This chore's completion was democratically verified by a roommate vote. It can no longer be reported as false."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close")),
          ],
        ),
      );
      return;
    }

    if (reportQuery.docs.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Report False Completion"),
          content: Text(
            "Report \"$choreTitle\" on $dayOfWeek as falsely marked done?\n\n"
            "If $threshold out of $teamSize roommates approve, it will be undone.",
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _db.collection('reports').add({
                  'assignmentId': assignmentId,
                  'choreTitle': choreTitle,
                  'dayOfWeek': dayOfWeek,
                  'roomId': _roomId,
                  'reportedBy': currentUser.uid,
                  'approvals': [currentUser.uid],
                  'status': 'pending',
                  'type': 'false_completion',
                  'createdAt': FieldValue.serverTimestamp(),
                });
                if (1 >= threshold) await _undoAssignment(assignmentId);
              },
              child: const Text("Report"),
            ),
          ],
        ),
      );
    } else {
      final reportDoc = reportQuery.docs.first;
      final reportData = reportDoc.data() as Map<String, dynamic>;
      final approvals = List<String>.from(reportData['approvals'] ?? []);
      final alreadyApproved = approvals.contains(currentUser.uid);

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("False Completion Report"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("\"$choreTitle\" on $dayOfWeek was reported as falsely done."),
              const SizedBox(height: 12),
              Text("Approvals: ${approvals.length} / $teamSize  (need $threshold to undo)"),
              if (alreadyApproved)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text("You already approved this report.", style: TextStyle(color: Colors.grey)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close")),
            if (!alreadyApproved)
              FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final newApprovals = [...approvals, currentUser.uid];
                  await reportDoc.reference.update({'approvals': newApprovals});
                  if (newApprovals.length >= threshold) {
                    await _undoAssignment(assignmentId);
                    await reportDoc.reference.update({'status': 'resolved'});
                  }
                },
                child: const Text("Approve Report"),
              ),
          ],
        ),
      );
    }
  }

  Future<void> _requestCompletionVoteDialog({
    required String assignmentId,
    required String choreTitle,
  }) async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) return;

    final reportQuery = await _db.collection('reports')
        .where('assignmentId', isEqualTo: assignmentId)
        .where('type', isEqualTo: 'completion_request')
        .where('status', isEqualTo: 'pending')
        .limit(1).get();

    if (!mounted) return;

    if (reportQuery.docs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("A completion vote is already pending!")));
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Chore Disputed"),
        content: Text(
          "\"$choreTitle\" was previously marked as incomplete by your roommates. "
          "You must request a 2/3 majority vote to mark it as done again."
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _db.collection('reports').add({
                'assignmentId': assignmentId,
                'choreTitle': choreTitle,
                'roomId': _roomId,
                'reportedBy': currentUser.uid,
                'approvals': [], // Only roommates vote
                'status': 'pending',
                'type': 'completion_request',
                'createdAt': FieldValue.serverTimestamp(),
              });
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Vote requested!")));
            },
            child: const Text("Request Vote"),
          ),
        ],
      ),
    );
  }

  Future<void> _showCompletionVoteDialog({
    required String assignmentId,
    required String choreTitle,
    required String choreId,
    required String assignedUserId,
  }) async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) return;

    final results = await Future.wait([
      _db.collection('reports')
          .where('assignmentId', isEqualTo: assignmentId)
          .where('type', isEqualTo: 'completion_request')
          .where('status', isEqualTo: 'pending')
          .limit(1).get(),
      _db.collection('users').where('roomId', isEqualTo: _roomId).get(),
    ]);

    final reportQuery = results[0] as QuerySnapshot;
    final usersSnapshot = results[1] as QuerySnapshot;
    final teamSize = usersSnapshot.docs.length;
    final threshold = (teamSize * 2 / 3).ceil();

    if (!mounted) return;

    if (reportQuery.docs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Only the assigned user can initiate a completion vote.")));
      return;
    }

    final reportDoc = reportQuery.docs.first;
    final reportData = reportDoc.data() as Map<String, dynamic>;
    final approvals = List<String>.from(reportData['approvals'] ?? []);
    final alreadyApproved = approvals.contains(currentUser.uid);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Approve Completion"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("The assigned user claims \"$choreTitle\" is now fully completed."),
            const SizedBox(height: 12),
            Text("Approvals: ${approvals.length} / $teamSize  (need $threshold to complete)"),
            if (alreadyApproved)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text("You already approved this completion.", style: TextStyle(color: Colors.grey)),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close")),
          if (!alreadyApproved)
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final newApprovals = [...approvals, currentUser.uid];
                await reportDoc.reference.update({'approvals': newApprovals});
                if (newApprovals.length >= threshold) {
                  await _choreService.completeChore(
                    roomId: _roomId!,
                    choreId: choreId,
                    doerIds: [assignedUserId],
                  );
                  await _db.collection('assignments').doc(assignmentId).update({'isCompleted': true, 'disputed': false});
                  await reportDoc.reference.update({'status': 'resolved'});
                }
              },
              child: const Text("Approve Completion"),
            ),
        ],
      ),
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
            icon: const Icon(Icons.swap_horiz),
            tooltip: "Switch Rooms",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const RoomSelectionScreen()),
              );
            },
          ),
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
            // --- SECTION 0b: Pending False-Completion Reports ---
            StreamBuilder<QuerySnapshot>(
              stream: _db.collection('reports')
                .where('roomId', isEqualTo: _roomId)
                .where('status', isEqualTo: 'pending')
                .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return const SizedBox.shrink();
                final currentUid = _auth.currentUser?.uid;
                final pendingReports = snapshot.data!.docs.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final approvals = List<String>.from(data['approvals'] ?? []);
                  final ignored = List<String>.from(data['ignored'] ?? []);
                  return !approvals.contains(currentUid) && !ignored.contains(currentUid);
                }).toList();
                if (pendingReports.isEmpty) return const SizedBox.shrink();

                return Column(
                  children: pendingReports.map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final isCompletionReq = data['type'] == 'completion_request';
                    final titleText = isCompletionReq
                        ? "\"${data['choreTitle']}\" completion vote requested by assigned user."
                        : "\"${data['choreTitle']}\" on ${data['dayOfWeek'] ?? 'this week'} was reported as falsely done.";

                    return MaterialBanner(
                      backgroundColor: isCompletionReq ? Colors.blue.shade50 : Colors.red.shade50,
                      leading: Icon(isCompletionReq ? Icons.how_to_reg : Icons.flag, color: isCompletionReq ? Colors.blue : Colors.red),
                      content: Text(titleText),
                      actions: [
                        TextButton(
                          onPressed: () async {
                            final ignored = List<String>.from(data['ignored'] ?? []);
                            await doc.reference.update({'ignored': [...ignored, currentUid!]});
                          },
                          child: const Text("IGNORE"),
                        ),
                        TextButton(
                          onPressed: () async {
                            final approvals = List<String>.from(data['approvals'] ?? []);
                            final newApprovals = [...approvals, currentUid!];
                            await doc.reference.update({'approvals': newApprovals});

                            final usersSnap = await _db.collection('users').where('roomId', isEqualTo: _roomId).get();
                            final threshold = (usersSnap.docs.length * 2 / 3).ceil();
                            if (newApprovals.length >= threshold) {
                              if (isCompletionReq) {
                                final assignmentDoc = await _db.collection('assignments').doc(data['assignmentId']).get();
                                if (assignmentDoc.exists) {
                                  final assignData = assignmentDoc.data() as Map<String, dynamic>;
                                  await _choreService.completeChore(
                                    roomId: _roomId!,
                                    choreId: assignData['choreId'],
                                    doerIds: [assignData['assignedToUserId']],
                                  );
                                  await assignmentDoc.reference.update({'isCompleted': true, 'disputed': false});
                                }
                                await doc.reference.update({'status': 'resolved'});
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text("Completion approved! \"${data['choreTitle']}\" marked done.")),
                                  );
                                }
                              } else {
                                await _undoAssignment(data['assignmentId']);
                                await doc.reference.update({'status': 'resolved'});
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text("Report approved! \"${data['choreTitle']}\" marked as undone.")),
                                  );
                                }
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
                            leading: Icon(
                              choreIcons[data['choreIcon']] ?? Icons.cleaning_services,
                              size: 36,
                              color: Colors.teal,
                            ),
                            title: Text(data['choreTitle'] ?? data['choreId'], style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text("Due: ${data['dayOfWeek'] ?? data['day']}"),
                            trailing: FilledButton(
                              onPressed: isSubmitting ? null : () async {
                                if (data['disputed'] == true) {
                                  await _requestCompletionVoteDialog(
                                    assignmentId: doc.id,
                                    choreTitle: data['choreTitle'] ?? data['choreId'],
                                  );
                                  return;
                                }

                                setBtnState(() => isSubmitting = true);
                                try {
                                  await _choreService.completeChore(
                                    roomId: _roomId!,
                                    choreId: data['choreId'],
                                    doerIds: [data['assignedToUserId']],
                                  );
                                  await doc.reference.update({'isCompleted': true});
                                  // Clear any existing reports so a fresh report can be filed
                                  final oldReports = await _db.collection('reports')
                                      .where('assignmentId', isEqualTo: doc.id)
                                      .get();
                                  for (final r in oldReports.docs) {
                                    await r.reference.delete();
                                  }
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

                      // Helper maps: "choreTitle_dayOfWeek" -> name / isCompleted / docId / userId
                      Map<String, String> assignmentMap = {};
                      Map<String, bool> completionMap = {};
                      Map<String, String> assignmentDocIdMap = {};
                      Map<String, String> assignedUserIdMap = {};
                      Map<String, bool> disputedMap = {};
                      for (var doc in assignments) {
                        final data = doc.data() as Map<String, dynamic>;
                        String key = "${data['choreId']}_${data['dayOfWeek']}";
                        assignmentMap[key] = data['assignedToName'] ?? 'Unassigned';
                        completionMap[key] = data['isCompleted'] == true;
                        assignmentDocIdMap[key] = doc.id;
                        assignedUserIdMap[key] = data['assignedToUserId'];
                        disputedMap[key] = data['disputed'] == true;
                      }

                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          border: TableBorder.all(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(8)),
                          headingRowColor: WidgetStateProperty.all(Colors.teal.withOpacity(0.1)),
                          columnSpacing: 0,
                          horizontalMargin: 12,
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
                                    final String lookupKey = "${chore.id}_$day";
                                    final String assignedName = assignmentMap[lookupKey] ?? '-';
                                    final bool isDone = completionMap[lookupKey] ?? false;
                                    final String? assignmentDocId = assignmentDocIdMap[lookupKey];
                                    final String? assignedUserId = assignedUserIdMap[lookupKey];
                                    final bool isDisputed = disputedMap[lookupKey] ?? false;
                                    final bool isMyChore = assignedUserId == _auth.currentUser?.uid;

                                    return DataCell(
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.symmetric(horizontal: 12),
                                        color: isDone ? Colors.green.shade300 : (isDisputed ? Colors.orange.shade100 : null),
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
                                      onTap: assignmentDocId != null
                                          ? () {
                                              if (isDone) {
                                                _showFalseReportDialog(
                                                  assignmentId: assignmentDocId,
                                                  choreTitle: chore['title'],
                                                  dayOfWeek: day,
                                                );
                                              } else if (isDisputed) {
                                                if (isMyChore) {
                                                  _requestCompletionVoteDialog(
                                                    assignmentId: assignmentDocId,
                                                    choreTitle: chore['title'],
                                                  );
                                                } else {
                                                  _showCompletionVoteDialog(
                                                    assignmentId: assignmentDocId,
                                                    choreTitle: chore['title'],
                                                    choreId: chore.id,
                                                    assignedUserId: assignedUserId!,
                                                  );
                                                }
                                              } else if (isMyChore) {
                                                showDialog(
                                                  context: context,
                                                  builder: (ctx) => AlertDialog(
                                                    title: const Text("Mark Chore Done?"),
                                                    content: Text("Are you finished with \"${chore['title']}\"?"),
                                                    actions: [
                                                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
                                                      FilledButton(
                                                        onPressed: () async {
                                                          Navigator.pop(ctx);
                                                          try {
                                                            await _choreService.completeChore(
                                                              roomId: _roomId!,
                                                              choreId: chore.id,
                                                              doerIds: [assignedUserId!],
                                                            );
                                                            await _db.collection('assignments').doc(assignmentDocId).update({'isCompleted': true});
                                                          } catch (e) {
                                                            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
                                                          }
                                                        },
                                                        child: const Text("Mark Done"),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              } else {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(content: Text("Only $assignedName can mark this done!")),
                                                );
                                              }
                                            }
                                          : null,
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
              
              const SizedBox(height: 32),
              const Text("Roommate Leaderboard", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              StreamBuilder<QuerySnapshot>(
                stream: _db.collection('users')
                  .where(Filter.or(
                    Filter('roomId', isEqualTo: _roomId),
                    Filter('roomIds', arrayContains: _roomId)
                  ))
                  .snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                  final users = snapshot.data!.docs.toList();
                  
                  // Sort locally to avoid Firestore composite index requirements
                  users.sort((a, b) {
                    final dataA = a.data() as Map<String, dynamic>;
                    final dataB = b.data() as Map<String, dynamic>;
                    final ptsA = (dataA['points'] ?? 0.0).toDouble();
                    final ptsB = (dataB['points'] ?? 0.0).toDouble();
                    return ptsB.compareTo(ptsA);
                  });

                  if (users.isEmpty) {
                    return const Card(child: Padding(padding: EdgeInsets.all(16), child: Text("No roommates found.")));
                  }

                  return Card(
                    elevation: 2,
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: users.length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final userData = users[index].data() as Map<String, dynamic>;
                        final points = (userData['points'] ?? 0.0).toDouble();
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: index == 0 ? Colors.amber : Colors.teal.shade100,
                            child: index == 0 
                                ? const Icon(Icons.emoji_events, color: Colors.white, size: 20)
                                : Text("${index + 1}", style: TextStyle(color: Colors.teal.shade800, fontWeight: FontWeight.bold)),
                          ),
                          title: Text(userData['name'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.w600)),
                          trailing: Text("${points.toStringAsFixed(1)} pts", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        );
                      },
                    ),
                  );
                },
              ),
              const SizedBox(height: 32),
          ],
        ),
      ),
      ),
    );
  }
}