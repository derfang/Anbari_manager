import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/finance_service.dart';

enum SplitType { equal, exact, percentage, mixed }

class AddExpenseScreen extends StatefulWidget {
  final String roomId;
  final String? expenseId;
  final Map<String, dynamic>? initialData;
  
  const AddExpenseScreen({super.key, required this.roomId, this.expenseId, this.initialData});

  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  final _formKey = GlobalKey<FormState>();
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FinanceService _financeService = FinanceService();

  bool _isLoading = false;
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  String _description = '';
  double _amount = 0.0;
  String? _paidByUserId;
  SplitType _splitType = SplitType.equal;

  List<Map<String, dynamic>> _roomMembers = [];
  
  // State for splits
  final Set<String> _selectedUsersForSplit = {}; // userIds selected for split
  final Map<String, TextEditingController> _exactControllers = {};
  final Map<String, TextEditingController> _percentageControllers = {};
  final Set<String> _lockedPercentageUsers = {};
  final Map<String, double> _autoCalculatedPercentages = {};
  final Map<String, String> _mixedModeUserTypes = {}; // 'exact' or 'percentage'

  @override
  void initState() {
    super.initState();
    _loadRoomMembers();
  }

  void _recalculatePercentages() {
    if (_roomMembers.isEmpty) return;
    
    double lockedTotal = 0.0;
    for (String userId in _lockedPercentageUsers) {
      if (_selectedUsersForSplit.contains(userId)) {
        lockedTotal += double.tryParse(_percentageControllers[userId]!.text) ?? 0.0;
      }
    }
    
    int unlockedCount = _roomMembers.where((m) => 
      _selectedUsersForSplit.contains(m['id']) && 
      !_lockedPercentageUsers.contains(m['id']) && 
      _mixedModeUserTypes[m['id']] == 'percentage'
    ).length;
    
    if (unlockedCount > 0) {
      double remaining = 100.0 - lockedTotal;
      double perPerson = remaining / unlockedCount;
      
      for (var member in _roomMembers) {
        String userId = member['id'];
        if (_selectedUsersForSplit.contains(userId) && !_lockedPercentageUsers.contains(userId) && _mixedModeUserTypes[userId] == 'percentage') {
          _autoCalculatedPercentages[userId] = perPerson;
        }
      }
    }
  }

  Future<void> _loadRoomMembers() async {
    setState(() => _isLoading = true);
    
    // We need to fetch users that have this roomId in their roomIds array or roomId field
    // In our DB, users belong to rooms. We query users where roomIds array contains widget.roomId
    final query = await _db.collection('users').where('roomIds', arrayContains: widget.roomId).get();
    
    if (mounted) {
      setState(() {
        _roomMembers = query.docs.map((d) => {'id': d.id, ...d.data()}).toList();
        
        // Also check for legacy users who just have 'roomId' == widget.roomId
        _db.collection('users').where('roomId', isEqualTo: widget.roomId).get().then((legacyQuery) {
          if (mounted) {
            setState(() {
              for (var doc in legacyQuery.docs) {
                if (!_roomMembers.any((m) => m['id'] == doc.id)) {
                  _roomMembers.add({'id': doc.id, ...doc.data()});
                }
              }
              
              final currentUserId = _auth.currentUser?.uid;
              for (var member in _roomMembers) {
                if (member['id'] == currentUserId) {
                  member['name'] = 'You';
                }
              }
              
              if (currentUserId != null && _roomMembers.any((m) => m['id'] == currentUserId)) {
                _paidByUserId = currentUserId;
              } else if (_roomMembers.isNotEmpty) {
                _paidByUserId = _roomMembers.first['id'];
              }

              // Initialize split state
              for (var member in _roomMembers) {
                _selectedUsersForSplit.add(member['id']); // Select all by default
                _exactControllers[member['id']] = TextEditingController();
                _percentageControllers[member['id']] = TextEditingController();
                _mixedModeUserTypes[member['id']] = 'percentage';
              }
              
                if (widget.initialData != null) {
                  _description = widget.initialData!['description'];
                  _descController.text = _description;
                  _amount = (widget.initialData!['amount'] as num).toDouble();
                  _amountController.text = _amount.toStringAsFixed(2);
                  _paidByUserId = widget.initialData!['paidBy'];
                  _splitType = SplitType.exact; // Default to exact for edits
                  
                  _selectedUsersForSplit.clear();
                  
                  Map<String, dynamic> splits = widget.initialData!['splits'];
                  splits.forEach((userId, share) {
                    _selectedUsersForSplit.add(userId);
                    double shareAmount = (share as num).toDouble();
                    _exactControllers[userId]!.text = shareAmount.toStringAsFixed(2);
                    
                    if (_amount > 0) {
                      double pct = (shareAmount / _amount) * 100;
                      _percentageControllers[userId]!.text = pct.toStringAsFixed(2);
                      _lockedPercentageUsers.add(userId); // Lock them so they act as pre-entered
                    }
                  });
                } else {
                  _recalculatePercentages();
                }
              _isLoading = false;
            });
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _descController.dispose();
    _amountController.dispose();
    for (var controller in _exactControllers.values) {
      controller.dispose();
    }
    for (var controller in _percentageControllers.values) {
      controller.dispose();
    }
    _descController.dispose();
    super.dispose();
  }

  void _saveExpense() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    if (_paidByUserId == null) return;

    if (_amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Total amount must be greater than zero.")));
      return;
    }

    Map<String, double> finalSplits = {};
    
    if (_splitType == SplitType.equal) {
      if (_selectedUsersForSplit.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Select at least one person to split with.")));
        return;
      }
      double splitAmount = _amount / _selectedUsersForSplit.length;
      for (var userId in _selectedUsersForSplit) {
        finalSplits[userId] = splitAmount;
      }
    } else if (_splitType == SplitType.exact) {
      if (_selectedUsersForSplit.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Select at least one person to split with.")));
        return;
      }
      double totalExact = 0;
      for (var member in _roomMembers) {
        if (!_selectedUsersForSplit.contains(member['id'])) continue;
        double val = double.tryParse(_exactControllers[member['id']]!.text) ?? 0.0;
        if (val < 0) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Exact amounts cannot be negative.")));
          return;
        }
        if (val > 0) {
          finalSplits[member['id']] = val;
          totalExact += val;
        }
      }
      if ((totalExact - _amount).abs() > 0.5) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Exact amounts sum to \$$totalExact, but total is \$$_amount.")));
        return;
      }
    } else if (_splitType == SplitType.percentage) {
      if (_selectedUsersForSplit.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Select at least one person to split with.")));
        return;
      }
      double totalPercent = 0;
      for (var member in _roomMembers) {
        if (!_selectedUsersForSplit.contains(member['id'])) continue;
        double pct;
        if (_lockedPercentageUsers.contains(member['id'])) {
          pct = double.tryParse(_percentageControllers[member['id']]!.text) ?? 0.0;
        } else {
          pct = _autoCalculatedPercentages[member['id']] ?? 0.0;
        }
        
        if (pct < 0 || pct > 100) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Percentages must be between 0 and 100.")));
          return;
        }
        if (pct > 0) {
          finalSplits[member['id']] = (_amount * pct) / 100.0;
          totalPercent += pct;
        }
      }
      if ((totalPercent - 100.0).abs() > 0.5) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Percentages sum to $totalPercent%, but must equal 100%.")));
        return;
      }
    } else if (_splitType == SplitType.mixed) {
      if (_selectedUsersForSplit.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Select at least one person to split with.")));
        return;
      }
      double totalExact = 0;
      double totalPercent = 0;
      
      for (var member in _roomMembers) {
        if (!_selectedUsersForSplit.contains(member['id'])) continue;
        if (_mixedModeUserTypes[member['id']] == 'exact') {
          double val = double.tryParse(_exactControllers[member['id']]!.text) ?? 0.0;
          if (val < 0) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Exact amounts cannot be negative.")));
            return;
          }
          if (val > 0) {
            finalSplits[member['id']] = val;
            totalExact += val;
          }
        }
      }
      
      if (totalExact > _amount) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Exact amounts sum to \$$totalExact, which is more than the total \$$_amount.")));
        return;
      }
      
      double remainingAmount = _amount - totalExact;
      
      for (var member in _roomMembers) {
        if (!_selectedUsersForSplit.contains(member['id'])) continue;
        if (_mixedModeUserTypes[member['id']] == 'percentage') {
          double pct;
          if (_lockedPercentageUsers.contains(member['id'])) {
            pct = double.tryParse(_percentageControllers[member['id']]!.text) ?? 0.0;
          } else {
            pct = _autoCalculatedPercentages[member['id']] ?? 0.0;
          }
          if (pct < 0 || pct > 100) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Percentages must be between 0 and 100.")));
            return;
          }
          if (pct > 0) {
            finalSplits[member['id']] = (remainingAmount * pct) / 100.0;
            totalPercent += pct;
          }
        }
      }
      
      bool hasPercentageUsers = _roomMembers.any((m) => _selectedUsersForSplit.contains(m['id']) && _mixedModeUserTypes[m['id']] == 'percentage');
      if (hasPercentageUsers && (totalPercent - 100.0).abs() > 0.5) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Percentages sum to $totalPercent%, but must equal 100%.")));
        return;
      }
      if (!hasPercentageUsers && (totalExact - _amount).abs() > 0.5) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Exact amounts sum to \$$totalExact, but total is \$$_amount.")));
        return;
      }
    }

    double currentSum = finalSplits.values.fold(0.0, (prev, curr) => prev + curr);
    double difference = _amount - currentSum;
    if (difference.abs() > 0.001) {
      if (_paidByUserId != null) {
        finalSplits[_paidByUserId!] = (finalSplits[_paidByUserId!] ?? 0.0) + difference;
      } else if (finalSplits.isNotEmpty) {
        finalSplits[finalSplits.keys.first] = finalSplits[finalSplits.keys.first]! + difference;
      }
    }

    setState(() => _isLoading = true);

    try {
      if (widget.expenseId != null) {
        await _financeService.updateExpense(
          expenseId: widget.expenseId!,
          description: _description,
          amount: _amount,
          paidBy: _paidByUserId!,
          splits: finalSplits,
          editedBy: _auth.currentUser!.uid,
        );
      } else {
        await _financeService.addExpense(
          roomId: widget.roomId,
          description: _description,
          amount: _amount,
          paidBy: _paidByUserId!,
          splits: finalSplits,
          createdBy: _auth.currentUser!.uid,
        );
      }
      
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.expenseId != null ? "Expense updated successfully!" : "Expense added successfully!")));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.expenseId != null ? "Edit Expense" : "Add Expense"),
        backgroundColor: Colors.teal.shade50,
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextFormField(
                  controller: _descController,
                  decoration: const InputDecoration(labelText: 'Description (e.g. Groceries)', border: OutlineInputBorder()),
                  validator: (val) => (val == null || val.isEmpty) ? 'Please enter a description' : null,
                  onSaved: (val) => _description = val!,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: ['Groceries', 'Utilities', 'Rent', 'Internet', 'Supplies', 'Takeout'].map((desc) {
                    return ActionChip(
                      label: Text(desc, style: const TextStyle(fontSize: 12)),
                      onPressed: () {
                        _descController.text = desc;
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _amountController,
                  decoration: const InputDecoration(labelText: 'Total Amount', prefixText: '\$', border: OutlineInputBorder()),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (val) {
                    if (val == null || val.isEmpty) return 'Please enter an amount';
                    if (double.tryParse(val) == null) return 'Enter a valid number';
                    return null;
                  },
                  onSaved: (val) => _amount = double.parse(val!),
                  onChanged: (val) {
                    setState(() {
                      _amount = double.tryParse(val) ?? 0.0;
                    });
                  },
                ),
                const SizedBox(height: 24),
                const Text("Who paid?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _paidByUserId,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                  items: _roomMembers.map((member) {
                    return DropdownMenuItem<String>(
                      value: member['id'],
                      child: Text(member['name'] ?? 'Unknown User'),
                    );
                  }).toList(),
                  onChanged: (val) {
                    setState(() => _paidByUserId = val);
                  },
                ),
                const SizedBox(height: 24),
                const Text("Split how?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                SegmentedButton<SplitType>(
                  segments: const [
                    ButtonSegment(value: SplitType.equal, label: Text("Equal")),
                    ButtonSegment(value: SplitType.exact, label: Text("Exact")),
                    ButtonSegment(value: SplitType.percentage, label: Text("Percentage")),
                    ButtonSegment(value: SplitType.mixed, label: Text("Mixed")),
                  ],
                  selected: {_splitType},
                  onSelectionChanged: (Set<SplitType> newSelection) {
                    setState(() => _splitType = newSelection.first);
                  },
                ),
                const SizedBox(height: 16),
                
                // Dynamic Split UI
                ..._roomMembers.map((member) {
                  final userId = member['id'] as String;
                  final name = member['name'] ?? 'Unknown User';

                  if (_splitType == SplitType.equal) {
                    return CheckboxListTile(
                      title: Text(name),
                      value: _selectedUsersForSplit.contains(userId),
                      onChanged: (bool? selected) {
                        setState(() {
                          if (selected == true) {
                            _selectedUsersForSplit.add(userId);
                          } else {
                            _selectedUsersForSplit.remove(userId);
                          }
                          _recalculatePercentages();
                        });
                      },
                    );
                  } else if (_splitType == SplitType.exact) {
                    bool isSelected = _selectedUsersForSplit.contains(userId);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                      child: Row(
                        children: [
                          Checkbox(
                            value: isSelected,
                            onChanged: (val) {
                              setState(() {
                                if (val == true) _selectedUsersForSplit.add(userId);
                                else _selectedUsersForSplit.remove(userId);
                                _recalculatePercentages();
                              });
                            },
                          ),
                          Expanded(child: Text(name, style: TextStyle(color: isSelected ? null : Colors.grey))),
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: _exactControllers[userId],
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              enabled: isSelected,
                              decoration: const InputDecoration(prefixText: '\$', border: OutlineInputBorder(), isDense: true),
                            ),
                          )
                        ],
                      ),
                    );
                  } else if (_splitType == SplitType.percentage) { // Percentage
                    bool isSelected = _selectedUsersForSplit.contains(userId);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                      child: Row(
                        children: [
                          Checkbox(
                            value: isSelected,
                            onChanged: (val) {
                              setState(() {
                                if (val == true) _selectedUsersForSplit.add(userId);
                                else _selectedUsersForSplit.remove(userId);
                                _recalculatePercentages();
                              });
                            },
                          ),
                          Expanded(child: Text(name, style: TextStyle(color: isSelected ? null : Colors.grey))),
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: _percentageControllers[userId],
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              enabled: isSelected,
                              decoration: InputDecoration(
                                hintText: (!_lockedPercentageUsers.contains(userId)) ? _autoCalculatedPercentages[userId]?.toStringAsFixed(2) : null,
                                suffixIcon: const SizedBox(width: 30, child: Center(child: Text('%', style: TextStyle(fontSize: 16, color: Colors.grey)))), border: const OutlineInputBorder(), isDense: true
                              ),
                              onChanged: (val) {
                                if (val.isNotEmpty) {
                                  _lockedPercentageUsers.add(userId);
                                } else {
                                  _lockedPercentageUsers.remove(userId);
                                }
                                setState(() {
                                  _recalculatePercentages();
                                });
                              },
                            ),
                          )
                        ],
                      ),
                    );
                  } else { // Mixed
                    bool isExact = _mixedModeUserTypes[userId] == 'exact';
                    bool isSelected = _selectedUsersForSplit.contains(userId);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                      child: Row(
                        children: [
                          Checkbox(
                            value: isSelected,
                            onChanged: (val) {
                              setState(() {
                                if (val == true) _selectedUsersForSplit.add(userId);
                                else _selectedUsersForSplit.remove(userId);
                                _recalculatePercentages();
                              });
                            },
                          ),
                          Expanded(child: Text(name, style: TextStyle(color: isSelected ? null : Colors.grey))),
                          DropdownButton<String>(
                            value: isExact ? 'exact' : 'percentage',
                            items: const [
                              DropdownMenuItem(value: 'percentage', child: Text('% of rest')),
                              DropdownMenuItem(value: 'exact', child: Text('\$ exact')),
                            ],
                            onChanged: isSelected ? (val) {
                              setState(() {
                                _mixedModeUserTypes[userId] = val!;
                                if (val == 'exact') {
                                  _lockedPercentageUsers.remove(userId);
                                }
                                _recalculatePercentages();
                              });
                            } : null,
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 100,
                            child: TextField(
                              controller: isExact ? _exactControllers[userId] : _percentageControllers[userId],
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              enabled: isSelected,
                              decoration: InputDecoration(
                                hintText: (!isExact && !_lockedPercentageUsers.contains(userId)) ? _autoCalculatedPercentages[userId]?.toStringAsFixed(2) : null,
                                prefixText: isExact ? '\$' : null,
                                suffixIcon: isExact ? null : const SizedBox(width: 30, child: Center(child: Text('%', style: TextStyle(fontSize: 16, color: Colors.grey)))),
                                border: const OutlineInputBorder(), 
                                isDense: true
                              ),
                              onChanged: (val) {
                                if (!isExact) {
                                  if (val.isNotEmpty) {
                                    _lockedPercentageUsers.add(userId);
                                  } else {
                                    _lockedPercentageUsers.remove(userId);
                                  }
                                }
                                setState(() {
                                  _recalculatePercentages();
                                });
                              },
                            ),
                          )
                        ],
                      ),
                    );
                  }
                }),
                
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: _saveExpense,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
                  child: Text(widget.expenseId != null ? "Update Expense" : "Save Expense", style: const TextStyle(fontSize: 18)),
                )
              ],
            ),
          ),
    );
  }
}
