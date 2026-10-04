import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class SyncService extends ChangeNotifier {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;

  bool _isOffline = false;
  bool _isSyncing = false;
  bool _isProbing = false;

  bool get isOffline => _isOffline;
  bool get isSyncing => _isSyncing;

  StreamSubscription? _connectivitySubscription;
  Timer? _heartbeatTimer;

  SyncService._internal() {
    _initConnectivity();
  }

  Future<void> _initConnectivity() async {
    // Initial hardware check
    final results = await Connectivity().checkConnectivity();
    await _handleConnectivityChange(results);

    // Listen for interface changes (WiFi, Mobile data, or VPN toggle)
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(_handleConnectivityChange);

    // Heartbeat every 4 seconds to verify actual Firebase server reachability
    _startHeartbeat();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      await _verifyReachability();
    });
  }

  Future<void> _handleConnectivityChange(List<ConnectivityResult> results) async {
    final hasInterface = results.any((r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet ||
        r == ConnectivityResult.vpn);

    if (!hasInterface) {
      // No network interface enabled at all
      _setOffline(true);
      return;
    }

    // Network interface is present, probe Firebase directly to ensure it isn't blocked
    await _verifyReachability();
  }

  Future<void> _verifyReachability() async {
    if (_isProbing) return;
    _isProbing = true;

    try {
      final reachable = await _probeFirebase();
      _setOffline(!reachable);
    } finally {
      _isProbing = false;
    }
  }

  /// Secure HTTP probe to Firestore endpoint.
  /// A raw TCP socket can be fooled by firewalls intercepting traffic.
  /// Doing a full HTTPS HEAD request forces the SSL/TLS handshake (SNI), 
  /// which accurately detects if the government/ISP is blocking Firebase.
  Future<bool> _probeFirebase() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      
      final request = await client
          .headUrl(Uri.parse('https://firestore.googleapis.com/'))
          .timeout(const Duration(seconds: 3));
          
      await request.close().timeout(const Duration(seconds: 3));
      client.close();
      
      // If we get any HTTP response (even a 404), the server is reachable.
      return true;
    } catch (_) {
      return false;
    }
  }

  void _setOffline(bool offline) {
    if (_isOffline != offline) {
      _isOffline = offline;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _heartbeatTimer?.cancel();
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
      // The action took too long (likely offline or Firebase blocked).
      _setOffline(true);
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
