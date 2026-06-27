import 'package:cloud_firestore/cloud_firestore.dart';

class SimplifiedDebt {
  final String fromUserId;
  final String toUserId;
  final double amount;

  SimplifiedDebt({
    required this.fromUserId,
    required this.toUserId,
    required this.amount,
  });
}

class FinanceService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> addExpense({
    required String roomId,
    required String description,
    required double amount,
    required String paidBy,
    required Map<String, double> splits,
    required String createdBy,
  }) async {
    // Validate that splits sum exactly to amount (with 0.5 tolerance)
    double sum = splits.values.fold(0, (prev, curr) => prev + curr);
    if ((sum - amount).abs() > 0.5) {
      throw Exception("Splits do not sum to total amount.");
    }

    Map<String, String> approvals = {};
    splits.keys.forEach((userId) {
      approvals[userId] = (userId == createdBy || userId == paidBy) ? 'approved' : 'pending';
    });

    await _db.collection('expenses').add({
      'roomId': roomId,
      'description': description,
      'amount': amount,
      'paidBy': paidBy,
      'splits': splits,
      'approvals': approvals,
      'date': FieldValue.serverTimestamp(),
      'createdBy': createdBy,
    });
  }

  Future<void> updateExpense({
    required String expenseId,
    required String description,
    required double amount,
    required String paidBy,
    required Map<String, double> splits,
    required String editedBy,
  }) async {
    double sum = splits.values.fold(0, (prev, curr) => prev + curr);
    if ((sum - amount).abs() > 0.5) {
      throw Exception("Splits do not sum to total amount.");
    }

    Map<String, String> approvals = {};
    splits.keys.forEach((userId) {
      approvals[userId] = (userId == editedBy || userId == paidBy) ? 'approved' : 'pending';
    });

    await _db.collection('expenses').doc(expenseId).update({
      'description': description,
      'amount': amount,
      'paidBy': paidBy,
      'splits': splits,
      'approvals': approvals,
    });
  }

  Future<void> updateExpenseApproval(String expenseId, String userId, String status) async {
    await _db.collection('expenses').doc(expenseId).update({
      'approvals.$userId': status,
    });
  }

  Future<void> addSettlement({
    required String roomId,
    required String fromUserId,
    required String toUserId,
    required double amount,
  }) async {
    await _db.collection('settlements').add({
      'roomId': roomId,
      'fromUserId': fromUserId,
      'toUserId': toUserId,
      'amount': amount,
      'date': FieldValue.serverTimestamp(),
    });
  }

  // Returns a map of userId -> net balance
  // Positive means they are owed money. Negative means they owe money.
  Future<Map<String, double>> calculateNetBalances(String roomId) async {
    final expensesQuery = await _db.collection('expenses').where('roomId', isEqualTo: roomId).get();
    final settlementsQuery = await _db.collection('settlements').where('roomId', isEqualTo: roomId).get();

    Map<String, double> balances = {};

    for (var doc in expensesQuery.docs) {
      final data = doc.data();
      final paidBy = data['paidBy'] as String;
      final splits = Map<String, dynamic>.from(data['splits']);
      final amount = (data['amount'] as num).toDouble();

      final approvals = data.containsKey('approvals') ? Map<String, String>.from(data['approvals']) : <String, String>{};

      // Person who paid gets credited the full amount, BUT ONLY for the approved splits
      // Actually, wait! The payer only paid out of pocket. Their "credit" towards others only counts if the others approved.
      // So payer gets credited the sum of all *approved* splits (plus their own share if approved, but payer's own share is auto-approved).
      
      double approvedTotal = 0;
      splits.forEach((userId, share) {
        String status = approvals[userId] ?? 'approved'; // Legacy expenses are implicitly approved
        if (status == 'approved') {
          balances[userId] = (balances[userId] ?? 0.0) - (share as num).toDouble();
          approvedTotal += (share as num).toDouble();
        }
      });

      // Credit the payer for the total of all approved splits
      balances[paidBy] = (balances[paidBy] ?? 0.0) + approvedTotal;
    }

    for (var doc in settlementsQuery.docs) {
      final data = doc.data();
      final fromUserId = data['fromUserId'] as String;
      final toUserId = data['toUserId'] as String;
      final amount = (data['amount'] as num).toDouble();

      // The person who paid the settlement reduces their debt (credits their balance)
      balances[fromUserId] = (balances[fromUserId] ?? 0.0) + amount;
      
      // The person who received it reduces their credit (debits their balance)
      balances[toUserId] = (balances[toUserId] ?? 0.0) - amount;
    }

    // Clean up floating point errors
    balances.forEach((key, value) {
      if (value.abs() < 0.01) {
        balances[key] = 0.0;
      }
    });

    return balances;
  }

  Future<List<SimplifiedDebt>> getSimplifiedDebts(String roomId) async {
    final balances = await calculateNetBalances(roomId);

    List<MapEntry<String, double>> debtors = [];
    List<MapEntry<String, double>> creditors = [];

    balances.forEach((userId, balance) {
      if (balance < 0) {
        debtors.add(MapEntry(userId, balance));
      } else if (balance > 0) {
        creditors.add(MapEntry(userId, balance));
      }
    });

    // Sort to match largest debtors with largest creditors first (greedy)
    debtors.sort((a, b) => a.value.compareTo(b.value)); // Most negative first
    creditors.sort((a, b) => b.value.compareTo(a.value)); // Most positive first

    List<SimplifiedDebt> debts = [];
    int i = 0; // index for debtors
    int j = 0; // index for creditors

    while (i < debtors.length && j < creditors.length) {
      double debt = debtors[i].value.abs();
      double credit = creditors[j].value;

      String debtorId = debtors[i].key;
      String creditorId = creditors[j].key;

      double settledAmount = debt < credit ? debt : credit;
      if (settledAmount > 0.01) {
        debts.add(SimplifiedDebt(
          fromUserId: debtorId,
          toUserId: creditorId,
          amount: settledAmount,
        ));
      }

      debtors[i] = MapEntry(debtorId, debtors[i].value + settledAmount);
      creditors[j] = MapEntry(creditorId, creditors[j].value - settledAmount);

      if (debtors[i].value.abs() < 0.01) i++;
      if (creditors[j].value < 0.01) j++;
    }

    return debts;
  }

  Stream<List<Map<String, dynamic>>> getPendingExpensesStream(String roomId, String userId) {
    return _db.collection('expenses').where('roomId', isEqualTo: roomId).snapshots().map((snapshot) {
      List<Map<String, dynamic>> pending = [];
      for (var doc in snapshot.docs) {
        final data = doc.data();
        if (data.containsKey('approvals')) {
          final approvals = Map<String, dynamic>.from(data['approvals']);
          if (approvals[userId] == 'pending') {
            pending.add({
              'id': doc.id,
              ...data,
            });
          }
        }
      }
      return pending;
    });
  }

  Future<void> deleteTransaction(String collection, String docId) async {
    if (collection != 'expenses' && collection != 'settlements') return;
    await _db.collection(collection).doc(docId).delete();
  }
}
