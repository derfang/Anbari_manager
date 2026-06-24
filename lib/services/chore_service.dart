import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'; // Required for debugPrint
import 'dart:math';

class ChoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  List<DateTime> getWeekBounds(int weekOffset) {
    DateTime now = DateTime.now();
    // In Dart, Monday is 1, Sunday is 7. We want Saturday (6) to be the start.
    int daysToSubtract = (now.weekday + 1) % 7;
    
    DateTime currentSaturday = DateTime(now.year, now.month, now.day).subtract(Duration(days: daysToSubtract));
    
    DateTime startOfWeek = currentSaturday.add(Duration(days: weekOffset * 7));
    DateTime endOfWeek = startOfWeek.add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
    
    return [startOfWeek, endOfWeek];
  }

  Future<void> cleanOldAssignments(String roomId) async {
    final bounds = getWeekBounds(-1); // Keep the previous week, delete anything older
    final pastSaturday = bounds[0];
    
    try {
      final assignmentsSnapshot = await _db.collection('assignments')
          .where('roomId', isEqualTo: roomId)
          .get();

      final batch = _db.batch();
      for (var doc in assignmentsSnapshot.docs) {
        try {
          final date = (doc.data()['date'] as Timestamp).toDate();
          if (date.compareTo(pastSaturday) < 0) {
            batch.delete(doc.reference);
          }
        } catch (_) {}
      }
      await batch.commit();
      debugPrint("Old assignments garbage collected.");
    } catch (e) {
      debugPrint("Error cleaning old assignments: $e");
    }
  }

  Future<void> recalculateSchedule(String roomId) async {
    await cleanOldAssignments(roomId);

    final currentBounds = getWeekBounds(0);
    final nextBounds = getWeekBounds(1);
    
    final startDate = currentBounds[0]; 
    final endDate = nextBounds[1];      

    try {
      final assignmentsSnapshot = await _db.collection('assignments')
          .where('roomId', isEqualTo: roomId)
          .where('isCompleted', isEqualTo: false)
          .get();

      final batch = _db.batch();
      for (var doc in assignmentsSnapshot.docs) {
        try {
          final date = (doc.data()['date'] as Timestamp).toDate();
          if (date.compareTo(startDate) >= 0 && date.compareTo(endDate) <= 0) {
            batch.delete(doc.reference);
          }
        } catch (_) {}
      }
      await batch.commit();

      await generateWeeklySchedule(
        roomId: roomId,
        startDate: startDate,
        endDate: endDate,
      );
    } catch (e) {
      debugPrint("Error recalculating schedule: $e");
      rethrow;
    }
  }

  Future<void> completeChore({
    required String roomId,
    required String choreId,
    required List<String> doerIds, // Supports multi-guy chores
  }) async {
    try {
      // 1. Fetch the chore details to get its effortValue
      final choreDoc = await _db.collection('chores').doc(choreId).get();
      if (!choreDoc.exists) throw Exception("Chore not found");

      final double effortValue = (choreDoc.data()?['effortValue'] ?? 0)
          .toDouble();

      // 2. Fetch all users in the room
      final usersSnapshot = await _db
          .collection('users')
          .where('roomId', isEqualTo: roomId) // FIXED: Named parameter syntax
          .get();

      List<DocumentSnapshot> presentSlackers = [];
      List<DocumentSnapshot> doers = [];

      // 3. Separate the guys doing the work from the guys on the couch
      for (var doc in usersSnapshot.docs) {
        final data = doc.data();

        if (doerIds.contains(doc.id)) {
          doers.add(doc);
        } else if (data['isAbsent'] != true) {
          presentSlackers.add(doc);
        }
      }

      // Prevent dividing by zero if everyone happens to be doing the chore or absent
      if (presentSlackers.isEmpty) {
        throw Exception(
          "No slackers to tax! Math engine aborted to prevent errors.",
        );
      }

      // 4. Calculate the zero-sum math
      final double slackerTax =
          (effortValue * doers.length) / presentSlackers.length;

      // 5. Create a WriteBatch to update everything simultaneously
      final batch = _db.batch();

      // Reward the doers (Increments their points by the chore value)
      for (var doer in doers) {
        batch.update(doer.reference, {
          'points': FieldValue.increment(effortValue),
        });
      }

      // Tax the slackers (Decrements their points by the tax value)
      for (var slacker in presentSlackers) {
        batch.update(slacker.reference, {
          'points': FieldValue.increment(-slackerTax),
        });
      }

      // 6. Log the history
      final historyRef = _db.collection('chore_history').doc();
      batch.set(historyRef, {
        'roomId': roomId,
        'choreId': choreId,
        'completedBy': doerIds,
        'completedAt': FieldValue.serverTimestamp(),
        'effortValue': effortValue,
      });

      // 7. Execute the batch
      await batch.commit();
      debugPrint(
        "Zero-sum points successfully distributed!",
      ); // FIXED: Using debugPrint
    } catch (e) {
      debugPrint("Error processing chore math: $e"); // FIXED: Using debugPrint
      rethrow;
    }
  }

  Future<void> generateWeeklySchedule({
    required String roomId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      // 1. Fetch users
      final usersSnapshot = await _db.collection('users').where('roomId', isEqualTo: roomId).get();
      List<Map<String, dynamic>> users = usersSnapshot.docs.map((doc) {
        var data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();

      // 2. Fetch chores
      final choresSnapshot = await _db.collection('chores').where('roomId', isEqualTo: roomId).get();
      List<Map<String, dynamic>> chores = choresSnapshot.docs.map((doc) {
        var data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();

      // 3. Fetch approved absences
      final absencesSnapshot = await _db.collection('absences')
          .where('roomId', isEqualTo: roomId)
          .where('status', isEqualTo: 'approved')
          .get();
      
      List<Map<String, dynamic>> absences = absencesSnapshot.docs.map((doc) => doc.data()).toList();

      final batch = _db.batch();
      final int daysDiff = endDate.difference(startDate).inDays;

      for (int i = 0; i <= daysDiff; i++) {
        DateTime currentDay = startDate.add(Duration(days: i));
        String dayString = "${currentDay.year}-${currentDay.month.toString().padLeft(2, '0')}-${currentDay.day.toString().padLeft(2, '0')}";
        
        const List<String> weekDays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
        String dayOfWeek = weekDays[currentDay.weekday - 1];

        // Create a deterministic random seed for this specific day
        int seed = currentDay.year * 10000 + currentDay.month * 100 + currentDay.day;
        Random seededRandom = Random(seed);

        // Shuffle the chores deterministically so the order of evaluation changes each day
        List<Map<String, dynamic>> dailyChores = List.from(chores);
        dailyChores.shuffle(seededRandom);

        for (var chore in dailyChores) {
          int freq = chore['frequencyDays'] ?? 7;
          if (i % freq != 0) continue;

          // Find available users
          List<Map<String, dynamic>> availableUsers = users.where((u) {
            bool isAbsent = absences.any((a) {
              if (a['userId'] != u['id']) return false;
              DateTime aStart = (a['startDate'] as Timestamp).toDate();
              DateTime aEnd = (a['endDate'] as Timestamp).toDate();
              
              DateTime normCurrent = DateTime(currentDay.year, currentDay.month, currentDay.day);
              DateTime normStart = DateTime(aStart.year, aStart.month, aStart.day);
              DateTime normEnd = DateTime(aEnd.year, aEnd.month, aEnd.day);

              return normCurrent.compareTo(normStart) >= 0 && normCurrent.compareTo(normEnd) <= 0;
            });
            return !isAbsent;
          }).toList();

          if (availableUsers.isEmpty) continue;

          // Shuffle users deterministically to break ties fairly when points are equal
          availableUsers.shuffle(seededRandom);

          // Sort by points ascending
          availableUsers.sort((a, b) {
            double pA = (a['points'] ?? 0).toDouble();
            double pB = (b['points'] ?? 0).toDouble();
            return pA.compareTo(pB);
          });

          int crewNeeded = chore['crew'] ?? 1;
          List<Map<String, dynamic>> assignedUsers = availableUsers.take(crewNeeded).toList();

          for (var assignedUser in assignedUsers) {
            final assignmentRef = _db.collection('assignments').doc();
            batch.set(assignmentRef, {
              'roomId': roomId,
              'choreId': chore['id'], 
              'choreTitle': chore['title'],
              'assignedToUserId': assignedUser['id'],
              'assignedToName': assignedUser['name'],
              'day': dayString,
              'dayOfWeek': dayOfWeek,
              'date': Timestamp.fromDate(currentDay),
              'isCompleted': false,
              'createdAt': FieldValue.serverTimestamp(),
            });

            // Simulate point increase
            double chorePoints = (chore['points'] ?? 1).toDouble();
            assignedUser['points'] = (assignedUser['points'] ?? 0).toDouble() + chorePoints;
          }
        }
      }
      
      await batch.commit();
      debugPrint("Weekly schedule generated client-side!");
    } catch (e) {
      debugPrint("Error generating schedule: $e");
      rethrow;
    }
  }

  Future<void> approveAbsenceAndRecalculate({
    required DocumentReference absenceDocRef,
    required String roomId,
    required String currentUserId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      // 1. Approve the absence
      await absenceDocRef.update({
        'status': 'approved',
        'approvedBy': currentUserId,
      });

      // 2. Re-generate schedule for this window
      await recalculateSchedule(roomId);

      debugPrint("Absence approved and schedule recalculated!");
    } catch (e) {
      debugPrint("Error approving absence: $e");
      rethrow;
    }
  }

  Future<void> removeUserAndRecalculate({
    required String userId,
    required String roomId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      // 1. Remove user from room (clear their roomId or delete doc. Let's just update roomId to empty)
      await _db.collection('users').doc(userId).update({
        'roomId': '',
      });

      // 2. Re-generate schedule
      await recalculateSchedule(roomId);

      debugPrint("User removed and schedule recalculated!");
    } catch (e) {
      debugPrint("Error removing user: $e");
      rethrow;
    }
  }
}
