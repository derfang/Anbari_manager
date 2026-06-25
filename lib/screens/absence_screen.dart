import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

class AbsenceScreen extends StatefulWidget {
  const AbsenceScreen({super.key});

  @override
  State<AbsenceScreen> createState() => _AbsenceScreenState();
}

class _AbsenceScreenState extends State<AbsenceScreen> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  DateTime? _startDate;
  DateTime? _endDate;
  bool _isLoading = false;
  bool _isAdmin = false;
  String? _roomId;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final user = _auth.currentUser;
    if (user == null) return;
    final doc = await _db.collection('users').doc(user.uid).get();
    final data = doc.data() as Map<String, dynamic>?;
    if (mounted) {
      setState(() {
        _roomId = data?['currentRoomId'] ?? data?['roomId'];
        if (_roomId != null && data?['roles'] != null && data!['roles'][_roomId] != null) {
          _isAdmin = data['roles'][_roomId] == 'admin';
        } else {
          _isAdmin = data != null && (data['role'] == 'admin' || data['isAdmin'] == true);
        }
      });
    }
  }

  Future<void> _pickDateRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
    }
  }

  Future<void> _submitAbsence() async {
    if (_startDate == null || _endDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please select a date range first.")),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception("User not logged in");

      final userDoc = await _db.collection('users').doc(user.uid).get();

      await _db.collection('absences').add({
        'userId': user.uid,
        'userName': userDoc['name'],
        'roomId': _roomId ?? userDoc['roomId'],
        'startDate': Timestamp.fromDate(_startDate!),
        'endDate': Timestamp.fromDate(_endDate!),
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _startDate = null;
        _endDate = null;
        _isLoading = false;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Absence requested! Waiting for approval.")),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    if (user == null) return const Scaffold(body: Center(child: Text("Not logged in.")));

    return Scaffold(
      appBar: AppBar(title: const Text("Manage Absences")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const Text("Going away?", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text("Request an absence to pause your chore assignments.", textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _pickDateRange,
                            icon: const Icon(Icons.date_range),
                            label: Text(_startDate != null && _endDate != null
                                ? "${DateFormat('MMM d').format(_startDate!)} - ${DateFormat('MMM d').format(_endDate!)}"
                                : "Select Dates"),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _isLoading ? null : _submitAbsence,
                      child: _isLoading ? const CircularProgressIndicator(color: Colors.white) : const Text("Request Absence"),
                    )
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _isAdmin ? "All Absence Requests" : "My Absences",
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: _isAdmin
                    ? _db.collection('absences').where('roomId', isEqualTo: _roomId).snapshots()
                    : _db.collection('absences').where('userId', isEqualTo: user.uid).snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text("Error: ${snapshot.error}"));
                  }
                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                    return const Center(child: Text("No absences logged."));
                  }

                  final docs = snapshot.data!.docs
                    ..sort((a, b) {
                      final aTime = (a.data() as Map)['createdAt'];
                      final bTime = (b.data() as Map)['createdAt'];
                      if (aTime == null || bTime == null) return 0;
                      return (bTime as Timestamp).compareTo(aTime as Timestamp);
                    });

                  return ListView.builder(
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final doc = docs[index];
                      final data = doc.data() as Map<String, dynamic>;
                      final start = (data['startDate'] as Timestamp).toDate();
                      final end = (data['endDate'] as Timestamp).toDate();
                      final status = data['status'] as String;

                      return Card(
                        child: ListTile(
                          leading: Icon(
                            status == 'approved' ? Icons.check_circle : Icons.pending,
                            color: status == 'approved' ? Colors.green : Colors.orange,
                          ),
                          title: Text(_isAdmin
                              ? "${data['userName']} · ${DateFormat('MMM d').format(start)} - ${DateFormat('MMM d').format(end)}"
                              : "${DateFormat('MMM d').format(start)} - ${DateFormat('MMM d').format(end)}"),
                          subtitle: Text("Status: ${status.toUpperCase()}"),
                          trailing: _isAdmin
                              ? IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: () => doc.reference.delete(),
                                )
                              : null,
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
