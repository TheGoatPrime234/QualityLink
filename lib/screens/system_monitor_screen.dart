import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import '../config/server_config.dart';
import '../services/heartbeat_service.dart';

// =============================================================================
// SYSTEM MONITOR SCREEN - MODULE 2 (Enhanced with HeartbeatService Debug Info)
// =============================================================================
class SystemMonitorScreen extends StatefulWidget {
  const SystemMonitorScreen({super.key});

  @override
  State<SystemMonitorScreen> createState() => _SystemMonitorScreenState();
}

class _SystemMonitorScreenState extends State<SystemMonitorScreen> {
  // ✅ Heartbeat Service Access
  final HeartbeatService _heartbeatService = HeartbeatService();
  
  List<String> _logLines = ["Initializing Uplink..."];
  Timer? _logTimer;
  final ScrollController _scrollController = ScrollController();
  
  // Settings
  bool _autoScroll = true;
  bool _devMode = false;
  
  // Storage Info
  Map<String, dynamic>? _storageInfo;
  Timer? _storageTimer;
  
  // Active Devices
  List<dynamic> _activeDevices = [];
  int _totalDevices = 0;
  int _onlineDevices = 0;
  
  // ✅ Heartbeat Debug Info
  Map<String, dynamic> _heartbeatDebugInfo = {};
  
  // ✅ Admin Panel Auto-Refresh
  Timer? _adminPanelTimer;
  bool _isAdminPanelOpen = false;

  @override
  void initState() {
    super.initState();
    _startLogStream();
    _fetchStorageInfo();
    _storageTimer = Timer.periodic(const Duration(seconds: 5), (t) {
      _fetchStorageInfo();
      _fetchActiveDevices();
      _updateHeartbeatInfo();
    });
    _fetchActiveDevices();
    _updateHeartbeatInfo();
  }

  @override
  void dispose() {
    _logTimer?.cancel();
    _storageTimer?.cancel();
    _adminPanelTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // ✅ Heartbeat Service Debug Info holen
  void _updateHeartbeatInfo() {
    setState(() {
      _heartbeatDebugInfo = _heartbeatService.getDebugInfo();
    });
  }

  void _startLogStream() {
    _fetchLogs();
    _logTimer = Timer.periodic(const Duration(seconds: 2), (t) => _fetchLogs());
  }

  Future<void> _fetchLogs() async {
    try {
      final response = await http.get(Uri.parse('$serverBaseUrl/logs?lines=100'));
      if (response.statusCode == 200 && mounted) {
        final newLines = LineSplitter.split(response.body)
              .where((l) => l.trim().isNotEmpty)
              .toList();

        if (newLines.length != _logLines.length || 
            (newLines.isNotEmpty && newLines.last != _logLines.last)) {
          
          setState(() {
            _logLines = newLines;
          });

          if (_autoScroll && _scrollController.hasClients) {
            Future.delayed(const Duration(milliseconds: 100), () {
              if (_scrollController.hasClients) {
                _scrollController.animateTo(
                  _scrollController.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              }
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        if (!_logLines.last.contains("CONNECTION LOST")) {
           setState(() => _logLines.add("CONNECTION LOST: $e"));
        }
      }
    }
  }

  Future<void> _fetchStorageInfo() async {
    try {
      final response = await http.get(Uri.parse('$serverBaseUrl/storage/info'));
      if (response.statusCode == 200 && mounted) {
        setState(() {
          _storageInfo = json.decode(response.body);
        });
      }
    } catch (e) {
      // Silently fail
    }
  }

  Future<void> _fetchActiveDevices() async {
    try {
      final response = await http.get(Uri.parse('$serverBaseUrl/admin/devices'));
      if (response.statusCode == 200 && mounted) {
        final data = json.decode(response.body);
        setState(() {
          _activeDevices = data['devices'];
          _totalDevices = data['total_devices'];
          _onlineDevices = data['online_devices'];
        });
      }
    } catch (e) {
      // Silently fail
    }
  }

  // --- ADMIN ACTIONS ---
  
  Future<void> _clearLogs() async {
    final confirm = await _showConfirmDialog(
      "Clear Logs?",
      "This will delete all log entries from the server.",
    );
    if (!confirm) return;

    try {
      final response = await http.post(Uri.parse('$serverBaseUrl/admin/clear_logs'));
      if (response.statusCode == 200 && mounted) {
        setState(() => _logLines = ["Logs cleared."]);
        _showSnackBar("✅ Logs cleared successfully", isError: false);
      }
    } catch (e) {
      _showSnackBar("❌ Failed to clear logs: $e", isError: true);
    }
  }

  Future<void> _clearTransfers() async {
    final confirm = await _showConfirmDialog(
      "Clear Transfer Files?",
      "This will delete all relay transfer files from the server storage.\n\n${_storageInfo?['stored_files'] ?? '?'} files will be deleted.",
    );
    if (!confirm) return;

    try {
      final response = await http.post(Uri.parse('$serverBaseUrl/admin/clear_transfers'));
      if (response.statusCode == 200 && mounted) {
        final data = json.decode(response.body);
        _showSnackBar(
          "✅ Deleted ${data['deleted_files']} files (${data['freed_mb']} MB freed)",
          isError: false,
        );
        _fetchStorageInfo();
      }
    } catch (e) {
      _showSnackBar("❌ Failed to clear transfers: $e", isError: true);
    }
  }

  Future<void> _clearAll() async {
    final confirm = await _showConfirmDialog(
      "Clear Everything?",
      "This will delete:\n• All logs\n• All transfer files (${_storageInfo?['stored_files'] ?? '?'} files)\n\nThis cannot be undone!",
      isDangerous: true,
    );
    if (!confirm) return;

    try {
      final response = await http.post(Uri.parse('$serverBaseUrl/admin/clear_all'));
      if (response.statusCode == 200 && mounted) {
        final data = json.decode(response.body);
        setState(() => _logLines = ["System cleared."]);
        _showSnackBar(
          "✅ Everything cleared! ${data['transfers']['freed_mb']} MB freed",
          isError: false,
        );
        _fetchStorageInfo();
      }
    } catch (e) {
      _showSnackBar("❌ Failed to clear: $e", isError: true);
    }
  }

  Future<void> _kickDevice(String clientId, String deviceName) async {
    final confirm = await _showConfirmDialog(
      "Kick Device?",
      "This will disconnect '$deviceName' from the server.\n\nThey can reconnect immediately.",
    );
    if (!confirm) return;

    try {
      final response = await http.post(
        Uri.parse('$serverBaseUrl/admin/kick_device'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({"client_id": clientId}),
      );
      
      if (response.statusCode == 200 && mounted) {
        _showSnackBar("✅ $deviceName kicked from server", isError: false);
        _fetchActiveDevices();
      }
    } catch (e) {
      _showSnackBar("❌ Failed to kick device: $e", isError: true);
    }
  }

  Future<void> _forceHeartbeat() async {
    await _heartbeatService.forceHeartbeat();
    _updateHeartbeatInfo();
    _showSnackBar("💓 Manual heartbeat sent", isError: false);
  }

  // ✅ Admin Panel Auto-Refresh Management
  void _startAdminPanelRefresh() {
    print("🔄 Starting Admin Panel auto-refresh");
    
    _fetchActiveDevices();
    _fetchStorageInfo();
    _updateHeartbeatInfo();
    
    _adminPanelTimer?.cancel();
    _adminPanelTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_isAdminPanelOpen && mounted) {
        _fetchActiveDevices();
        _fetchStorageInfo();
        _updateHeartbeatInfo();
      } else {
        timer.cancel();
      }
    });
  }

  void _stopAdminPanelRefresh() {
    print("⏸️ Stopping Admin Panel auto-refresh");
    setState(() => _isAdminPanelOpen = false);
    _adminPanelTimer?.cancel();
    _adminPanelTimer = null;
  }

  // FORTSETZUNG IN TEIL 2...
// FORTSETZUNG VON TEIL 1...

  void _showDeviceDetails(Map<String, dynamic> device) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Row(
          children: [
            Icon(
              _getDeviceIcon(device['type']),
              color: device['online'] ? const Color(0xFF00FF41) : Colors.grey,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                device['name'],
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow("Status", device['online'] ? "🟢 Online" : "🔴 Offline"),
            _buildDetailRow("Type", device['type']),
            _buildDetailRow("IP Address", device['ip']),
            _buildDetailRow("Client ID", device['client_id']),
            _buildDetailRow("Last Seen", "${device['last_seen_ago']}s ago"),
            const Divider(color: Colors.grey),
            _buildDetailRow("Transfers Sent", "${device['transfers_sent']}", color: Colors.orange),
            _buildDetailRow("Transfers Received", "${device['transfers_received']}", color: const Color(0xFF00E5FF)),
            _buildDetailRow("Clipboard Entries", "${device['clipboard_entries']}", color: Colors.purple),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _kickDevice(device['client_id'], device['name']);
            },
            icon: const Icon(Icons.logout, size: 16),
            label: const Text("Kick"),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF0055),
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  void _showHeartbeatDebug() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Row(
          children: [
            Icon(Icons.favorite, color: Color(0xFFFF0055), size: 24),
            SizedBox(width: 12),
            Text("HEARTBEAT SERVICE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDetailRow(
                "Status",
                _heartbeatDebugInfo['isRunning'] == true ? "🟢 Running" : "🔴 Stopped",
              ),
              _buildDetailRow(
                "Connection",
                _heartbeatDebugInfo['isConnected'] == true ? "🟢 Connected" : "🔴 Disconnected",
              ),
              const Divider(color: Colors.grey),
              _buildDetailRow("Client ID", _heartbeatDebugInfo['clientId'] ?? "N/A"),
              _buildDetailRow("Device Name", _heartbeatDebugInfo['deviceName'] ?? "N/A"),
              _buildDetailRow("Local IP", _heartbeatDebugInfo['localIp'] ?? "N/A"),
              _buildDetailRow("File Server Port", "${_heartbeatDebugInfo['fileServerPort'] ?? 'N/A'}"),
              const Divider(color: Colors.grey),
              _buildDetailRow("Interval", "${_heartbeatDebugInfo['heartbeatInterval'] ?? 'N/A'}s"),
              const Divider(color: Colors.grey),
              const Text(
                "Active Listeners:",
                style: TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold, fontSize: 12),
              ),
              const SizedBox(height: 8),
              if (_heartbeatDebugInfo['activeListeners'] != null) ...[
                _buildDetailRow("Connection", "${_heartbeatDebugInfo['activeListeners']['connection']}"),
                _buildDetailRow("Peer", "${_heartbeatDebugInfo['activeListeners']['peer']}"),
                _buildDetailRow("Error", "${_heartbeatDebugInfo['activeListeners']['error']}"),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _forceHeartbeat();
            },
            icon: const Icon(Icons.sync, size: 16),
            label: const Text("Force Beat"),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00FF41),
              foregroundColor: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          Text(
            value,
            style: TextStyle(
              color: color ?? Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  IconData _getDeviceIcon(String type) {
    switch (type.toLowerCase()) {
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'windows':
        return Icons.computer;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.desktop_mac;
      default:
        return Icons.devices;
    }
  }

  Future<bool> _showConfirmDialog(String title, String message, {bool isDangerous = false}) async {
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(
          title,
          style: TextStyle(
            color: isDangerous ? const Color(0xFFFF0055) : Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDangerous ? const Color(0xFFFF0055) : const Color(0xFF00FF41),
            ),
            child: Text(
              isDangerous ? "DELETE" : "Confirm",
              style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    ) ?? false;
  }

  void _showSnackBar(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? const Color(0xFFFF0055) : const Color(0xFF00FF41).withValues(alpha: 0.3),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showAdminPanel() {
    setState(() => _isAdminPanelOpen = true);
    _startAdminPanelRefresh();
    
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0A0A0A),
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header mit Live Indicator
                Row(
                  children: [
                    const Icon(Icons.admin_panel_settings, color: Color(0xFFFF0055), size: 28),
                    const SizedBox(width: 12),
                    const Text(
                      "ADMIN PANEL",
                      style: TextStyle(
                        color: Color(0xFFFF0055),
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00FF41).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF00FF41), width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFF00FF41),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            "LIVE",
                            style: TextStyle(
                              color: Color(0xFF00FF41),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Heartbeat Service Status
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF151515),
                    border: Border.all(color: const Color(0xFFFF0055).withValues(alpha: 0.3)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            "HEARTBEAT SERVICE",
                            style: TextStyle(
                              color: Color(0xFFFF0055),
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: (_heartbeatDebugInfo['isConnected'] == true 
                                ? const Color(0xFF00FF41) 
                                : Colors.red).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _heartbeatDebugInfo['isConnected'] == true ? "CONNECTED" : "OFFLINE",
                              style: TextStyle(
                                color: _heartbeatDebugInfo['isConnected'] == true 
                                  ? const Color(0xFF00FF41) 
                                  : Colors.red,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "Interval: ${_heartbeatDebugInfo['heartbeatInterval'] ?? 'N/A'}s",
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      Text(
                        "Local IP: ${_heartbeatDebugInfo['localIp'] ?? 'N/A'}",
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _showHeartbeatDebug,
                          icon: const Icon(Icons.favorite, size: 16),
                          label: const Text("Show Details"),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFFF0055),
                            side: const BorderSide(color: Color(0xFFFF0055)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // FORTSETZUNG IN TEIL 3...

// FORTSETZUNG VON TEIL 2...

                // Active Devices Section
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF151515),
                    border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.3)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            "ACTIVE DEVICES",
                            style: TextStyle(
                              color: Color(0xFF00E5FF),
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00FF41).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              "$_onlineDevices / $_totalDevices online",
                              style: const TextStyle(
                                color: Color(0xFF00FF41),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_activeDevices.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(
                            child: Text(
                              "No devices connected",
                              style: TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                          ),
                        )
                      else
                        ..._activeDevices.map((device) => _buildDeviceCard(device)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Storage Info
                if (_storageInfo != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF151515),
                      border: Border.all(color: const Color(0xFF00FF41).withValues(alpha: 0.3)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _storageInfo!['storage_type'] ?? 'Unknown',
                          style: const TextStyle(
                            color: Color(0xFF00FF41),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Storage: ${_storageInfo!['used_gb']} / ${_storageInfo!['total_gb']} GB (${_storageInfo!['usage_percent']}%)",
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        Text(
                          "Free: ${_storageInfo!['free_gb']} GB",
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        Text(
                          "Stored Files: ${_storageInfo!['stored_files']}",
                          style: const TextStyle(color: Colors.orange, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Action Buttons
                const Text(
                  "MAINTENANCE",
                  style: TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                _buildAdminButton("Clear Logs Only", Icons.delete_outline, _clearLogs, Colors.orange),
                const SizedBox(height: 10),
                _buildAdminButton("Clear Transfer Files", Icons.cloud_off, _clearTransfers, Colors.orange),
                const SizedBox(height: 10),
                _buildAdminButton("Clear Everything", Icons.warning, _clearAll, const Color(0xFFFF0055)),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      _stopAdminPanelRefresh();
    });
  }

  Widget _buildDeviceCard(Map<String, dynamic> device) {
    return GestureDetector(
      onTap: () => _showDeviceDetails(device),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0F0F0F),
          border: Border(
            left: BorderSide(
              color: device['online'] ? const Color(0xFF00FF41) : Colors.grey,
              width: 3,
            ),
          ),
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(4),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Row(
          children: [
            Icon(
              _getDeviceIcon(device['type']),
              color: device['online'] ? const Color(0xFF00FF41) : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device['name'],
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    "${device['ip']} • ${device['type']}",
                    style: const TextStyle(color: Colors.grey, fontSize: 10),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  device['online'] ? "ONLINE" : "OFFLINE",
                  style: TextStyle(
                    color: device['online'] ? const Color(0xFF00FF41) : Colors.grey,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  "↑${device['transfers_sent']} ↓${device['transfers_received']}",
                  style: const TextStyle(color: Colors.grey, fontSize: 9),
                ),
              ],
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              color: Colors.grey.withValues(alpha: 0.5),
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminButton(String label, IconData icon, VoidCallback onPressed, Color color) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () {
          Navigator.pop(context);
          onPressed();
        },
        icon: Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withValues(alpha: 0.2),
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(vertical: 14),
          side: BorderSide(color: color.withValues(alpha: 0.5)),
        ),
      ),
    );
  }

  bool _shouldShowInNormalMode(String line) {
    if (line.contains("[CLEANUP]")) return false;
    if (line.contains("[STORAGE]")) return false;
    if (line.contains("uvicorn")) return false;
    if (line.contains("Get all clipboard")) return false;
    return true;
  }

  String _formatForNormalMode(String line) {
    int infoIndex = line.indexOf("] ");
    String content = line;
    
    if (infoIndex != -1 && infoIndex + 2 < line.length) {
      content = line.substring(infoIndex + 2);
    }

    content = content.replaceAll("[SYSTEM]", "").trim();
    content = content.replaceAll("[HYBRID]", "").trim();
    content = content.replaceAll("[CLIPBOARD]", "").trim();
    content = content.replaceAll("[RELAY]", "").trim();
    content = content.replaceAll("[UPLOAD]", "").trim();

    return content;
  }

  IconData _getIconForLine(String line) {
    if (line.contains("ERROR") || line.contains("failed") || line.contains("verloren")) return Icons.error_outline;
    if (line.contains("CLIPBOARD") || line.contains("New entry")) return Icons.content_paste;
    if (line.contains("Upload") || line.contains("Offer")) return Icons.cloud_upload;
    if (line.contains("Download")) return Icons.cloud_download;
    if (line.contains("SYSTEM")) return Icons.system_security_update_good;
    if (line.contains("P2P") || line.contains("Direct")) return Icons.wifi_tethering;
    return Icons.info_outline;
  }

  Color _getLogColor(String line) {
    if (line.contains("[ERROR]") || line.contains("fail") || line.contains("verloren")) {
      return const Color(0xFFFF0055);
    }
    if (line.contains("[HYBRID]") || line.contains("P2P")) {
      return const Color(0xFF00E5FF);
    }
    if (line.contains("UPLOAD") || line.contains("DOWNLOAD")) {
      return Colors.white;
    }
    if (line.contains("RELAY") || line.contains("Cloud")) {
      return Colors.orange;
    }
    if (line.contains("SYSTEM")) {
      return const Color(0xFFFFD700);
    }
    return const Color(0xFF00FF41);
  }

  @override
  Widget build(BuildContext context) {
    final displayList = _devMode 
        ? _logLines 
        : _logLines.where((l) => _shouldShowInNormalMode(l)).toList();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_devMode ? "SYS // KERNEL_LOG" : "SYSTEM ACTIVITY"),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.favorite, color: Color(0xFFFF0055)),
            onPressed: _showHeartbeatDebug,
            tooltip: "Heartbeat Debug",
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.admin_panel_settings, color: Color(0xFFFF0055)),
            onPressed: _showAdminPanel,
            tooltip: "Admin Panel",
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: () => setState(() => _devMode = !_devMode),
            icon: Icon(
              _devMode ? Icons.terminal : Icons.remove_red_eye,
              color: _devMode ? const Color(0xFF00FF41) : Colors.white,
              size: 18,
            ),
            label: Text(
              _devMode ? "DEV MODE" : "NORMAL",
              style: TextStyle(
                color: _devMode ? const Color(0xFF00FF41) : Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            style: TextButton.styleFrom(
              backgroundColor: _devMode ? const Color(0xFF00FF41).withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.2),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.arrow_circle_down : Icons.pause_circle_outline,
              color: _autoScroll ? const Color(0xFF00FF41) : Colors.grey,
            ),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
            tooltip: "Auto-scroll",
          )
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          border: Border(
              top: BorderSide(
                  color: (_devMode ? const Color(0xFF00FF41) : Colors.white).withValues(alpha: 0.3))),
          color: const Color(0xFF050505),
        ),
        child: displayList.isEmpty 
          ? const Center(child: Text("No relevant logs found.", style: TextStyle(color: Colors.grey))) 
          : ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(8),
          itemCount: displayList.length,
          itemBuilder: (context, index) {
            final rawLine = displayList[index];
            
            if (_devMode) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  rawLine,
                  style: GoogleFonts.shareTechMono(
                    color: _getLogColor(rawLine),
                    fontSize: 11,
                  ),
                ),
              );
            } else {
              final cleanText = _formatForNormalMode(rawLine);
              final color = _getLogColor(rawLine);
              final icon = _getIconForLine(rawLine);
              
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF111111),
                  border: Border(left: BorderSide(color: color, width: 3)),
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(4),
                    bottomRight: Radius.circular(4)
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 16, color: color.withValues(alpha: 0.8)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        cleanText,
                        style: GoogleFonts.rajdhani(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
          },
        ),
      ),
    );
  }
}