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
import '../services/sync_paste_service.dart' hide serverBaseUrl;

import '../ui/theme_constants.dart';
import '../ui/tech_card.dart';
import '../ui/parallelogram_button.dart';

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
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
      if (_autoSync) {
        await _startBackgroundService();
      } else {
        await _stopBackgroundService();
      }
    }
  }

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
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("📥 Copied from cloud"),
          duration: Duration(seconds: 1),
          backgroundColor: AppColors.primary,
        ),
      );
    }
  }

  Future<void> _copyToClipboard(String content) async {
    _lastReceivedContent = content;
    _lastClipboardContent = content;
    await Clipboard.setData(ClipboardData(text: content));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("📋 Copied!"),
          duration: Duration(seconds: 1),
          backgroundColor: AppColors.primary,
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
          backgroundColor: isError ? AppColors.warning : AppColors.primary.withValues(alpha: 0.3),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            // 1. HEADER (Cleaned up, no buttons)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: AppColors.surface,
              child: Row(
                children: [
                  const Text("SYNCPASTE", style: TextStyle(color: AppColors.primary, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 12),
                  // Status Dot
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _isConnected ? AppColors.primary : AppColors.warning,
                      shape: BoxShape.circle,
                      boxShadow: _isConnected 
                          ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.5), blurRadius: 8, spreadRadius: 2)] 
                          : null,
                    ),
                  ),
                  
                  // SPACER sorgt dafür, dass rechts ALLES leer bleibt für das App Icon
                  const Spacer(),
                ],
              ),
            ),

            // 2. INFO HEADER (TechCard) - ✅ UMBAU: Zwei Switches untereinander
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TechCard(
                borderColor: AppColors.accent.withValues(alpha: 0.3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("DEVICE ID", style: TextStyle(color: AppColors.textDim, fontSize: 10)),
                        Text(widget.deviceName, style: const TextStyle(color: AppColors.textMain, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const Divider(color: Colors.white10),
                    
                    // ZEILE 1: Auto-Copy (mit Switch)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("AUTO-COPY MODE", style: TextStyle(color: AppColors.textDim, fontSize: 12)),
                        Switch(
                          value: _autoCopyMode,
                          onChanged: (val) {
                            setState(() => _autoCopyMode = val);
                            _saveSettings();
                          },
                          activeColor: AppColors.primary,
                          activeTrackColor: AppColors.primary.withValues(alpha: 0.3),
                          inactiveThumbColor: Colors.grey,
                          inactiveTrackColor: Colors.grey.withValues(alpha: 0.3),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ],
                    ),

                    const SizedBox(height: 4),

                    // ZEILE 2: Auto-Sync (JETZT AUCH EIN SWITCH)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                         Text(
                          "AUTO-SYNC MODE", // Label vereinheitlicht
                          style: TextStyle(color: _autoSync ? AppColors.primary : AppColors.textDim, fontSize: 12),
                        ),
                        Switch(
                          value: _autoSync,
                          onChanged: (val) {
                            setState(() => _autoSync = val);
                            _saveSettings();
                          },
                          activeColor: AppColors.primary,
                          activeTrackColor: AppColors.primary.withValues(alpha: 0.3),
                          inactiveThumbColor: Colors.grey,
                          inactiveTrackColor: Colors.grey.withValues(alpha: 0.3),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // DROPDOWN FILTER
            if (_availableDevices.length > 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TechCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  borderColor: AppColors.accent.withValues(alpha: 0.3),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedDeviceFilter,
                      dropdownColor: AppColors.card,
                      isExpanded: true,
                      style: const TextStyle(color: AppColors.textMain),
                      icon: const Icon(Icons.arrow_drop_down, color: AppColors.accent),
                      items: [
                        DropdownMenuItem(
                          value: "all",
                          child: Text("ALL SIGNALS (${_clipboardEntries.length})"),
                        ),
                        ..._availableDevices.map((id) => DropdownMenuItem(
                          value: id,
                          child: Text("${_getDeviceName(id).toUpperCase()}"),
                        )),
                      ],
                      onChanged: (v) => setState(() => _selectedDeviceFilter = v ?? "all"),
                    ),
                  ),
                ),
              ),

            // ACTIONS (Parallelogram Buttons)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: ParallelogramButton(
                      text: "PUSH NOW",
                      icon: Icons.upload,
                      onTap: _manualPush,
                      color: AppColors.accent, // Türkis
                      skew: 0.3, // Neigung nach Rechts
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: ParallelogramButton(
                      text: "CLEAR MINE",
                      icon: Icons.delete_sweep,
                      onTap: _clearMyHistory,
                      color: AppColors.warning,
                      skew: -0.3, // Neigung nach Links
                    ),
                  ),
                ],
              ),
            ),

            const Divider(color: Colors.white10),

            // LISTE
            Expanded(
              child: _filteredEntries.isEmpty
                  ? const Center(
                      child: Text(
                        "NO DATA STREAM",
                        style: TextStyle(color: AppColors.textDim, letterSpacing: 2),
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
      ),
    );
  }

  Widget _buildClipboardCard(Map<String, dynamic> entry) {
    final content = entry['content'] as String;
    final isMyEntry = entry['client_id'] == widget.clientId;
    
    return TechCard(
      borderColor: isMyEntry ? AppColors.primary.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.1),
      onTap: () => _copyToClipboard(content),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.text_fields, color: isMyEntry ? AppColors.primary : AppColors.accent, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry['client_name'].toString().toUpperCase(),
                  style: TextStyle(
                    color: isMyEntry ? AppColors.primary : AppColors.accent,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 1,
                  ),
                ),
              ),
              Text(
                timeago.format(
                  DateTime.now().subtract(Duration(seconds: entry['age_seconds'])),
                  locale: 'en_short',
                ).toUpperCase(),
                style: const TextStyle(color: AppColors.textDim, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            content,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
          ),
        ],
      ),
    );
  }
}