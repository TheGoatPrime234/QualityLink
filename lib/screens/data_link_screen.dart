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
import '../services/device_manager.dart';

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
  
  List<NetworkDevice> _peers = [];
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
  final Set<String> _currentBatchIds = {};
  bool _showFilePreview = true; // 🔥 NEU: Steuert die Vorschau

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeServices();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    
    // 🔥 FIX 3: Alte Listener aufräumen, damit sich beim Tab-Wechsel nichts aufstaut!
    _heartbeat.clearListeners();
    _datalink.removeAllListeners();
    
    // Bonus-Fix: Die Notification (Overlay) nur schließen, wenn WIRKLICH nichts mehr lädt!
    if (!_datalink.isProcessing) {
      OverlayForegroundService.stop();
    }
    
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
    _updatePeerList();
    
    // Auf globale Updates des DeviceManagers hören
    DeviceManager().addListener(() {
      if (mounted) _updatePeerList();
    });

    _heartbeat.addConnectionListener((isConnected) {
      if (mounted) setState(() => _isConnected = isConnected);
    });

    setState(() => _isConnected = _heartbeat.isConnected);
  }

  // 🔥 NEU: Baut die Liste und setzt die Cloud immer nach ganz vorne!
  void _updatePeerList() {
    final cloudDevice = NetworkDevice(
      id: "CLOUD",
      name: "SERVER CLOUD",
      type: "cloud", // Spezieller Typ für das Icon
      ip: "127.0.0.1",
      isOnline: true,
      isSameLan: true, // Damit es im ersten P2P-Reiter (oben) auftaucht
    );
    
    final otherDevices = DeviceManager().devices
        .where((d) => d.id != widget.clientId && d.id != "SERVER") 
        .toList();
        
    setState(() {
      _peers = [cloudDevice, ...otherDevices];
    });
  }

  void _setupDataLinkListeners() {
    // 1. TRANSFER LISTENER
    _datalink.addTransferListener((transfer) {
      if (mounted) {
        setState(() {
          final index = _transfers.indexWhere((t) => t.id == transfer.id);
          if (index != -1) {
            _transfers[index] = transfer;
          } else {
            _transfers.insert(0, transfer);
          }
          
          // 🔥 BATCH-TRACKING: Neu in die Schlange aufnehmen
          if (transfer.status == TransferStatus.queued || transfer.isActive) {
             _currentBatchIds.add(transfer.id);
          }
        });
      }
    });

    // 2. PROGRESS LISTENER (Mit globaler MB-Berechnung)
    _datalink.addProgressListener((id, progress, message) {
      if (mounted) {
        setState(() {
          _currentTransferId = id;
          
          if (message != null) {
            final lowerMsg = message.toLowerCase();
            if (lowerMsg.contains("p2p")) _progressMode = ProgressBarMode.p2p;
            else if (lowerMsg.contains("relay")) _progressMode = ProgressBarMode.relay;
            else if (lowerMsg.contains("zip")) _progressMode = ProgressBarMode.zipping;
            else if (lowerMsg.contains("upload")) _progressMode = ProgressBarMode.uploading;
          }

          // 🔥 GLOBALE BERECHNUNG ALLER DATEIEN IN DER SCHLANGE
          int totalBytes = 0;
          double transferredBytes = 0;
          
          for (var t in _transfers) {
            if (_currentBatchIds.contains(t.id)) {
              // Abgebrochene/Fehlerhafte Dateien aus der Rechnung nehmen
              if (t.status == TransferStatus.failed || t.status == TransferStatus.cancelled) {
                continue; 
              }
              
              totalBytes += t.fileSize;
              double p = t.isCompleted ? 1.0 : t.progress;
              if (p.isNaN || p.isInfinite) p = 0.0;
              
              transferredBytes += (t.fileSize * p);
            }
          }
          
          if (totalBytes > 0) {
            _progressValue = transferredBytes / totalBytes;
            String transMb = (transferredBytes / 1024 / 1024).toStringAsFixed(1);
            String totalMb = (totalBytes / 1024 / 1024).toStringAsFixed(1);
            
            // Text bereinigen und MB anhängen (z.B. "Uploading... (15.2 / 50.0 MB)")
            String baseMsg = message?.split('(').first.trim() ?? "Processing...";
            _progressMessage = "$baseMsg ($transMb / $totalMb MB)";
          } else {
            _progressValue = progress;
            _progressMessage = message ?? "Processing...";
          }
        });
        
        _updateOverlayService();
      }
    });

    // 3. MESSAGE LISTENER
    _datalink.addMessageListener((message, isError) {
      _showSnack(message, isError: isError);
      if (isError && Platform.isAndroid) {
         OverlayForegroundService.showStatusNotification(title: "❌ Transfer Failed", body: message);
         OverlayForegroundService.updateOverlay(status: "Ready", progress: 0.0, mode: "idle");
      }
    });

    // 4. HISTORY CLEARED
    _datalink.addHistoryClearedListener(() {
      if (mounted) {
        setState(() {
          _transfers.clear();
          _currentBatchIds.clear(); // 🔥 Batch leeren
          _progressValue = 0.0;
          _progressMessage = "";
          _isProcessing = false;
        });
        _showSnack("🧹 Transfer history cleared");
      }
    });

    // 5. PROCESSING LISTENER
    _datalink.addProcessingListener((isProcessing) {
      if (mounted) {
        setState(() {
          _isProcessing = isProcessing;
          
          // 🔥 Wenn alles fertig ist, setzen wir den Batch für die nächste Runde zurück
          bool hasQueued = _transfers.any((t) => t.status == TransferStatus.queued);
          if (!isProcessing && !hasQueued) {
            _currentBatchIds.clear();
          }
        });
        
        if (isProcessing) {
          if (Platform.isAndroid) {
            OverlayForegroundService.showStatusNotification(title: "🚀 Transfer Started", body: "Processing files...");
          }
          _ensureOverlayServiceStarted();
        } else {
          if (Platform.isAndroid) {
            OverlayForegroundService.updateOverlay(status: "QualityLink Ready", progress: 0.0, mode: "idle");
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
      
      // 🔥 NEU: Lade den Zustand der Vorschau
      _showFilePreview = prefs.getBool('datalink_show_preview') ?? true; 
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('custom_paths', _customPaths);
    await prefs.setString('selected_path', _selectedPath);
    
    // 🔥 NEU: Speichere den Zustand
    await prefs.setBool('datalink_show_preview', _showFilePreview); 
    
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
                showModalBottomSheet(
                  context: context,
                  backgroundColor: AppColors.card,
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                  builder: (ctx) => StatefulBuilder( // StatefulBuilder aktualisiert den Switch live!
                    builder: (ctx, setModalState) => Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("DATALINK SETTINGS", style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 20),
                          SwitchListTile(
                            title: const Text("Show File Previews", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            subtitle: const Text("Load thumbnails in the activity log", style: TextStyle(color: AppColors.textDim, fontSize: 12)),
                            activeColor: AppColors.primary,
                            value: _showFilePreview,
                            onChanged: (val) {
                              setState(() => _showFilePreview = val); // Screen aktualisieren
                              setModalState(() => _showFilePreview = val); // Switch aktualisieren
                              _saveSettings();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 20), 
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 20),

                    // 🔥 DIE SMARTE WARTESCHLANGEN-PROGRESSBAR
                    if (_isProcessing || _transfers.any((t) => t.status == TransferStatus.queued || t.status == TransferStatus.offered))
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(bottom: 16),
                        child: FuturisticProgressBar(
                          progress: _progressValue,
                          label: _progressMessage.isNotEmpty ? _progressMessage : "PROCESSING QUEUE...",
                          mode: _progressMode,
                          // Smarter Subtitle, der die Schlange zählt:
                          subtitle: (() {
                            int queued = _transfers.where((t) => t.status == TransferStatus.queued).length;
                            if (queued > 0) return "$queued ITEMS WAITING IN QUEUE";
                            return "TRANSFER ACTIVE";
                          })(),
                          // Wenn man auf das X klickt, bricht der aktuelle ab und der nächste in der Schlange startet!
                          onCancel: _currentTransferId != null ? () {
                            _datalink.cancelTransfer(_currentTransferId!);
                          } : null,
                        ),
                      ),

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

  Widget _buildPeerList(List<NetworkDevice> peers) {
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
          final isCloud = peer.id == "CLOUD";
          final activeColor = isCloud ? const Color(0xFFAA00FF) : (peer.isSameLan ? AppColors.primary : AppColors.accent);
          
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
      case 'cloud': return Icons.cloud;
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
      iconColor = AppColors.primary; 
    } else if (transfer.isFailed) {
      icon = Icons.error;
      iconColor = AppColors.warning; 
    } else if (transfer.status == TransferStatus.queued) { 
      icon = Icons.hourglass_empty;
      iconColor = Colors.grey; 
    } else {
      icon = Icons.sync;
      iconColor = AppColors.accent; 
    }

    // 🔥 NEU: Die Vorschau (Thumbnail) Logik
    final ext = p.extension(transfer.fileName).toLowerCase();
    final isImage = ['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext);

    Widget leadingWidget;
    
    // Wenn Vorschau aktiv ist, es ein Bild ist und der Transfer fertig ist
    if (_showFilePreview && isImage && transfer.isCompleted) {
       // Wir suchen den Pfad zur Datei
       String potentialPath = p.join(transfer.destinationPath ?? _currentDownloadPath, transfer.fileName);
       
       leadingWidget = Container(
         width: 40, height: 40,
         decoration: BoxDecoration(
           color: iconColor.withValues(alpha: 0.1),
           borderRadius: BorderRadius.circular(4),
           border: Border.all(color: iconColor.withValues(alpha: 0.3)),
         ),
         child: ClipRRect(
           borderRadius: BorderRadius.circular(3),
           child: Image.file(
             File(potentialPath),
             fit: BoxFit.cover,
             // Fallback: Wenn die Datei gelöscht oder verschoben wurde, zeige das normale Icon
             errorBuilder: (ctx, err, stack) => Icon(icon, color: iconColor, size: 20),
           ),
         ),
       );
    } else {
       // Standard-Icon für laufende Transfers oder Nicht-Bilder
       leadingWidget = Container(
         width: 40, height: 40,
         decoration: BoxDecoration(
           color: iconColor.withValues(alpha: 0.1),
           borderRadius: BorderRadius.circular(4),
           border: Border.all(color: iconColor.withValues(alpha: 0.3)),
         ),
         child: Icon(icon, color: iconColor, size: 20),
       );
    }

    return ListTile(
      onTap: () => _showTransferDetails(transfer),
      visualDensity: const VisualDensity(horizontal: 0, vertical: -3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), // Etwas mehr Platz für die Box
      minVerticalPadding: 0, 
      leading: leadingWidget, // 🔥 Hier bauen wir unsere neue Vorschau/Icon-Box ein!
      title: Text(transfer.fileName, style: const TextStyle(fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        transfer.isCompleted ? "Complete • ${transfer.sizeFormatted}" : transfer.isFailed ? "Failed" : "${transfer.status.name} • ${transfer.progressFormatted}",
        style: TextStyle(color: transfer.isCompleted ? AppColors.primary : AppColors.textDim, fontSize: 12),
      ),
      trailing: transfer.isActive
          ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(value: transfer.progress, strokeWidth: 2, color: AppColors.accent))
          : null,
    );
  }
}