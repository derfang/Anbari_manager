import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import '../services/finance_service.dart';
import 'add_expense_screen.dart';

class FinancesScreen extends StatefulWidget {
  final String roomId;
  const FinancesScreen({super.key, required this.roomId});

  @override
  State<FinancesScreen> createState() => _FinancesScreenState();
}

class _FinancesScreenState extends State<FinancesScreen> {
  final FinanceService _financeService = FinanceService();
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  List<SimplifiedDebt> _debts = [];
  Map<String, String> _userNames = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    
    // Load users
    final query = await _db.collection('users').get();
    Map<String, String> names = {};
    for (var doc in query.docs) {
      if (doc.id == _auth.currentUser?.uid) {
        names[doc.id] = 'You';
      } else {
        names[doc.id] = (doc.data()['name'] as String?) ?? 'Unknown';
      }
    }

    final debts = await _financeService.getSimplifiedDebts(widget.roomId);

    if (mounted) {
      setState(() {
        _userNames = names;
        _debts = debts;
        _isLoading = false;
      });
    }
  }

  Future<void> _settleDebt(SimplifiedDebt debt) async {
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Settle Up"),
        content: Text("Record a cash payment of \$${debt.amount.toStringAsFixed(2)} from ${_userNames[debt.fromUserId]} to ${_userNames[debt.toUserId]}?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Settle")),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _isLoading = true);
      await _financeService.addSettlement(
        roomId: widget.roomId,
        fromUserId: debt.fromUserId,
        toUserId: debt.toUserId,
        amount: debt.amount,
      );
      await _loadData();
    }
  }

  void _showTransactionDetails(Map<String, dynamic> activity) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        bool isExpense = activity['type'] == 'expense';
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 24, right: 24, top: 24
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isExpense ? "Expense Details" : "Settlement Details", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              
              if (isExpense) ...[
                Text("Description: ${activity['description']}", style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                Text("Total Amount: \$${(activity['amount'] as num).toStringAsFixed(2)}", style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                Text("Paid By: ${_userNames[activity['paidBy']]}", style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                Text("Date: ${activity['date'] != null ? DateFormat('MMM d, yyyy h:mm a').format((activity['date'] as Timestamp).toDate()) : 'Pending'}", style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 16),
                const Text("Splits:", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (activity['splits'] != null)
                  ...(activity['splits'] as Map<String, dynamic>).entries.map((e) => 
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4.0),
                      child: Text("${_userNames[e.key] ?? 'Unknown'}: \$${(e.value as num).toStringAsFixed(2)}"),
                    )
                  ),
              ] else ...[
                Text("${_userNames[activity['fromUserId']]} paid ${_userNames[activity['toUserId']]}", style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                Text("Amount: \$${(activity['amount'] as num).toStringAsFixed(2)}", style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                Text("Date: ${activity['date'] != null ? DateFormat('MMM d, yyyy h:mm a').format((activity['date'] as Timestamp).toDate()) : 'Pending'}", style: const TextStyle(fontSize: 16)),
              ],
              
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (isExpense)
                    OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await Navigator.push(context, MaterialPageRoute(
                          builder: (_) => AddExpenseScreen(
                            roomId: widget.roomId,
                            expenseId: activity['id'],
                            initialData: activity,
                          )
                        ));
                        _loadData(); // Refresh list after edit
                      }, 
                      icon: const Icon(Icons.edit), 
                      label: const Text("Edit")
                    ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () async {
                      // Check permissions
                      if (isExpense) {
                        if (activity['createdBy'] != _auth.currentUser?.uid && activity['paidBy'] != _auth.currentUser?.uid) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Only the creator or payer can delete this.")));
                          return;
                        }
                      } else {
                        if (activity['fromUserId'] != _auth.currentUser?.uid) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Only the sender can delete this settlement.")));
                          return;
                        }
                      }

                      bool? confirm = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text("Delete Transaction"),
                          content: const Text("Are you sure you want to delete this transaction? This will reverse the balances."),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("Cancel")),
                            FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(c, true), child: const Text("Delete")),
                          ]
                        )
                      );

                      if (confirm == true) {
                        Navigator.pop(ctx);
                        setState(() => _isLoading = true);
                        await _financeService.deleteTransaction(isExpense ? 'expenses' : 'settlements', activity['id']);
                        await _loadData();
                      }
                    }, 
                    icon: const Icon(Icons.delete), 
                    label: const Text("Delete")
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Room Finances"),
        backgroundColor: Colors.teal.shade50,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => AddExpenseScreen(roomId: widget.roomId)));
          _loadData(); // refresh when coming back
        },
        icon: const Icon(Icons.add),
        label: const Text("Add Expense"),
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _loadData,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text("Who Owes Whom (Simplified)", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.teal)),
                const SizedBox(height: 12),
                if (_debts.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24.0),
                      child: Center(child: Text("All settled up! No debts in the room.", style: TextStyle(fontSize: 16, color: Colors.grey))),
                    ),
                  )
                else
                  ..._debts.map((debt) {
                    final isMyDebt = debt.fromUserId == _auth.currentUser?.uid || debt.toUserId == _auth.currentUser?.uid;
                    final canSettle = debt.fromUserId == _auth.currentUser?.uid;
                    
                    String titleText;
                    if (debt.fromUserId == _auth.currentUser?.uid) {
                      titleText = "You owe ${_userNames[debt.toUserId]}";
                    } else if (debt.toUserId == _auth.currentUser?.uid) {
                      titleText = "${_userNames[debt.fromUserId]} owes you";
                    } else {
                      titleText = "${_userNames[debt.fromUserId]} owes ${_userNames[debt.toUserId]}";
                    }

                    return Card(
                      elevation: isMyDebt ? 3 : 1,
                      color: isMyDebt ? Colors.teal.shade50 : null,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.teal.shade100,
                          child: const Icon(Icons.monetization_on, color: Colors.teal),
                        ),
                        title: Text(titleText),
                        subtitle: Text("\$${debt.amount.toStringAsFixed(2)}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        trailing: canSettle 
                          ? FilledButton.tonal(
                              onPressed: () => _settleDebt(debt),
                              child: const Text("Settle"),
                            )
                          : null,
                      ),
                    );
                  }),
                
                const SizedBox(height: 32),
                const Text("Recent Activity", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.teal)),
                const SizedBox(height: 12),
                StreamBuilder<QuerySnapshot>(
                  stream: _db.collection('expenses').where('roomId', isEqualTo: widget.roomId).snapshots(),
                  builder: (context, expenseSnap) {
                    return StreamBuilder<QuerySnapshot>(
                      stream: _db.collection('settlements').where('roomId', isEqualTo: widget.roomId).snapshots(),
                      builder: (context, settlementSnap) {
                        if (expenseSnap.hasError) return Center(child: Text("Error: ${expenseSnap.error}"));
                        if (settlementSnap.hasError) return Center(child: Text("Error: ${settlementSnap.error}"));
                        if (!expenseSnap.hasData || !settlementSnap.hasData) {
                          return const Center(child: CircularProgressIndicator());
                        }

                        // Combine and sort both lists
                        List<Map<String, dynamic>> allActivity = [];
                        
                        for (var doc in expenseSnap.data!.docs) {
                          var data = doc.data() as Map<String, dynamic>;
                          data['id'] = doc.id;
                          data['type'] = 'expense';
                          allActivity.add(data);
                        }

                        for (var doc in settlementSnap.data!.docs) {
                          var data = doc.data() as Map<String, dynamic>;
                          data['id'] = doc.id;
                          data['type'] = 'settlement';
                          allActivity.add(data);
                        }

                        allActivity.sort((a, b) {
                          Timestamp? tA = a['date'] as Timestamp?;
                          Timestamp? tB = b['date'] as Timestamp?;
                          if (tA == null) return 1;
                          if (tB == null) return -1;
                          return tB.compareTo(tA);
                        });

                        if (allActivity.isEmpty) {
                          return const Center(child: Text("No financial activity yet."));
                        }

                        return Column(
                          children: allActivity.map((activity) {
                            if (activity['type'] == 'expense') {
                              return ListTile(
                                onTap: () => _showTransactionDetails(activity),
                                leading: const Icon(Icons.receipt, color: Colors.blueGrey),
                                title: Text(activity['description'] ?? 'Expense'),
                                subtitle: Text("${_userNames[activity['paidBy']]} paid \$${(activity['amount'] as num).toStringAsFixed(2)}"),
                                trailing: Text(activity['date'] != null ? DateFormat('MMM d, h:mm a').format((activity['date'] as Timestamp).toDate()) : ''),
                              );
                            } else {
                              return ListTile(
                                onTap: () => _showTransactionDetails(activity),
                                leading: const Icon(Icons.handshake, color: Colors.green),
                                title: const Text("Settlement"),
                                subtitle: Text("${_userNames[activity['fromUserId']]} paid ${_userNames[activity['toUserId']]} \$${(activity['amount'] as num).toStringAsFixed(2)}"),
                                trailing: Text(activity['date'] != null ? DateFormat('MMM d, h:mm a').format((activity['date'] as Timestamp).toDate()) : ''),
                              );
                            }
                          }).toList(),
                        );
                      }
                    );
                  }
                )
              ],
            ),
          ),
    );
  }
}
