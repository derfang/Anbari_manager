import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class SyncService extends ChangeNotifier {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;

  bool _isOffline = false;
  bool _isSyncing = false;

  bool get isOffline => _isOffline;
  bool get isSyncing => _isSyncing;

  StreamSubscription? _connectivitySubscription;

  SyncService._internal() {
    _initConnectivity();
  }

  Future<void> _initConnectivity() async {
    // Initial check
    final results = await Connectivity().checkConnectivity();
    _updateConnectionStatus(results);

    // Listen for changes
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(_updateConnectionStatus);
  }

  void _updateConnectionStatus(List<ConnectivityResult> results) {
    bool isDisconnected = results.contains(ConnectivityResult.none) && results.length == 1;
    // If there's an active connection (e.g., wifi, mobile), isDisconnected is false
    if (!results.contains(ConnectivityResult.wifi) && 
        !results.contains(ConnectivityResult.mobile) && 
        !results.contains(ConnectivityResult.ethernet) &&
        !results.contains(ConnectivityResult.vpn)) {
      isDisconnected = true;
    } else {
      isDisconnected = false;
    }

    if (_isOffline != isDisconnected) {
      _isOffline = isDisconnected;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  /// Wraps a database write with a 3-second timeout.
  /// If it times out, it unblocks the UI, marks the app as "Syncing", 
  /// and waits in the background for Firebase to sync it when online.
  Future<void> runWithTimeout({
    required BuildContext context,
    required Future<void> Function() action,
  }) async {
    try {
      await action().timeout(const Duration(seconds: 3));
    } on TimeoutException {
      // The action took too long (likely offline).
      // We notify the user that it's queued.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Saved offline. Syncing in background..."),
            duration: Duration(seconds: 3),
          ),
        );
      }
      // Tell the SyncService to show the global Sync spinner until Firebase clears the queue
      _registerPendingWrite();
    } catch (e) {
      rethrow;
    }
  }

  void _registerPendingWrite() {
    if (!_isSyncing) {
      _isSyncing = true;
      notifyListeners();
    }
    
    // Firebase automatically tracks all queued writes.
    // This future resolves only when ALL pending offline writes are successfully synced to the server.
    FirebaseFirestore.instance.waitForPendingWrites().then((_) {
      _isSyncing = false;
      notifyListeners();
    }).catchError((_) {
      _isSyncing = false;
      notifyListeners();
    });
  }
}
