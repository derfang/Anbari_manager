import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../services/chore_service.dart';
import '../utils/chore_icons.dart';

class ForceInsertTaskDialog extends StatefulWidget {
  final String roomId;

  const ForceInsertTaskDialog({super.key, required this.roomId});

  static Future<void> show(BuildContext context, String roomId) {
    return showDialog(
      context: context,
      builder: (ctx) => ForceInsertTaskDialog(roomId: roomId),
    );
  }

  @override
  State<ForceInsertTaskDialog> createState() => _ForceInsertTaskDialogState();
}

class _ForceInsertTaskDialogState extends State<ForceInsertTaskDialog> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final TextEditingController _titleController = TextEditingController();

  bool _isExistingChore = true;
  String? _selectedChoreId;
  String? _selectedUserId;
  String? _selectedUserName;
  DateTime _selectedDate = DateTime.now();
  double _customPoints = 1.0;
  String _customIcon = 'cleaning_services';
  bool _isSubmitting = false;

  List<QueryDocumentSnapshot> _chores = [];
  List<QueryDocumentSnapshot> _users = [];
  bool _isLoadingData = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final results = await Future.wait([
        _db.collection('chores').where('roomId', isEqualTo: widget.roomId).get(),
        _db.collection('users').where(Filter.or(
          Filter('roomId', isEqualTo: widget.roomId),
          Filter('roomIds', arrayContains: widget.roomId),
        )).get(),
      ]);

      final choreSnap = results[0];
      final userSnap = results[1];

      if (mounted) {
        setState(() {
          _chores = choreSnap.docs.where((doc) {
            final data = doc.data();
            return data['isOneOff'] != true;
          }).toList();

          _users = userSnap.docs;

          if (_chores.isNotEmpty) {
            _selectedChoreId = _chores.first.id;
          }
          if (_users.isNotEmpty) {
            _selectedUserId = _users.first.id;
            _selectedUserName = (_users.first.data() as Map<String, dynamic>)['name'] ?? 'Roommate';
          }
          _isLoadingData = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingData = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error loading room data: $e")));
      }
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 14)),
      lastDate: DateTime.now().add(const Duration(days: 30)),
    );
    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _handleSubmit() async {
    if (_selectedUserId == null || _selectedUserName == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please select a roommate.")));
      return;
    }

    String choreTitle;
    String choreIcon;
    double points;
    String? choreId;

    if (_isExistingChore) {
      if (_selectedChoreId == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please select a chore.")));
        return;
      }
      final choreDoc = _chores.firstWhere((c) => c.id == _selectedChoreId);
      final choreData = choreDoc.data() as Map<String, dynamic>;
      choreTitle = choreData['title'] ?? 'Chore';
      choreIcon = choreData['icon'] ?? 'cleaning_services';
      points = (choreData['points'] as num? ?? 1.0).toDouble();
      choreId = choreDoc.id;
    } else {
      choreTitle = _titleController.text.trim();
      if (choreTitle.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please enter a task name.")));
        return;
      }
      choreIcon = _customIcon;
      points = _customPoints;
      choreId = null; // forceInsertAssignment will create a one-off chore doc
    }

    setState(() => _isSubmitting = true);

    try {
      await ChoreService().forceInsertAssignment(
        roomId: widget.roomId,
        choreId: choreId,
        title: choreTitle,
        icon: choreIcon,
        points: points,
        date: _selectedDate,
        assignedToUserId: _selectedUserId!,
        assignedToName: _selectedUserName!,
      );

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Task \"$choreTitle\" assigned to $_selectedUserName!")),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error assigning task: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingData) {
      return const AlertDialog(
        content: SizedBox(
          height: 100,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final availableIcons = choreIcons.keys.toList();

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.assignment_ind, color: Colors.teal),
          SizedBox(width: 8),
          Text("Force Insert Task"),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Directly assigns a task without modifying or recalculating any other scheduled chores.",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),

            // Segmented mode switcher
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text("Existing Chore"), icon: Icon(Icons.list_alt)),
                ButtonSegment(value: false, label: Text("Custom Task"), icon: Icon(Icons.flash_on)),
              ],
              selected: {_isExistingChore},
              onSelectionChanged: (val) {
                setState(() => _isExistingChore = val.first);
              },
            ),
            const SizedBox(height: 16),

            if (_isExistingChore) ...[
              if (_chores.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: Text("No existing chores available. Please switch to Custom Task.", style: TextStyle(color: Colors.orange)),
                )
              else
                DropdownButtonFormField<String>(
                  value: _selectedChoreId,
                  decoration: const InputDecoration(
                    labelText: "Select Chore",
                    border: OutlineInputBorder(),
                  ),
                  items: _chores.map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    return DropdownMenuItem<String>(
                      value: doc.id,
                      child: Row(
                        children: [
                          Icon(choreIcons[data['icon']] ?? Icons.cleaning_services, size: 20, color: Colors.teal),
                          const SizedBox(width: 8),
                          Text("${data['title']} (${data['points']} pts)"),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (val) => setState(() => _selectedChoreId = val),
                ),
            ] else ...[
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: "Task Name (e.g. Clean Garage)",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text("Effort Points: ${_customPoints.toStringAsFixed(1)}", style: const TextStyle(fontWeight: FontWeight.bold)),
              Slider(
                value: _customPoints,
                min: 0.5,
                max: 5.0,
                divisions: 9,
                label: _customPoints.toString(),
                onChanged: (val) => setState(() => _customPoints = val),
              ),
              const Text("Icon:", style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: availableIcons.map((iconName) {
                  final isSelected = _customIcon == iconName;
                  return GestureDetector(
                    onTap: () => setState(() => _customIcon = iconName),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.teal.withOpacity(0.2) : Colors.grey.withOpacity(0.1),
                        border: Border.all(color: isSelected ? Colors.teal : Colors.transparent, width: 2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        choreIcons[iconName] ?? Icons.cleaning_services,
                        size: 24,
                        color: isSelected ? Colors.teal : Colors.grey.shade700,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],

            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),

            // Assignee Dropdown
            DropdownButtonFormField<String>(
              value: _selectedUserId,
              decoration: const InputDecoration(
                labelText: "Assign To",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
              items: _users.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                final name = data['name'] ?? 'Roommate';
                return DropdownMenuItem<String>(
                  value: doc.id,
                  child: Text(name),
                );
              }).toList(),
              onChanged: (val) {
                final userDoc = _users.firstWhere((u) => u.id == val);
                final name = (userDoc.data() as Map<String, dynamic>)['name'] ?? 'Roommate';
                setState(() {
                  _selectedUserId = val;
                  _selectedUserName = name;
                });
              },
            ),

            const SizedBox(height: 16),

            // Due Date
            Row(
              children: [
                const Icon(Icons.calendar_today, color: Colors.teal),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Due Date", style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text(
                        DateFormat('EEEE, MMM d, yyyy').format(_selectedDate),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: _pickDate,
                  child: const Text("Change"),
                ),
              ],
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
          onPressed: _isSubmitting ? null : _handleSubmit,
          child: _isSubmitting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text("Assign Task"),
        ),
      ],
    );
  }
}
