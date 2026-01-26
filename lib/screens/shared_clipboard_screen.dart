import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:timeago/timeago.dart' as timeago;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../config/server_config.dart';
import '../services/clipboard_background_service.dart' hide serverBaseUrl;

// =============================================================================
// SHARED CLIPBOARD SCREEN (Enhanced with HeartbeatService Integration)
// =============================================================================
class SharedClipboardScreen extends StatefulWidget {
  final String clientId;
  final String deviceName;
  
  const SharedClipboardScreen({
    super.key,
    required this.clientId,
    required this.deviceName,
  });

  @override
  State<SharedClipboardScreen> createState() => _SharedClipboardScreenState();
}

class _SharedClipboardScreenState extends State<SharedClipboardScreen> with WidgetsBindingObserver {
  List<dynamic> _clipboardEntries = [];
  String? _lastClipboardContent;
  String? _lastReceivedContent; 
  bool _isConnected = false;
  bool _autoSync = true;
  bool _autoCopyMode = false;
  
  Timer? _syncTimer;
  Timer? _clipboardMonitor;
  
  String _selectedDeviceFilter = "all";
  List<String> _availableDevices = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timeago.setLocaleMessages('en', timeago.EnMessages());
    _loadSettings();
    _startSyncLoop();
    _startClipboardMonitor();
    _initBackgroundService();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _clipboardMonitor?.cancel();
    super.dispose();
  }

  // ✅ Verbessert: Sofort-Check bei App-Resume
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      print("📱 App resumed: Checking clipboard immediately...");
      _checkLocalClipboard(); 
      _pullFromServer();
    }
  }

  Future<void> _initBackgroundService() async {
    if (Platform.isAndroid) {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
      final notificationPermission = await FlutterForegroundTask.checkNotificationPermission();
      if (notificationPermission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      final isRunning = await ClipboardBackgroundService.isRunning();
      if (!isRunning && _autoSync) {
        await _startBackgroundService();
      }
    }
  }

  Future<void> _startBackgroundService() async {
    if (Platform.isAndroid) {
      await ClipboardBackgroundService.startService(widget.clientId, widget.deviceName);
    }
  }

  Future<void> _stopBackgroundService() async {
    if (Platform.isAndroid) {
      await ClipboardBackgroundService.stopService();
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoSync = prefs.getBool('clipboard_auto_sync') ?? true;
      _autoCopyMode = prefs.getBool('clipboard_auto_copy') ?? false;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('clipboard_auto_sync', _autoSync);
    await prefs.setBool('clipboard_auto_copy', _autoCopyMode);
    
    if (Platform.isAndroid) {
      if (_autoSync) await _startBackgroundService();
      else await _stopBackgroundService();
    }
  }

  // ===========================================================================
  // CLIPBOARD MONITORING
  // ===========================================================================
  void _startClipboardMonitor() {
    _clipboardMonitor = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!_autoSync) return;
      await _checkLocalClipboard();
    });
  }

  Future<void> _checkLocalClipboard() async {
    try {
      final clipData = await Clipboard.getData(Clipboard.kTextPlain);
      final content = clipData?.text?.trim();
      
      if (content != null && content.isNotEmpty) {
        if (content != _lastClipboardContent && content != _lastReceivedContent) {
          print("📋 New local content detected: ${content.substring(0, content.length > 20 ? 20 : content.length)}...");
          _lastClipboardContent = content;
          await _pushToServer(content);
        }
      }
    } catch (e) {
      // Silent fail
    }
  }

  void _startSyncLoop() {
    _pullFromServer();
    _syncTimer = Timer.periodic(const Duration(seconds: 3), (t) {
      _pullFromServer();
    });
  }

  Future<void> _pushToServer(String content) async {
    try {
      final contentType = _detectContentType(content);
      
      final response = await http.post(
        Uri.parse('$serverBaseUrl/clipboard/push'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "client_id": widget.clientId,
          "client_name": widget.deviceName,
          "content": content,
          "content_type": contentType,
        }),
      );
      
      if (response.statusCode == 200) {
        _pullFromServer();
      }
    } catch (e) {
      print("❌ Clipboard push failed: $e");
    }
  }

  Future<void> _pullFromServer() async {
    try {
      final response = await http.get(Uri.parse('$serverBaseUrl/clipboard/pull'));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> entries = data['entries'];
        
        if (mounted) {
          setState(() {
            _isConnected = true;
            _clipboardEntries = entries;
            
            _availableDevices = entries
                .map((e) => e['client_id'] as String)
                .toSet()
                .toList();
          });
          
          // AUTO-COPY LOGIC
          if (_autoCopyMode && entries.isNotEmpty) {
            final newest = entries.first;
            if (newest['client_id'] != widget.clientId) {
              final content = newest['content'] as String;
              
              if (content != _lastReceivedContent && content != _lastClipboardContent) {
                await _autoCopyToClipboard(content);
              }
            }
          }
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isConnected = false);
    }
  }

  String _detectContentType(String content) {
    if (content.startsWith('http://') || content.startsWith('https://')) return 'url';
    if (content.contains('import ') || content.contains('function ') || content.contains('class ')) return 'code';
    return 'text';
  }

  Future<void> _autoCopyToClipboard(String content) async {
    _lastReceivedContent = content;
    _lastClipboardContent = content;
    
    await Clipboard.setData(ClipboardData(text: content));
    print("📄 Auto-copied from cloud");
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("📥 Copied from cloud"),
          duration: Duration(seconds: 1),
          backgroundColor: Color(0xFF00FF41),
        ),
      );
    }
  }

  // --- USER ACTIONS ---
  Future<void> _copyToClipboard(String content) async {
    _lastReceivedContent = content;
    _lastClipboardContent = content;
    await Clipboard.setData(ClipboardData(text: content));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("📋 Copied!"),
          duration: Duration(seconds: 1),
          backgroundColor: Color(0xFF00FF41),
        ),
      );
    }
  }

  Future<void> _manualPush() async {
    await _checkLocalClipboard();
    _showSnack("✅ Manual Check Done");
  }

  Future<void> _clearMyHistory() async {
    try {
      await http.delete(Uri.parse('$serverBaseUrl/clipboard/clear/${widget.clientId}'));
      _pullFromServer();
      _showSnack("🗑️ History cleared");
    } catch (e) {
      _showSnack("❌ Error: $e", isError: true);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: isError ? Colors.red : const Color(0xFF00FF41).withValues(alpha: 0.3),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // --- FILTERING ---
  List<dynamic> get _filteredEntries {
    if (_selectedDeviceFilter == "all") return _clipboardEntries;
    return _clipboardEntries.where((e) => e['client_id'] == _selectedDeviceFilter).toList();
  }

  String _getDeviceName(String clientId) {
    final entry = _clipboardEntries.firstWhere(
      (e) => e['client_id'] == clientId,
      orElse: () => {'client_name': clientId}
    );
    return entry['client_name'];
  }

  // ===========================================================================
  // UI BUILD
  // ===========================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("SHARED CLIPBOARD"),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              _autoSync ? Icons.sync : Icons.sync_disabled,
              color: _autoSync ? const Color(0xFF00FF41) : Colors.grey,
            ),
            onPressed: () {
              setState(() => _autoSync = !_autoSync);
              _saveSettings();
            },
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                _isConnected ? "SYNCED" : "OFFLINE",
                style: TextStyle(
                  color: _isConnected ? const Color(0xFF00FF41) : Colors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF0F0F0F),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Device: ${widget.deviceName}"),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _autoSync ? "Auto-sync: ON" : "Auto-sync: OFF",
                        style: const TextStyle(color: Colors.grey, fontSize: 10),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          "Auto-copy: ",
                          style: TextStyle(color: Colors.grey, fontSize: 10),
                        ),
                        Switch(
                          value: _autoCopyMode,
                          onChanged: (val) {
                            setState(() => _autoCopyMode = val);
                            _saveSettings();
                          },
                          activeColor: const Color(0xFF00FF41),
                          inactiveThumbColor: Colors.grey,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_availableDevices.length > 1)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: DropdownButtonFormField<String>(
                value: _selectedDeviceFilter,
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Color(0xFF00FF41)),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF0F0F0F),
                ),
                dropdownColor: const Color(0xFF1A1A1A),
                style: const TextStyle(color: Colors.white, fontSize: 12),
                items: [
                  DropdownMenuItem(
                    value: "all",
                    child: Text("All Devices (${_clipboardEntries.length})"),
                  ),
                  ..._availableDevices.map((id) => DropdownMenuItem(
                    value: id,
                    child: Text(
                      "${_getDeviceName(id)} (${_clipboardEntries.where((e) => e['client_id'] == id).length})",
                    ),
                  )),
                ],
                onChanged: (v) => setState(() => _selectedDeviceFilter = v ?? "all"),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _manualPush,
                    icon: const Icon(Icons.upload),
                    label: const Text("PUSH NOW"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00FF41).withValues(alpha: 0.2),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _clearMyHistory,
                    icon: const Icon(Icons.delete_sweep),
                    label: const Text("CLEAR MINE"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF0055).withValues(alpha: 0.2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: _filteredEntries.isEmpty
                ? const Center(
                    child: Text(
                      "No entries found",
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _filteredEntries.length,
                    itemBuilder: (context, index) => _buildClipboardCard(_filteredEntries[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildClipboardCard(Map<String, dynamic> entry) {
    final content = entry['content'] as String;
    final isMyEntry = entry['client_id'] == widget.clientId;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      color: isMyEntry ? const Color(0xFF1A1A1A) : const Color(0xFF0F0F0F),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isMyEntry ? const Color(0xFF00FF41).withValues(alpha: 0.3) : Colors.transparent,
        ),
      ),
      child: InkWell(
        onTap: () => _copyToClipboard(content),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.text_fields, color: Color(0xFF00FF41), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry['client_name'],
                      style: TextStyle(
                        color: isMyEntry ? const Color(0xFF00FF41) : Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Text(
                    timeago.format(
                      DateTime.now().subtract(Duration(seconds: entry['age_seconds'])),
                      locale: 'en_short',
                    ),
                    style: const TextStyle(color: Colors.grey, fontSize: 10),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                content,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}