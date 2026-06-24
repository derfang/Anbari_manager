import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/chore_service.dart';

class ManageChoresScreen extends StatefulWidget {
  const ManageChoresScreen({super.key});

  @override
  State<ManageChoresScreen> createState() => _ManageChoresScreenState();
}

class _ManageChoresScreenState extends State<ManageChoresScreen> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  
  String? _roomId;
  bool _isAdmin = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUserRoom();
  }

  Future<void> _loadUserRoom() async {
    final user = _auth.currentUser;
    if (user != null) {
      final doc = await _db.collection('users').doc(user.uid).get();
      if (mounted) {
        final data = doc.data() as Map<String, dynamic>?;
        setState(() {
          _roomId = doc['roomId'];
          _isAdmin = data != null && (data['role'] == 'admin' || data['isAdmin'] == true);
          _isLoading = false;
        });
      }
    }
  }

  // Opens a dialog to Add or Edit a chore
  void _showChoreDialog({DocumentSnapshot? existingChore}) {
    final TextEditingController titleController = TextEditingController(
      text: existingChore != null ? existingChore['title'] : ''
    );
    double effortPoints = existingChore != null ? (existingChore['points'] as num).toDouble() : 1.0;
    int crewNeeded = existingChore != null ? existingChore['crew'] : 1;
    int frequencyDays = existingChore != null ? existingChore['frequencyDays'] : 7;

    showDialog(
      context: context,
      builder: (context) {
        // StatefulBuilder allows the dialog sliders/dropdowns to update live
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(existingChore == null ? "Add New Chore" : "Edit Chore"),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(labelText: "Task Name (e.g., Vacuuming)"),
                    ),
                    const SizedBox(height: 20),
                    
                    Text("Effort Points: ${effortPoints.toStringAsFixed(1)}"),
                    Slider(
                      value: effortPoints,
                      min: 0.5,
                      max: 5.0,
                      divisions: 9,
                      label: effortPoints.toString(),
                      onChanged: (val) => setDialogState(() => effortPoints = val),
                    ),
                    
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Crew Needed:"),
                        DropdownButton<int>(
                          value: crewNeeded,
                          items: [1, 2, 3].map((int value) {
                            return DropdownMenuItem<int>(
                              value: value,
                              child: Text("$value Person${value > 1 ? 's' : ''}"),
                            );
                          }).toList(),
                          onChanged: (val) => setDialogState(() => crewNeeded = val!),
                        ),
                      ],
                    ),

                    Text("Frequency: Every $frequencyDays day${frequencyDays > 1 ? 's' : ''}"),
                    Slider(
                      value: frequencyDays.toDouble(),
                      min: 1,
                      max: 14,
                      divisions: 13,
                      label: "$frequencyDays",
                      onChanged: (val) => setDialogState(() => frequencyDays = val.round()),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancel"),
                ),
                FilledButton(
                  onPressed: () async {
                    if (titleController.text.trim().isEmpty) return;
                    
                    final choreData = {
                      'roomId': _roomId,
                      'title': titleController.text.trim(),
                      'points': effortPoints,
                      'crew': crewNeeded,
                      'frequencyDays': frequencyDays,
                    };

                    if (existingChore == null) {
                      await _db.collection('chores').add(choreData);
                    } else {
                      // Update existing
                      await _db.collection('chores').doc(existingChore.id).update(choreData);
                    }
                    
                    // Auto-recalculate the schedule
                    await ChoreService().recalculateSchedule(_roomId!);

                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text("Save"),
                )
              ],
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: const Text("Manage Chores")),
      floatingActionButton: _isAdmin
          ? FloatingActionButton.extended(
              onPressed: () => _showChoreDialog(),
              icon: const Icon(Icons.add),
              label: const Text("Add Task"),
            )
          : null,
      body: StreamBuilder<QuerySnapshot>(
        // Listen to the database in real-time for chores in this room
        stream: _db.collection('chores').where('roomId', isEqualTo: _roomId).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          
          final chores = snapshot.data!.docs;
          
          if (chores.isEmpty) {
            return const Center(child: Text("No chores defined yet.\nTap 'Add Task' to get started!", textAlign: TextAlign.center));
          }

          return ListView.builder(
            itemCount: chores.length,
            itemBuilder: (context, index) {
              final chore = chores[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  title: Text(chore['title'], style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("${chore['points']} pts • ${chore['crew']} person crew • Every ${chore['frequencyDays']} days"),
                  trailing: _isAdmin
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, color: Colors.blue),
                              onPressed: () => _showChoreDialog(existingChore: chore),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () async {
                                await _db.collection('chores').doc(chore.id).delete();
                                await ChoreService().recalculateSchedule(_roomId!);
                              },
                            ),
                          ],
                        )
                      : null,
                ),
              );
            },
          );
        },
      ),
    );
  }
}