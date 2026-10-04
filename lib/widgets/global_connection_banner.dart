import 'package:flutter/material.dart';
import '../services/sync_service.dart';

class GlobalConnectionBanner extends StatelessWidget {
  final Widget child;

  const GlobalConnectionBanner({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          child,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: AnimatedBuilder(
                animation: SyncService(),
                builder: (context, _) {
                  final syncService = SyncService();
                  
                  if (syncService.isOffline) {
                    return _buildBanner(
                      color: Colors.red.shade600,
                      icon: Icons.wifi_off,
                      text: "Offline Mode",
                    );
                  } else if (syncService.isSyncing) {
                    return _buildBanner(
                      color: Colors.orange.shade600,
                      icon: Icons.sync,
                      text: "Syncing changes...",
                      spinIcon: true,
                    );
                  }
                  
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBanner({
    required Color color,
    required IconData icon,
    required String text,
    bool spinIcon = false,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (spinIcon)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
            )
          else
            Icon(icon, color: Colors.white, size: 14),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
