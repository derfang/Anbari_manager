import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'; // Required for debugPrint
import 'dart:math';
import 'fcm_service.dart';

class ChoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Set<String> _processingAssignments = {};

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

  Future<void> recalculateSchedule(String roomId, {int startWeekOffset = 0, int endWeekOffset = 1}) async {
    await cleanOldAssignments(roomId);

    final currentBounds = getWeekBounds(startWeekOffset);
    final nextBounds = getWeekBounds(endWeekOffset);
    
    final startDate = currentBounds[0]; 
    final endDate = nextBounds[1];      

    try {
      final assignmentsSnapshot = await _db.collection('assignments')
          .where('roomId', isEqualTo: roomId)
          .get();

      final batch = _db.batch();
      for (var doc in assignmentsSnapshot.docs) {
        try {
          final data = doc.data();
          if (data['isCompleted'] == false) {
            final date = (data['date'] as Timestamp).toDate();
            if (date.compareTo(startDate) >= 0 && date.compareTo(endDate) <= 0) {
              batch.delete(doc.reference);
            }
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

  /// Silently checks and generates the current and next week's schedule if missing.
  /// Unlike recalculateSchedule, this does NOT delete any uncompleted chores,
  /// making it safe to run just-in-time when the Dashboard is opened.
  Future<void> ensureScheduleGenerated(String roomId) async {
    final currentBounds = getWeekBounds(0);
    final nextBounds = getWeekBounds(1);
    
    final startDate = currentBounds[0]; 
    final endDate = nextBounds[1];      

    try {
      // Purge any uncompleted legacy assignments (created by old app versions without 'v' field)
      final existingSnapshot = await _db.collection('assignments')
          .where('roomId', isEqualTo: roomId)
          .get();

      final batch = _db.batch();
      bool hasLegacy = false;
      for (var doc in existingSnapshot.docs) {
        final data = doc.data();
        if (data['isCompleted'] == false && data['v'] == null) {
          final date = (data['date'] as Timestamp).toDate();
          if (date.compareTo(startDate) >= 0 && date.compareTo(endDate) <= 0) {
            batch.delete(doc.reference);
            hasLegacy = true;
          }
        }
      }
      if (hasLegacy) {
        await batch.commit();
        debugPrint("Purged legacy assignments from old app versions.");
      }

      await generateWeeklySchedule(
        roomId: roomId,
        startDate: startDate,
        endDate: endDate,
      );
      debugPrint("Silently ensured schedule is generated for $roomId");
    } catch (e) {
      debugPrint("Error ensuring schedule is generated: $e");
    }
  }

  /// Calculates presence weight for each non-doer roommate over the chore cycle window [cycleStart, cycleEnd].
  /// Presence weight = daysPresent / totalCycleDays (between 0.0 and 1.0).
  Map<String, double> _calculatePresenceWeights({
    required List<DocumentSnapshot> candidates,
    required List<Map<String, dynamic>> approvedAbsences,
    required DateTime cycleStart,
    required DateTime cycleEnd,
  }) {
    final normStart = DateTime(cycleStart.year, cycleStart.month, cycleStart.day);
    final normEnd = DateTime(cycleEnd.year, cycleEnd.month, cycleEnd.day);
    final int totalCycleDays = normEnd.difference(normStart).inDays + 1;
    if (totalCycleDays <= 0) return {for (var c in candidates) c.id: 1.0};

    final Map<String, double> weights = {};

    for (var doc in candidates) {
      final String uid = doc.id;
      final data = doc.data() as Map<String, dynamic>;
      
      // If user is globally flagged as permanent absent, weight is 0
      if (data['isAbsent'] == true) {
        weights[uid] = 0.0;
        continue;
      }

      // Find all approved absence windows for this user
      final userAbsences = approvedAbsences.where((a) => a['userId'] == uid).toList();
      
      int absentDaysCount = 0;
      for (int d = 0; d < totalCycleDays; d++) {
        final currentDay = normStart.add(Duration(days: d));
        bool isDayAbsent = false;
        for (var absence in userAbsences) {
          final aStart = (absence['startDate'] as Timestamp).toDate();
          final aEnd = (absence['endDate'] as Timestamp).toDate();
          final normAStart = DateTime(aStart.year, aStart.month, aStart.day);
          final normAEnd = DateTime(aEnd.year, aEnd.month, aEnd.day);

          if (currentDay.compareTo(normAStart) >= 0 && currentDay.compareTo(normAEnd) <= 0) {
            isDayAbsent = true;
            break;
          }
        }
        if (isDayAbsent) absentDaysCount++;
      }

      int presentDays = totalCycleDays - absentDaysCount;
      if (presentDays < 0) presentDays = 0;
      weights[uid] = presentDays / totalCycleDays;
    }

    return weights;
  }

  Future<void> completeChore({
    required String roomId,
    required String choreId,
    required String assignmentId,
    required List<String> doerIds, // Supports multi-guy chores
  }) async {
    if (_processingAssignments.contains(assignmentId)) {
      debugPrint("Already processing this assignment. Aborting.");
      return;
    }
    _processingAssignments.add(assignmentId);
    try {
      final assignmentDoc = await _db.collection('assignments').doc(assignmentId).get();
      if (assignmentDoc.exists && assignmentDoc.data()?['isCompleted'] == true) {
        debugPrint("Chore already completed. Aborting.");
        return;
      }
      // 1. Fetch the chore details to get its effortValue and frequency
      final choreDoc = await _db.collection('chores').doc(choreId).get();
      if (!choreDoc.exists) throw Exception("Chore not found");

      final choreData = choreDoc.data() ?? {};
      final double effortValue = (choreData['points'] ?? 0).toDouble();
      final int freq = (choreData['frequencyDays'] is num && choreData['frequencyDays'] > 0 && choreData['frequencyDays'] < 99999)
          ? (choreData['frequencyDays'] as num).toInt()
          : 1;

      // 2. Determine the cycle window [cycleStart, cycleEnd]
      DateTime taskDate = DateTime.now();
      if (assignmentDoc.exists && assignmentDoc.data() != null) {
        final assignData = assignmentDoc.data()!;
        if (assignData['date'] is Timestamp) {
          taskDate = (assignData['date'] as Timestamp).toDate();
        }
      }
      final DateTime cycleEnd = DateTime(taskDate.year, taskDate.month, taskDate.day);
      final DateTime cycleStart = cycleEnd.subtract(Duration(days: freq - 1));

      // 3. Fetch all users in the room
      final usersSnapshot = await _db
          .collection('users')
          .where(Filter.or(Filter('roomId', isEqualTo: roomId), Filter('roomIds', arrayContains: roomId)))
          .get();

      List<DocumentSnapshot> nonDoerCandidates = [];
      List<DocumentSnapshot> doers = [];

      for (var doc in usersSnapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final List<dynamic> roomIds = data['roomIds'] ?? [];
        if (data['roomId'] != roomId && !roomIds.contains(roomId)) continue;

        if (doerIds.contains(doc.id)) {
          doers.add(doc);
        } else {
          nonDoerCandidates.add(doc);
        }
      }

      // 4. Fetch approved absences for the room
      final absencesSnapshot = await _db.collection('absences')
          .where('roomId', isEqualTo: roomId)
          .where('status', isEqualTo: 'approved')
          .get();
      final approvedAbsences = absencesSnapshot.docs.map((d) => d.data()).toList();

      // 5. Calculate presence weights for all non-doer roommates
      final presenceWeights = _calculatePresenceWeights(
        candidates: nonDoerCandidates,
        approvedAbsences: approvedAbsences,
        cycleStart: cycleStart,
        cycleEnd: cycleEnd,
      );

      final double totalPresenceWeight = presenceWeights.values.fold(0.0, (prev, w) => prev + w);

      final double totalReward = effortValue * doers.length;
      final Map<String, double> distributedTaxes = {};
      final batch = _db.batch();

      if (totalPresenceWeight > 0) {
        // Distribute tax proportionally to each roommate's presence weight
        for (var slacker in nonDoerCandidates) {
          final double weight = presenceWeights[slacker.id] ?? 0.0;
          if (weight > 0) {
            final double userTax = totalReward * (weight / totalPresenceWeight);
            distributedTaxes[slacker.id] = userTax;
            batch.update(slacker.reference, {
              'roomPoints.$roomId': FieldValue.increment(-userTax),
            });
          } else {
            distributedTaxes[slacker.id] = 0.0;
          }
        }

        // Reward the doers with full effort points
        for (var doer in doers) {
          batch.update(doer.reference, {
            'roomPoints.$roomId': FieldValue.increment(effortValue),
          });
        }
      } else {
        debugPrint("All non-doers were 100% absent during cycle. No slacker tax applied.");
      }

      // 6. Log the history with exact distributed taxes
      final historyRef = _db.collection('chore_history').doc();
      batch.set(historyRef, {
        'roomId': roomId,
        'choreId': choreId,
        'assignmentId': assignmentId,
        'completedBy': doerIds,
        'completedAt': FieldValue.serverTimestamp(),
        'effortValue': effortValue,
        'taxes': distributedTaxes,
        'cycleDays': freq,
        'presenceWeights': presenceWeights,
      });

      batch.update(_db.collection('assignments').doc(assignmentId), {'isCompleted': true, 'v': 2});

      // 7. Execute the batch
      await batch.commit();
      debugPrint("Zero-sum proportional points successfully distributed!");

      // 8. Recalculate next week's schedule with the new points
      await recalculateSchedule(roomId, startWeekOffset: 1, endWeekOffset: 1);
    } catch (e) {
      debugPrint("Error processing chore math: $e");
      rethrow;
    } finally {
      _processingAssignments.remove(assignmentId);
    }
  }

  /// Cancels a completion made by mistake without triggering a dispute or vote.
  /// Reverts zero-sum points using recorded history taxes, cleans up history, and returns assignment to pending state.
  Future<void> cancelSelfCompletion({
    required String roomId,
    required String choreId,
    required String assignmentId,
    required List<String> doerIds,
  }) async {
    if (_processingAssignments.contains(assignmentId)) {
      debugPrint("Already processing this assignment. Aborting.");
      return;
    }
    _processingAssignments.add(assignmentId);
    try {
      final assignmentDoc = await _db.collection('assignments').doc(assignmentId).get();
      if (!assignmentDoc.exists) return;
      if (assignmentDoc.data()?['isCompleted'] == false) {
        debugPrint("Chore is already not completed. Aborting.");
        return;
      }

      final choreDoc = await _db.collection('chores').doc(choreId).get();
      if (!choreDoc.exists) throw Exception("Chore not found");

      final double effortValue = (choreDoc.data()?['points'] ?? 0).toDouble();

      // Fetch history record to get exact taxes deducted
      final historyQuery = await _db.collection('chore_history')
          .where('roomId', isEqualTo: roomId)
          .where('assignmentId', isEqualTo: assignmentId)
          .get();

      Map<String, double>? recordedTaxes;
      if (historyQuery.docs.isNotEmpty) {
        final historyData = historyQuery.docs.first.data();
        if (historyData['taxes'] is Map) {
          recordedTaxes = (historyData['taxes'] as Map).map(
            (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
          );
        }
      }

      final usersSnapshot = await _db
          .collection('users')
          .where(Filter.or(Filter('roomId', isEqualTo: roomId), Filter('roomIds', arrayContains: roomId)))
          .get();

      List<DocumentSnapshot> slackers = [];
      List<DocumentSnapshot> doers = [];

      for (var doc in usersSnapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final List<dynamic> roomIds = data['roomIds'] ?? [];
        if (data['roomId'] != roomId && !roomIds.contains(roomId)) continue;

        if (doerIds.contains(doc.id)) {
          doers.add(doc);
        } else {
          slackers.add(doc);
        }
      }

      final batch = _db.batch();

      if (recordedTaxes != null && recordedTaxes.isNotEmpty) {
        // Precise reversion based on exact recorded taxes
        for (var slacker in slackers) {
          final double refundedTax = recordedTaxes[slacker.id] ?? 0.0;
          if (refundedTax > 0) {
            batch.update(slacker.reference, {
              'roomPoints.$roomId': FieldValue.increment(refundedTax),
            });
          }
        }
        for (var doer in doers) {
          batch.update(doer.reference, {
            'roomPoints.$roomId': FieldValue.increment(-effortValue),
          });
        }
      } else {
        // Fallback for legacy records without taxes map
        final presentSlackers = slackers.where((d) => (d.data() as Map<String, dynamic>)['isAbsent'] != true).toList();
        if (presentSlackers.isNotEmpty) {
          final double slackerTax = (effortValue * doers.length) / presentSlackers.length;
          for (var slacker in presentSlackers) {
            batch.update(slacker.reference, {
              'roomPoints.$roomId': FieldValue.increment(slackerTax),
            });
          }
          for (var doer in doers) {
            batch.update(doer.reference, {
              'roomPoints.$roomId': FieldValue.increment(-effortValue),
            });
          }
        }
      }

      // Mark assignment uncompleted and NOT disputed
      batch.update(assignmentDoc.reference, {
        'isCompleted': false,
        'disputed': false,
        'v': 2,
      });

      // Delete history log for this assignment
      for (var h in historyQuery.docs) {
        batch.delete(h.reference);
      }

      // Delete any pending false report filed for this assignment
      final reportsQuery = await _db.collection('reports')
          .where('assignmentId', isEqualTo: assignmentId)
          .get();
      for (var r in reportsQuery.docs) {
        batch.delete(r.reference);
      }

      await batch.commit();
      debugPrint("Self-completion cancelled: proportional points reverted and status cleared.");

      // Recalculate next week's schedule with the reverted points
      await recalculateSchedule(roomId, startWeekOffset: 1, endWeekOffset: 1);
    } catch (e) {
      debugPrint("Error cancelling self-completion: $e");
      rethrow;
    } finally {
      _processingAssignments.remove(assignmentId);
    }
  }

  /// Inserts a task directly for a specific roommate on a specific date without
  /// touching, recalculating, or disrupting any other scheduled tasks.
  Future<void> forceInsertAssignment({
    required String roomId,
    String? choreId,
    required String title,
    required String icon,
    required double points,
    required DateTime date,
    required String assignedToUserId,
    required String assignedToName,
  }) async {
    String finalChoreId = choreId ?? '';
    if (finalChoreId.isEmpty) {
      // Create a one-off chore document in 'chores' collection so math engine finds it
      final newChoreRef = await _db.collection('chores').add({
        'roomId': roomId,
        'title': title,
        'icon': icon,
        'points': points,
        'crew': 1,
        'frequencyDays': 99999, // High number prevents IntegerDivisionByZero on older clients
        'isOneOff': true,
        'createdAt': FieldValue.serverTimestamp(),
      });
      finalChoreId = newChoreRef.id;
    }

    // Normalize date to midnight
    final normDate = DateTime(date.year, date.month, date.day);
    const List<String> weekDays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final dayOfWeek = weekDays[normDate.weekday - 1];
    final dayString = "${normDate.year}-${normDate.month.toString().padLeft(2, '0')}-${normDate.day.toString().padLeft(2, '0')}";

    final assignmentData = {
      'roomId': roomId,
      'choreId': finalChoreId,
      'choreTitle': title,
      'choreIcon': icon,
      'points': points,
      'date': Timestamp.fromDate(normDate),
      'day': dayString,
      'dayOfWeek': dayOfWeek,
      'assignedToUserId': assignedToUserId,
      'assignedToName': assignedToName,
      'isCompleted': false,
      'disputed': false,
      'v': 2,
    };

    await _db.collection('assignments').add(assignmentData);
    debugPrint("Force inserted assignment for $assignedToName ($title on $dayString)");
  }

  Future<void> undoChore({
    required String roomId,
    required String choreId,
    required String assignmentId,
    required List<String> doerIds,
  }) async {
    if (_processingAssignments.contains(assignmentId)) {
      debugPrint("Already processing this assignment. Aborting.");
      return;
    }
    _processingAssignments.add(assignmentId);
    try {
      final assignmentDoc = await _db.collection('assignments').doc(assignmentId).get();
      if (assignmentDoc.exists && assignmentDoc.data()?['isCompleted'] == false) {
        debugPrint("Chore already undone. Aborting.");
        return;
      }
      final choreDoc = await _db.collection('chores').doc(choreId).get();
      if (!choreDoc.exists) throw Exception("Chore not found");

      final double effortValue = (choreDoc.data()?['points'] ?? 0).toDouble();

      // Fetch history record to get exact taxes deducted
      final historyQuery = await _db.collection('chore_history')
          .where('roomId', isEqualTo: roomId)
          .where('assignmentId', isEqualTo: assignmentId)
          .get();

      Map<String, double>? recordedTaxes;
      if (historyQuery.docs.isNotEmpty) {
        final historyData = historyQuery.docs.first.data();
        if (historyData['taxes'] is Map) {
          recordedTaxes = (historyData['taxes'] as Map).map(
            (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
          );
        }
      }

      final usersSnapshot = await _db
          .collection('users')
          .where(Filter.or(Filter('roomId', isEqualTo: roomId), Filter('roomIds', arrayContains: roomId)))
          .get();

      List<DocumentSnapshot> slackers = [];
      List<DocumentSnapshot> doers = [];

      for (var doc in usersSnapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final List<dynamic> roomIds = data['roomIds'] ?? [];
        if (data['roomId'] != roomId && !roomIds.contains(roomId)) continue;

        if (doerIds.contains(doc.id)) {
          doers.add(doc);
        } else {
          slackers.add(doc);
        }
      }

      final batch = _db.batch();

      if (recordedTaxes != null && recordedTaxes.isNotEmpty) {
        // Precise reversion based on exact recorded taxes
        for (var slacker in slackers) {
          final double refundedTax = recordedTaxes[slacker.id] ?? 0.0;
          if (refundedTax > 0) {
            batch.update(slacker.reference, {
              'roomPoints.$roomId': FieldValue.increment(refundedTax),
            });
          }
        }
        for (var doer in doers) {
          batch.update(doer.reference, {
            'roomPoints.$roomId': FieldValue.increment(-effortValue),
          });
        }
      } else {
        // Fallback for legacy records without taxes map
        final presentSlackers = slackers.where((d) => (d.data() as Map<String, dynamic>)['isAbsent'] != true).toList();
        if (presentSlackers.isNotEmpty) {
          final double slackerTax = (effortValue * doers.length) / presentSlackers.length;
          for (var slacker in presentSlackers) {
            batch.update(slacker.reference, {
              'roomPoints.$roomId': FieldValue.increment(slackerTax),
            });
          }
          for (var doer in doers) {
            batch.update(doer.reference, {
              'roomPoints.$roomId': FieldValue.increment(-effortValue),
            });
          }
        }
      }

      batch.update(_db.collection('assignments').doc(assignmentId), {'isCompleted': false, 'v': 2});

      await batch.commit();
      debugPrint("Zero-sum points successfully reverted!");

      // Recalculate next week's schedule with the reverted points
      await recalculateSchedule(roomId, startWeekOffset: 1, endWeekOffset: 1);
    } catch (e) {
      debugPrint("Error reverting chore math: $e");
      rethrow;
    } finally {
      _processingAssignments.remove(assignmentId);
    }
  }

  Future<void> generateWeeklySchedule({
    required String roomId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      Map<String, int> assignmentsPerUser = {};

      // 1. Fetch users
      final usersSnapshot = await _db
          .collection('users')
          .where(Filter.or(Filter('roomId', isEqualTo: roomId), Filter('roomIds', arrayContains: roomId)))
          .get();
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
          .get();
      List<Map<String, dynamic>> absences = absencesSnapshot.docs
          .map((doc) => doc.data())
          .where((data) => data['status'] == 'approved')
          .toList();

      // 4. Fetch existing assignments to avoid duplicates
      final existingAssignmentsSnapshot = await _db.collection('assignments')
          .where('roomId', isEqualTo: roomId)
          .get();

      Set<String> existingChoreDays = {};
      for (var doc in existingAssignmentsSnapshot.docs) {
        final data = doc.data();
        final date = (data['date'] as Timestamp).toDate();
        if (date.compareTo(startDate) >= 0 && date.compareTo(endDate) <= 0) {
          final String cId = data['choreId'];
          final String dStr = data['day'];
          existingChoreDays.add("${cId}_$dStr");
        }
      }

      final batch = _db.batch();
      final int daysDiff = endDate.difference(startDate).inDays;
      final DateTime epoch = DateTime.utc(2024, 1, 6);

      for (int i = 0; i <= daysDiff; i++) {
        DateTime currentDay = startDate.add(Duration(days: i));
        DateTime currentDayUtc = DateTime.utc(currentDay.year, currentDay.month, currentDay.day);
        int daysSinceEpoch = currentDayUtc.difference(epoch).inDays;
        
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
          if (chore['isOneOff'] == true || (chore['frequencyDays'] ?? 0) <= 0) continue;
          int freq = chore['frequencyDays'] ?? 7;
          if (daysSinceEpoch % freq != 0) continue;

          // Skip if an assignment already exists for this chore on this day
          if (existingChoreDays.contains("${chore['id']}_$dayString")) {
            continue;
          }

          // Find available users
          List<Map<String, dynamic>> availableUsers = users.where((u) {
            if (u['isAbsent'] == true) return false;

            bool isAbsentTemp = absences.any((a) {
              if (a['userId'] != u['id']) return false;
              DateTime aStart = (a['startDate'] as Timestamp).toDate();
              DateTime aEnd = (a['endDate'] as Timestamp).toDate();
              
              DateTime normCurrent = DateTime(currentDay.year, currentDay.month, currentDay.day);
              DateTime normStart = DateTime(aStart.year, aStart.month, aStart.day);
              DateTime normEnd = DateTime(aEnd.year, aEnd.month, aEnd.day);

              return normCurrent.compareTo(normStart) >= 0 && normCurrent.compareTo(normEnd) <= 0;
            });
            return !isAbsentTemp;
          }).toList();

          if (availableUsers.isEmpty) continue;

          // Shuffle users deterministically to break ties fairly when points are equal
          availableUsers.shuffle(seededRandom);

          // Sort by points ascending
          availableUsers.sort((a, b) {
            double pA = ((a['roomPoints'] as Map?)?[roomId] ?? 0).toDouble();
            double pB = ((b['roomPoints'] as Map?)?[roomId] ?? 0).toDouble();
            return pA.compareTo(pB);
          });

          int crewNeeded = chore['crew'] ?? 1;
          List<Map<String, dynamic>> assignedUsers = availableUsers.take(crewNeeded).toList();

          for (var assignedUser in assignedUsers) {
            int deadlineDays = chore['deadlineDays'] ?? 1;
            DateTime endDay = currentDay.add(Duration(days: deadlineDays - 1));

            final String deterministicId = "${roomId}_${chore['id']}_${dayString}_${assignedUser['id']}";
            final assignmentRef = _db.collection('assignments').doc(deterministicId);
            batch.set(assignmentRef, {
              'roomId': roomId,
              'choreId': chore['id'], 
              'choreTitle': chore['title'],
              'choreIcon': chore['icon'] ?? 'cleaning_services',
              'assignedToUserId': assignedUser['id'],
              'assignedToName': assignedUser['name'],
              'day': dayString,
              'dayOfWeek': dayOfWeek,
              'date': Timestamp.fromDate(currentDay),
              'endDate': Timestamp.fromDate(endDay),
              'deadlineDays': deadlineDays,
              'isCompleted': false,
              'createdAt': FieldValue.serverTimestamp(),
              'v': 2,
            });

            // Simulate point increase
            double chorePoints = (chore['points'] ?? 1).toDouble();
            assignedUser['roomPoints'] ??= {};
            assignedUser['roomPoints'][roomId] = ((assignedUser['roomPoints'] as Map?)?[roomId] ?? 0).toDouble() + chorePoints;

            assignmentsPerUser[assignedUser['id']] = (assignmentsPerUser[assignedUser['id']] ?? 0) + 1;
          }
        }
      }
      
      await batch.commit();
      debugPrint("Weekly schedule generated client-side!");

      // Notification for new assignments has been disabled based on user request.
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
      // 1. Remove user from room (clear their legacy roomId and arrayRemove from roomIds)
      await _db.collection('users').doc(userId).update({
        'roomId': '',
        'roomIds': FieldValue.arrayRemove([roomId]),
      });

      // 2. Delete all their pending assignments for this room
      final batch = _db.batch();
      final pendingAssignments = await _db.collection('assignments')
          .where('roomId', isEqualTo: roomId)
          .where('assignedTo', isEqualTo: userId)
          .where('status', isEqualTo: 'pending')
          .get();
          
      for (var doc in pendingAssignments.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      // 3. Re-generate schedule for remaining roommates
      await recalculateSchedule(roomId);

      debugPrint("User removed, pending assignments deleted, and schedule recalculated!");
    } catch (e) {
      debugPrint("Error removing user: $e");
      rethrow;
    }
  }
}
