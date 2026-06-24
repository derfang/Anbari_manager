import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'; // Required for debugPrint

class ChoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

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
        } else if (data['isAbsent'] == false) {
          // FIXED: Removed null check and cast
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
}
