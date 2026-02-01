import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:path/path.dart' as p;

import '../services/datalink_service.dart';
import '../services/heartbeat_service.dart';
import '../services/overlay_foreground_service.dart';
import '../models/transfer_models.dart';
import '../widgets/futuristic_progress_bar.dart';

// =============================================================================
// DATALINK SCREEN - P2P & Relay Dashboard
// =============================================================================

class DataLinkScreen extends StatefulWidget {
  final String clientId;
  final String deviceName;
  
  const DataLinkScreen({
    super.key,
    required this.clientId,
    required this.deviceName,
  });

  @override
  State<DataLinkScreen> createState() => _DataLinkScreenState();
}

class _DataLinkScreenState extends State<DataLinkScreen> with WidgetsBindingObserver {
  final DataLinkService _datalink = DataLinkService();
  final HeartbeatService _heartbeat = HeartbeatService();
  
  List<Peer> _peers = [];
  List<Transfer> _transfers = [];
  final Set<String> _selectedPeerIds = {};
  
  bool _isConnected = false;
  bool _isProcessing = false;
  double _progressValue = 0.0;
  String _progressMessage = "";
  ProgressBarMode _progressMode = ProgressBarMode.zipping;
  
  String _selectedPath = "DEFAULT";
  String? _systemDownloadPath;
  List<String> _customPaths = [];
  bool _serviceStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeServices();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    OverlayForegroundService.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused) {
      if (_isProcessing && Platform.isAndroid) {
        await _ensureOverlayServiceStarted();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (Platform.isAndroid) {
        try {
          if (await FlutterOverlayWindow.isActive()) {
            await FlutterOverlayWindow.closeOverlay();
          }
        } catch (e) {}
      }
    }
  }

Future<void> _initializeServices() async {
    if (Platform.isAndroid) {
      await Permission.notification.request();
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }

    await _locateSystemDownloadFolder();
    await _loadSettings();

    _setupHeartbeatService();

    await _datalink.start(
      clientId: widget.clientId,
      localIp: _heartbeat.localIp,
    );

    _datalink.setDownloadPath(_currentDownloadPath);
    _setupDataLinkListeners();

    if (Platform.isAndroid) {
      await _ensureOverlayServiceStarted();
    }
  }

  void _setupHeartbeatService() {
    _heartbeat.addConnectionListener((isConnected) {
      if (mounted) setState(() => _isConnected = isConnected);
    });

    _heartbeat.addPeerListener((peers) {
      if (mounted) {
        setState(() {
          _peers = peers.map((p) => Peer.fromJson(p, _heartbeat.localIp)).toList();
        });
      }
    });

    setState(() => _isConnected = _heartbeat.isConnected);
  }

  void _setupDataLinkListeners() {
    _datalink.addTransferListener((transfer) {
      if (mounted) {
        setState(() {
          final index = _transfers.indexWhere((t) => t.id == transfer.id);
          if (index != -1) {
            _transfers[index] = transfer;
          } else {
            _transfers.insert(0, transfer);
          }
        });
      }
    });

    _datalink.addProgressListener((id, progress, message) {
      if (mounted) {
        setState(() {
          _progressValue = progress;
          _progressMessage = message ?? "";
          
          if (message != null) {
            final lowerMsg = message.toLowerCase();
            if (lowerMsg.contains("p2p")) _progressMode = ProgressBarMode.p2p;
            else if (lowerMsg.contains("relay")) _progressMode = ProgressBarMode.relay;
            else if (lowerMsg.contains("zip")) _progressMode = ProgressBarMode.zipping;
            else if (lowerMsg.contains("upload")) _progressMode = ProgressBarMode.uploading;
          }
        });
        
        _updateOverlayService();

        if (progress >= 1.0 && _isProcessing) {
           OverlayForegroundService.showCompletionNotification(
             message ?? "Transfer successfully finished."
           );
        }
      }
    });

    _datalink.addMessageListener((message, isError) {
      _showSnack(message, isError: isError);
      if (isError && Platform.isAndroid) {
         OverlayForegroundService.showStatusNotification(
           title: "❌ Transfer Failed", 
           body: message
         );
         OverlayForegroundService.updateOverlay(
           status: "Ready", 
           progress: 0.0, 
           mode: "idle"
         );
      }
    });

    _datalink.addProcessingListener((isProcessing) {
      if (mounted) {
        setState(() => _isProcessing = isProcessing);
        
        if (isProcessing) {
          if (Platform.isAndroid) {
            OverlayForegroundService.showStatusNotification(
              title: "🚀 Transfer Started",
              body: "Processing files...",
            );
          }
          _ensureOverlayServiceStarted();
        } else {
          if (Platform.isAndroid) {
            OverlayForegroundService.updateOverlay(
              status: "QualityLink Ready",
              progress: 0.0,
              mode: "idle",
            );
          }
        }
      }
    });
  }

Future<void> _locateSystemDownloadFolder() async {
    if (Platform.isAndroid) await Permission.storage.request();
    
    _systemDownloadPath = Platform.isAndroid
        ? "/storage/emulated/0/Download"
        : (await getDownloadsDirectory())?.path;
        
    _systemDownloadPath ??= (await getApplicationDocumentsDirectory()).path;
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _customPaths = prefs.getStringList('custom_paths') ?? [];
      final savedPath = prefs.getString('selected_path');
      if (savedPath != null) _selectedPath = savedPath;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('custom_paths', _customPaths);
    await prefs.setString('selected_path', _selectedPath);
    _datalink.setDownloadPath(_currentDownloadPath);
  }

  Future<void> _addCustomPath() async {
    String? path = await FilePicker.platform.getDirectoryPath();
    if (path != null && !_customPaths.contains(path)) {
      setState(() => _customPaths.add(path));
      await _saveSettings();
    }
  }

  void _removeCustomPath(String path) async {
    setState(() => _customPaths.remove(path));
    if (_selectedPath == path) {
      setState(() => _selectedPath = "DEFAULT");
    }
    await _saveSettings();
  }

  String get _currentDownloadPath {
    return _selectedPath == "DEFAULT"
        ? (_systemDownloadPath ?? "")
        : _selectedPath;
  }

  Future<void> _ensureOverlayServiceStarted() async {
    if (!Platform.isAndroid) return;

    try {
      if (!_serviceStarted) {
        await OverlayForegroundService.startWithOverlay(
          status: "QualityLink Ready",
          progress: 0.0,
          mode: ProgressBarMode.zipping.name,
        );
        _serviceStarted = true;
      } else if (_isProcessing) {
        await _updateOverlayService();
      }
    } catch (e) {}
  }

  Future<void> _updateOverlayService() async {
    if (!Platform.isAndroid || !_serviceStarted) return;

    try {
      await OverlayForegroundService.updateOverlay(
        status: _progressMessage.isNotEmpty ? _progressMessage : "Processing...",
        progress: _progressValue,
        mode: _progressMode.name,
      );
    } catch (e) {}
  }

Future<void> _pickAndSendFiles() async {
    if (_selectedPeerIds.isEmpty) {
      _showSnack("Select at least one target", isError: true);
      return;
    }

    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;

    final files = result.files
        .where((f) => f.path != null)
        .map((f) => File(f.path!))
        .toList();

    if (files.isEmpty) return;

    try {
      setState(() => _progressMode = ProgressBarMode.p2p);
      await _datalink.sendFiles(files, _selectedPeerIds.toList());
    } catch (e) {
      _showSnack("Send failed", isError: true);
    }
  }

  Future<void> _pickAndSendFolder() async {
    if (_selectedPeerIds.isEmpty) {
      _showSnack("Select at least one target", isError: true);
      return;
    }

    String? folderPath = await FilePicker.platform.getDirectoryPath();
    if (folderPath == null) return;

    try {
      setState(() => _progressMode = ProgressBarMode.zipping);
      
      await _datalink.sendFolder(
        Directory(folderPath),
        _selectedPeerIds.toList(),
        onProgress: (progress, message) {
          setState(() {
            _progressValue = progress;
            _progressMessage = message;
          });
        },
      );
    } catch (e) {
      _showSnack("Send failed", isError: true);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : const Color(0xFF00FF41).withValues(alpha: 0.3),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sameLanPeers = _peers.where((p) => p.isSameLan).toList();
    final otherPeers = _peers.where((p) => !p.isSameLan).toList();

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            if (_isProcessing)
              FuturisticProgressBar(
                progress: _progressValue,
                subtitle: _progressMessage,
                mode: _progressMode,
                label: "Processing", 
              ),
            
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 20), 
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 20),
                    _buildPathSelector(),
                    const Divider(),
                    if (sameLanPeers.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text("SAME NETWORK (P2P)", style: TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold)),
                      ),
                      _buildPeerList(sameLanPeers),
                    ],
                    if (otherPeers.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text("ONLINE (RELAY ONLY)", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                      ),
                      _buildPeerList(otherPeers),
                    ],
                    if (_peers.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text("No devices detected...", style: TextStyle(color: Colors.grey))),
                      ),
                    _buildActionButtons(),
                    const Divider(),
                    _buildActivityLog(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: const Color(0xFF0F0F0F),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text("DATALINK", style: TextStyle(color: Color(0xFF00FF41), fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(width: 12),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _isConnected ? const Color(0xFF00FF41) : Colors.red,
                  shape: BoxShape.circle,
                  boxShadow: _isConnected ? [BoxShadow(color: const Color(0xFF00FF41).withValues(alpha: 0.5), blurRadius: 8, spreadRadius: 2)] : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text("ID: ${widget.clientId}", style: const TextStyle(color: Colors.grey, fontSize: 10)),
          Text("P2P IP: ${_datalink.myLocalIp}:${_datalink.localServerPort}", style: const TextStyle(color: Colors.grey, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildPathSelector() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: const Color(0xFF0A0A0A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("DOWNLOAD LOCATION", style: TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          _buildPathOption("DEFAULT", "System Downloads", _systemDownloadPath ?? ""),
          ..._customPaths.map((path) => _buildPathOption(path, p.basename(path), path, isCustom: true)),
          OutlinedButton.icon(
            onPressed: _addCustomPath,
            icon: const Icon(Icons.add, size: 14),
            label: const Text("ADD PATH"),
            style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF00FF41)),
          ),
        ],
      ),
    );
  }

  Widget _buildPathOption(String value, String label, String subtitle, {bool isCustom = false}) {
    final isSelected = _selectedPath == value;
    return GestureDetector(
      onTap: () async {
        setState(() => _selectedPath = value);
        await _saveSettings();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF00FF41).withValues(alpha: 0.1) : const Color(0xFF151515),
          border: Border.all(color: isSelected ? const Color(0xFF00FF41) : Colors.grey.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: isSelected ? const Color(0xFF00FF41) : Colors.grey),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontWeight: FontWeight.bold, color: isSelected ? const Color(0xFF00FF41) : Colors.white)),
                  Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 10)),
                ],
              ),
            ),
            if (isCustom)
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red, size: 16),
                onPressed: () => _removeCustomPath(value),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeerList(List<Peer> peers) {
    return SizedBox(
      height: 100,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: peers.length,
        itemBuilder: (context, index) {
          final peer = peers[index];
          final isSelected = _selectedPeerIds.contains(peer.id);
          
          return GestureDetector(
            onTap: () {
              setState(() {
                if (isSelected) _selectedPeerIds.remove(peer.id);
                else _selectedPeerIds.add(peer.id);
              });
            },
            child: Container(
              width: 90,
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF00FF41).withValues(alpha: 0.2) : const Color(0xFF111111),
                border: Border.all(color: isSelected ? const Color(0xFF00FF41) : Colors.grey),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_getDeviceIcon(peer.type), color: isSelected ? Colors.white : Colors.grey),
                  const SizedBox(height: 4),
                  Text(peer.name, style: const TextStyle(fontSize: 10), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  IconData _getDeviceIcon(String type) {
    switch (type.toLowerCase()) {
      case 'android': return Icons.phone_android;
      case 'ios': return Icons.phone_iphone;
      case 'windows': return Icons.computer;
      case 'macos': return Icons.laptop_mac;
      case 'linux': return Icons.desktop_mac;
      default: return Icons.devices;
    }
  }

  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _pickAndSendFiles,
              icon: const Icon(Icons.file_copy),
              label: const Text("FILES"),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF222222), minimumSize: const Size(0, 48)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _pickAndSendFolder,
              icon: const Icon(Icons.folder),
              label: const Text("FOLDER"),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF0055).withValues(alpha: 0.2), minimumSize: const Size(0, 48)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityLog() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text("ACTIVITY LOG", style: TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
        
        if (_transfers.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text("No transfers yet", style: TextStyle(color: Colors.grey, fontSize: 12))),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero, 
            itemCount: _transfers.length,
            itemBuilder: (context, index) {
              final transfer = _transfers[index];
              return _buildTransferTile(transfer);
            },
          ),
      ],
    );
  }

  Widget _buildTransferTile(Transfer transfer) {
    IconData icon;
    Color iconColor;
    
    if (transfer.isCompleted) {
      icon = Icons.check_circle;
      iconColor = const Color(0xFF00FF41);
    } else if (transfer.isFailed) {
      icon = Icons.error;
      iconColor = Colors.red;
    } else {
      icon = Icons.sync;
      iconColor = Colors.orange;
    }

    return ListTile(
      visualDensity: const VisualDensity(horizontal: 0, vertical: -3), 
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      minVerticalPadding: 0, 
      leading: Icon(icon, color: iconColor), 
      title: Text(transfer.fileName, style: const TextStyle(fontSize: 18), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        transfer.isCompleted ? "Complete • ${transfer.sizeFormatted}" : transfer.isFailed ? "Failed" : "${transfer.status.name} • ${transfer.progressFormatted}",
        style: TextStyle(color: transfer.isCompleted ? const Color(0xFF00FF41) : Colors.grey, fontSize: 13),
      ),
      trailing: transfer.isActive
          ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(value: transfer.progress, strokeWidth: 2, color: const Color(0xFF00FF41)))
          : null,
    );
  }
}