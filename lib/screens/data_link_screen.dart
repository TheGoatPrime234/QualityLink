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

import '../services/data_link_service.dart';
import '../services/heartbeat_service.dart';
import '../services/overlay_foreground_service.dart';
import '../models/transfer_models.dart';
import '../widgets/futuristic_progress_bar.dart';

import '../ui/theme_constants.dart';
import '../ui/tech_card.dart';
import '../ui/global_topbar.dart';
import '../ui/parallelogram_button.dart';

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
  String? _currentTransferId;

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
      deviceName: widget.deviceName, // 🔥 FIX: Namen übergeben
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
    // 1. TRANSFER LISTENER (Aktualisiert die Liste der Transfers)
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

    // 2. PROGRESS LISTENER (Aktualisiert Ladebalken & Overlay)
    _datalink.addProgressListener((id, progress, message) {
      if (mounted) {
        setState(() {
          _currentTransferId = id; // 🔥 HIER wird die ID für den Cancel-Button gespeichert
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

    // 3. MESSAGE LISTENER (Für Popups unten am Bildschirmrand)
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

    // 4. HISTORY CLEARED LISTENER (Wenn der Server den Log löscht)
    _datalink.addHistoryClearedListener(() {
      if (mounted) {
        setState(() {
          _transfers.clear();
          _progressValue = 0.0;
          _progressMessage = "";
          _isProcessing = false;
        });
        _showSnack("🧹 Transfer history cleared");
      }
    });

    // 5. PROCESSING LISTENER (Sagt uns, ob gerade generell gearbeitet wird)
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

  void _showTransferDetails(Transfer transfer) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.primary, width: 1),
        ),
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: AppColors.primary),
            SizedBox(width: 10),
            Text("TRANSFER DETAILS", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow("File", transfer.fileName),
            _buildDetailRow("Size", transfer.sizeFormatted),
            const Divider(color: Colors.white24),
            _buildDetailRow("Sender", transfer.senderName ?? transfer.senderId),
            _buildDetailRow("Target", transfer.targetName ?? transfer.targetIds.first),
            const Divider(color: Colors.white24),
            _buildDetailRow(
              "Status", 
              transfer.status.name.toUpperCase(), 
              color: transfer.isFailed ? AppColors.warning : (transfer.isCompleted ? AppColors.primary : AppColors.accent)
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CLOSE", style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(label, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: color ?? Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
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
        content: Text(message, style: const TextStyle(color: Colors.white)),
        // Warning (Pink) für Fehler, Cyan (Primary) Glow für Erfolg
        backgroundColor: isError 
            ? AppColors.warning 
            : AppColors.primary.withValues(alpha: 0.3),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sameLanPeers = _peers.where((p) => p.isSameLan).toList();
    final otherPeers = _peers.where((p) => !p.isSameLan).toList();

    return Scaffold(
      backgroundColor: AppColors.background, 
      body: SafeArea(
        child: Column( // <--- Column hält Topbar und den Rest
          children: [
            // 1. STICKY TOPBAR
            GlobalTopbar(
              title: "DATALINK",
              statusColor: _isConnected ? AppColors.primary : AppColors.warning,
              subtitle1: "ID: ${widget.clientId}",
              subtitle2: "P2P IP: ${_datalink.myLocalIp}:${_datalink.localServerPort}",
              onSettingsTap: () {
                // Hier kommt später dein Einstellungs-Menü hin
                print("Settings tapped");
              },
            ),
            
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 20), 
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 20),
                    _buildPathSelector(),
                    const Divider(color: Colors.white10), // Subtiler
                    if (sameLanPeers.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        // P2P ist Primary (Cyan)
                        child: Text("SAME NETWORK (P2P)", style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold)),
                      ),
                      _buildPeerList(sameLanPeers),
                    ],
                    if (otherPeers.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        // Relay ist jetzt Accent (Türkis) statt Orange
                        child: Text("ONLINE (RELAY ONLY)", style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold)),
                      ),
                      _buildPeerList(otherPeers),
                    ],
                    if (_peers.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text("No devices detected...", style: TextStyle(color: AppColors.textDim))),
                      ),
                    _buildActionButtons(),
                    const Divider(color: Colors.white10),
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

  Widget _buildPathSelector() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: AppColors.card, // ✅ Card Farbe
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("DOWNLOAD LOCATION", style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          _buildPathOption("DEFAULT", "System Downloads", _systemDownloadPath ?? ""),
          ..._customPaths.map((path) => _buildPathOption(path, p.basename(path), path, isCustom: true)),
          OutlinedButton.icon(
            onPressed: _addCustomPath,
            icon: const Icon(Icons.add, size: 14),
            label: const Text("ADD PATH"),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary),
            ),
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
          color: isSelected ? AppColors.primary.withValues(alpha: 0.1) : AppColors.surface,
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.textDim.withValues(alpha: 0.3)
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked, 
              color: isSelected ? AppColors.primary : AppColors.textDim
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontWeight: FontWeight.bold, color: isSelected ? AppColors.primary : Colors.white)),
                  Text(subtitle, style: const TextStyle(color: AppColors.textDim, fontSize: 10)),
                ],
              ),
            ),
            if (isCustom)
              IconButton(
                icon: const Icon(Icons.delete, color: AppColors.warning, size: 16),
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
          // Farbe basierend auf Typ (P2P = Primary, Relay = Accent)
          final activeColor = peer.isSameLan ? AppColors.primary : AppColors.accent;
          
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
                color: isSelected ? activeColor.withValues(alpha: 0.2) : AppColors.card,
                border: Border.all(color: isSelected ? activeColor : AppColors.textDim),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_getDeviceIcon(peer.type), color: isSelected ? Colors.white : AppColors.textDim),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Row(
        children: [
          Expanded(
            child: ParallelogramButton(
              text: "FILES",
              icon: Icons.file_copy,
              onTap: _pickAndSendFiles,
              color: AppColors.primary, // ✅ Cyan
              skew: 0.3,
            ),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: ParallelogramButton(
              text: "FOLDER",
              icon: Icons.folder,
              onTap: _pickAndSendFolder,
              color: AppColors.accent, // ✅ Türkis
              skew: -0.3,
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
          child: Text("ACTIVITY LOG", style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold)),
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
      iconColor = AppColors.primary; // ✅ Cyan
    } else if (transfer.isFailed) {
      icon = Icons.error;
      iconColor = AppColors.warning; // ✅ Pink
    } else {
      icon = Icons.sync;
      iconColor = AppColors.accent; // ✅ Türkis (statt Orange)
    }

    return ListTile(
      onTap: () => _showTransferDetails(transfer),
      visualDensity: const VisualDensity(horizontal: 0, vertical: -3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      minVerticalPadding: 0, 
      leading: Icon(icon, color: iconColor), 
      title: Text(transfer.fileName, style: const TextStyle(fontSize: 18), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        transfer.isCompleted ? "Complete • ${transfer.sizeFormatted}" : transfer.isFailed ? "Failed" : "${transfer.status.name} • ${transfer.progressFormatted}",
        // Success -> Cyan, sonst Grau
        style: TextStyle(color: transfer.isCompleted ? AppColors.primary : AppColors.textDim, fontSize: 13),
      ),
      trailing: transfer.isActive
          ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(value: transfer.progress, strokeWidth: 2, color: AppColors.accent))
          : null,
    );
  }
}