import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../config/server_config.dart';
import '../widgets/futuristic_progress_bar.dart';
import '../services/overlay_foreground_service.dart';
import '../services/file_server_service.dart';
import '../services/heartbeat_service.dart'; // ✅ NEU

// =============================================================================
// HELPER: PROGRESS CLASS
// =============================================================================
class ZipProgress {
  final double progress;
  final String message;
  final String? resultPath;
  final String? error;
  ZipProgress({this.progress = 0.0, this.message = "", this.resultPath, this.error});
}

// =============================================================================
// BACKGROUND ISOLATE
// =============================================================================
void _zipIsolateEntry(List<dynamic> args) async {
  final SendPort sendPort = args[0];
  final String sourcePath = args[1];

  try {
    final sourceDir = Directory(sourcePath);
    final folderName = p.basename(sourcePath).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final tempDir = Directory.systemTemp;
    final zipPath = p.join(tempDir.path, '${folderName}_${DateTime.now().millisecondsSinceEpoch}.zip');

    sendPort.send(ZipProgress(message: "Analyzing folder structure..."));
    
    int totalBytes = 0;
    try {
      totalBytes = _calculateDirectorySize(sourceDir);
    } catch (e) {}
    if (totalBytes == 0) totalBytes = 1;

    var encoder = ZipFileEncoder();
    encoder.create(zipPath);

    int processedBytes = 0;
    await _addDirectoryWithProgress(encoder, sourceDir, "", (bytesAdded) {
      processedBytes += bytesAdded;
      sendPort.send(ZipProgress(
        progress: processedBytes / totalBytes,
        message: "Archiving: ${(processedBytes / 1024 / 1024).toStringAsFixed(1)} MB"
      ));
    });

    encoder.close();
    sendPort.send(ZipProgress(progress: 1.0, message: "Done!", resultPath: zipPath));
  } catch (e) {
    sendPort.send(ZipProgress(error: e.toString()));
  }
}

int _calculateDirectorySize(Directory dir) {
  int size = 0;
  try {
    final entities = dir.listSync(recursive: false, followLinks: false);
    for (var entity in entities) {
      if (entity is File) {
        size += entity.lengthSync();
      } else if (entity is Directory) {
        size += _calculateDirectorySize(entity);
      }
    }
  } catch (e) {}
  return size;
}

Future<void> _addDirectoryWithProgress(
    ZipFileEncoder encoder, Directory dir, String relPath, Function(int) onBytesAdded) async {
  try {
    final entities = dir.listSync(recursive: false, followLinks: false);
    for (var entity in entities) {
      final name = p.basename(entity.path);
      if (name.startsWith('.') || name.startsWith(r'$') || name == "System Volume Information") continue;

      if (entity is File) {
        try {
          final len = entity.lengthSync();
          await encoder.addFile(entity, p.join(relPath, name), 0);
          onBytesAdded(len);
        } catch (e) {
          print("⚠️ Skipping locked file: $name");
        }
      } else if (entity is Directory) {
        await _addDirectoryWithProgress(encoder, entity, p.join(relPath, name), onBytesAdded);
      }
    }
  } catch (e) {
    print("⚠️ Access denied: ${dir.path}");
  }
}

// =============================================================================
// STREAMING REQUEST
// =============================================================================
class ProgressMultipartRequest extends http.MultipartRequest {
  final void Function(int bytes, int totalBytes) onProgress;
  ProgressMultipartRequest(String method, Uri url, {required this.onProgress}) : super(method, url);

  @override
  http.ByteStream finalize() {
    final byteStream = super.finalize();
    final total = contentLength;
    int bytesWritten = 0;
    final transformer = StreamTransformer.fromHandlers(
      handleData: (List<int> data, EventSink<List<int>> sink) {
        bytesWritten += data.length;
        onProgress(bytesWritten, total);
        sink.add(data);
      },
    );
    return http.ByteStream(byteStream.transform(transformer));
  }
}

// =============================================================================
// SCREEN
// =============================================================================
class DataLinkScreen extends StatefulWidget {
  final String clientId;
  final String deviceName;
  const DataLinkScreen({super.key, required this.clientId, required this.deviceName});

  @override
  State<DataLinkScreen> createState() => _DataLinkScreenState();
}

class _DataLinkScreenState extends State<DataLinkScreen> with WidgetsBindingObserver {
  // ✅ Heartbeat Service
  final HeartbeatService _heartbeatService = HeartbeatService();
  
  List<dynamic> _activePeers = [];
  List<dynamic> _transfers = [];
  final Set<String> _selectedTargetIds = {};
  
  HttpServer? _localServer;
  String _myLocalIp = "0.0.0.0";
  
  bool _isConnected = false;
  bool _isProcessing = false;
  String _processingStatus = "";
  double _progressValue = 0.0;
  ProgressBarMode _progressMode = ProgressBarMode.zipping;
  String? _progressSubtitle;
  Timer? _syncTimer;
  
  Set<String> _processedTransfers = {};
  final Map<String, String> _activeOperations = {};
  final Map<String, String> _completedTransfers = {};
  
  String _selectedPath = "DEFAULT";
  String? _systemDownloadPath;
  List<String> _customPaths = [];
  bool _serviceStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSystem();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _localServer?.close();
    OverlayForegroundService.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused) {
      if (_isProcessing && Platform.isAndroid) {
        bool permission = await FlutterOverlayWindow.isPermissionGranted();
        if (!permission) {
          bool? granted = await FlutterOverlayWindow.requestPermission();
          if (granted != true) return;
        }
        await _ensureServiceStarted();
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

  Future<void> _initSystem() async {
    await _locateSystemDownloadFolder();
    await _loadPersistent();
    await _startLocalServer();
    
    // ✅ Heartbeat Service Setup
    _setupHeartbeatService();
    
    // ✅ Sync-Loop nur für Transfers/Tasks
    _startSyncLoop();
    
    if (Platform.isAndroid) {
      await Permission.notification.request();
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
  }

  // ✅ NEU: Heartbeat Service Setup
  void _setupHeartbeatService() {
    // Connection Status Updates
    _heartbeatService.addConnectionListener((isConnected) {
      if (mounted) {
        setState(() {
          _isConnected = isConnected;
        });
        print("🔄 DataLink: Connection status updated: $isConnected");
      }
    });

    // Peer List Updates
    _heartbeatService.addPeerListener((peers) {
      if (mounted) {
        setState(() {
          _activePeers = peers;
        });
        print("👥 DataLink: Peers updated: ${peers.length}");
      }
    });

    // Error Handling
    _heartbeatService.addErrorListener((error) {
      _showSnack("Connection Error: $error", isError: true);
    });
    
    // ✅ WICHTIG: Initial Status vom Service holen
    setState(() {
      _isConnected = _heartbeatService.isConnected;
    });
    print("📡 DataLink: Initial connection status: $_isConnected");
  }

  Future<void> _ensureServiceStarted({bool showNotification = false}) async {
    if (!_serviceStarted && Platform.isAndroid) {
      try {
        await OverlayForegroundService.startWithOverlay(
          status: _processingStatus,
          progress: _progressValue,
          mode: _progressMode.name,
        );
        _serviceStarted = true;
      } catch (e) {
        print("❌ Service start failed: $e");
      }
    } else if (showNotification && _serviceStarted && Platform.isAndroid) {
      await OverlayForegroundService.updateOverlay(
        status: _processingStatus,
        progress: _progressValue,
        mode: _progressMode.name,
      );
    }
  }

  Future<void> _locateSystemDownloadFolder() async {
    if (Platform.isAndroid) await Permission.storage.request();
    _systemDownloadPath = Platform.isAndroid 
        ? "/storage/emulated/0/Download" 
        : (await getDownloadsDirectory())?.path;
    _systemDownloadPath ??= (await getApplicationDocumentsDirectory()).path;
  }

  Future<void> _loadPersistent() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _customPaths = p.getStringList('custom_paths') ?? [];
      String? l = p.getString('selected_path');
      if (l != null) _selectedPath = l;
    });
  }

  Future<void> _savePersistent() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('custom_paths', _customPaths);
    await p.setString('selected_path', _selectedPath);
  }

// FORTSETZUNG IN TEIL 2...

// FORTSETZUNG VON TEIL 1...

  Future<void> _startLocalServer() async {
    try {
      _myLocalIp = "0.0.0.0";
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.address.startsWith("127.")) {
            if (addr.address.startsWith("192.168.")) {
              _myLocalIp = addr.address;
              break;
            } else if (addr.address.startsWith("10.") || addr.address.startsWith("172.")) {
              if (_myLocalIp == "0.0.0.0") _myLocalIp = addr.address;
            }
          }
        }
        if (_myLocalIp.startsWith("192.168.")) break;
      }
      
      if (_myLocalIp == "0.0.0.0") {
        try {
          final s = await Socket.connect(serverIp, int.parse(serverPort));
          _myLocalIp = s.address.address;
          s.destroy();
        } catch (_) {
          _myLocalIp = "127.0.0.1";
        }
      }

      _localServer?.close();
      _localServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);

      _localServer!.listen((request) async {
        final path = request.uri.path;
        if (path.startsWith("/download/")) {
          final filePath = Uri.decodeComponent(path.replaceAll("/download/", ""));
          final file = File(filePath);
          if (file.existsSync()) {
            if (mounted) {
              setState(() {
                _isProcessing = true;
                _progressMode = ProgressBarMode.p2p;
                _processingStatus = "Sending via P2P...";
                _progressValue = 0.0;
              });
            }

            request.response.headers.add("Connection", "keep-alive");
            request.response.headers.add("Content-Type", "application/octet-stream");
            request.response.headers.add("Content-Length", file.lengthSync());

            try {
              int sent = 0;
              await for (var chunk in file.openRead()) {
                request.response.add(chunk);
                sent += chunk.length;
                if (mounted && sent % (1024 * 1024) == 0) {
                  setState(() {
                    _progressValue = sent / file.lengthSync();
                    _progressSubtitle = "${(sent / 1024 / 1024).toStringAsFixed(1)} MB sent";
                  });
                }
              }
              await request.response.close();
            } catch (e) {
              print("P2P Error: $e");
            } finally {
              if (mounted) setState(() => _isProcessing = false);
            }
          } else {
            request.response.statusCode = 404;
            request.response.close();
          }
        } else {
          request.response.close();
        }
      });
    } catch (e) {
      print("Server Err: $e");
    }
  }

  void _startSyncLoop() {
    _syncTimer = Timer.periodic(const Duration(seconds: 2), (t) {
      _syncTransfers();
      _monitorSenderTasks();
    });
  }
  
  Future<void> _offerFile(String filePath, String targetId) async {
    final transferId = "${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999)}";
    final fileName = p.basename(filePath);
    final fileSize = File(filePath).lengthSync();
    final directLink = "http://$_myLocalIp:${_localServer!.port}/download/${Uri.encodeComponent(filePath)}";
    try {
      await http.post(
        Uri.parse('$serverBaseUrl/transfer/offer'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "transfer_id": transferId,
          "sender_id": widget.clientId,
          "target_id": targetId,
          "file_name": fileName,
          "file_size": fileSize,
          "direct_link": directLink
        }),
      );
      _activeOperations[transferId] = filePath;
      _showSnack("✅ Offer sent for $fileName");
    } catch (e) {
      _showSnack("Error: $e", isError: true);
    }
  }

  Future<void> _pickAndSendFolder() async {
    if (_selectedTargetIds.isEmpty) {
      _showSnack("Select a target first", isError: true);
      return;
    }

    String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;

    setState(() {
      _isProcessing = true;
      _processingStatus = "Compressing folder...";
      _progressMode = ProgressBarMode.zipping;
      _progressValue = 0.0;
    });

    await _ensureServiceStarted(showNotification: false);

    final receivePort = ReceivePort();

    try {
      await Isolate.spawn(_zipIsolateEntry, [receivePort.sendPort, dir]);

      await for (final message in receivePort) {
        if (message is ZipProgress) {
          if (message.error != null) throw Exception(message.error);

          if (message.resultPath != null) {
            final zipPath = message.resultPath!;
            receivePort.close();

            setState(() {
              _processingStatus = "Compression complete!";
              _progressValue = 1.0;
            });

            await OverlayForegroundService.showCompletionNotification("📦 Folder compressed!");

            for (var t in _selectedTargetIds) _offerFile(zipPath, t);
            break;
          } else {
            setState(() {
              _progressValue = message.progress;
              _progressSubtitle = message.message;
            });
          }
        }
      }
    } catch (e) {
      _showSnack("Zip Error: $e", isError: true);
    } finally {
      receivePort.close();
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _monitorSenderTasks() async {
    for (var transferId in _activeOperations.keys.toList()) {
      try {
        final response = await http.get(Uri.parse('$serverBaseUrl/transfer/status/$transferId'));
        if (json.decode(response.body)['status'] == "RELAY_REQUESTED") {
          final filePath = _activeOperations[transferId]!;
          if (!_isProcessing) _uploadToRelay(filePath, transferId);
        }
      } catch (e) {}
    }
  }

  Future<void> _uploadToRelay(String path, String transferId) async {
    setState(() {
      _isProcessing = true;
      _processingStatus = "Uploading to Cloud...";
      _progressMode = ProgressBarMode.relay;
      _progressValue = 0.0;
    });

    await _ensureServiceStarted(showNotification: false);

    try {
      final request = ProgressMultipartRequest(
        'POST',
        Uri.parse('$serverBaseUrl/upload'),
        onProgress: (bytes, total) {
          if (mounted) {
            setState(() {
              _progressValue = bytes / total;
              _progressSubtitle = "${(bytes / 1024 / 1024).toStringAsFixed(1)} MB sent";
            });
          }
        },
      );

      request.fields['transfer_id'] = transferId;
      request.files.add(await http.MultipartFile.fromPath('file', path));
      final res = await request.send().timeout(const Duration(minutes: 60));

      if (res.statusCode == 200) {
        _activeOperations.remove(transferId);
        await _reportTransferEvent(transferId, "completed", "Upload via Relay");
        await OverlayForegroundService.showCompletionNotification("☁️ Upload completed!");
        _showSnack("✅ Upload Done");
      }
    } catch (e) {
      await _reportTransferEvent(transferId, "failed", "P2P connection error");
      _showSnack("Upload Fail: $e", isError: true);
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _pickAndSendFiles() async {
    if (_selectedTargetIds.isEmpty) {
      _showSnack("No target selected", isError: true);
      return;
    }
    FilePickerResult? res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res != null) {
      for (var f in res.files) {
        if (f.path != null) {
          for (var t in _selectedTargetIds) {
            _offerFile(f.path!, t);
          }
        }
      }
      _showSnack("✅ Files Offered");
    }
  }

  Future<void> _syncTransfers() async {
    if (!_isConnected) return;
    try {
      final response = await http.get(Uri.parse('$serverBaseUrl/transfer/check/${widget.clientId}'));
      if (response.statusCode == 200) {
        final List<dynamic> list = json.decode(response.body)['transfers'];
        if (mounted) setState(() => _transfers = list);
        String saveDir = _selectedPath == "DEFAULT" ? (_systemDownloadPath ?? "") : _selectedPath;
        if (saveDir.isEmpty) return;

        for (var t in list) {
          final tId = t['meta']['transfer_id'];
          final status = t['status'];
          if (_processedTransfers.contains(tId)) continue;

          if (status == "OFFERED") {
            _processedTransfers.add(tId);
            
            await OverlayForegroundService.showCompletionNotification(
              "📥 Incoming: ${t['meta']['file_name']}"
            );
            
            bool p2pSuccess = await _tryP2PDownload(
                t['meta']['direct_link'], File('$saveDir/${t['meta']['file_name']}'));
            if (p2pSuccess) {
              _showSnack("✨ Direct P2P: ${t['meta']['file_name']}");
              setState(() => _completedTransfers[tId] = "P2P");
            } else {
              _showSnack("⚠️ P2P Fail -> Relay");
              await http.post(
                Uri.parse('$serverBaseUrl/transfer/request_relay'),
                headers: {"Content-Type": "application/json"},
                body: json.encode({"transfer_id": tId}),
              );
              _processedTransfers.remove(tId);
            }
          } else if (status == "RELAY_READY") {
            _processedTransfers.add(tId);
            _showSnack("☁️ Cloud Download...");
            await _downloadFromRelay(tId, File('$saveDir/${t['meta']['file_name']}'));
            setState(() => _completedTransfers[tId] = "RELAY");
          }
        }
      }
    } catch (e) {}
  }

  Future<bool> _tryP2PDownload(String url, File target) async {
    try {
      if (mounted) {
        setState(() {
          _isProcessing = true;
          _processingStatus = "Downloading (P2P)...";
          _progressMode = ProgressBarMode.p2p;
          _progressValue = 0.0;
        });
      }

      await _ensureServiceStarted(showNotification: false);

      final request = http.Request('GET', Uri.parse(url));
      final response = await http.Client().send(request).timeout(const Duration(seconds: 120));

      if (response.statusCode == 200) {
        final sink = target.openWrite();
        int rx = 0;
        int? tot = response.contentLength;

        await for (var c in response.stream) {
          sink.add(c);
          rx += c.length;

          if (mounted && tot != null) {
            setState(() {
              _progressValue = rx / tot!;
              _progressSubtitle = "${(rx / 1024 / 1024).toStringAsFixed(1)} MB";
            });
          }
        }

        await sink.close();
        
        final transferId = _transfers.firstWhere(
          (t) => t['meta']['direct_link'] == url,
          orElse: () => {'meta': {'transfer_id': 'unknown'}}
        )['meta']['transfer_id'];
        await _reportTransferEvent(transferId, "completed", "via P2P");
        
        await OverlayForegroundService.showCompletionNotification(
          "✅ Downloaded: ${p.basename(target.path)}"
        );
        return true;
      }
    } catch (e) {
      print("P2P Fail: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
    return false;
  }

  Future<void> _downloadFromRelay(String tid, File target) async {
    try {
      if (mounted) {
        setState(() {
          _isProcessing = true;
          _processingStatus = "Downloading (Relay)...";
          _progressMode = ProgressBarMode.relay;
          _progressValue = 0.0;
        });
      }

      await _ensureServiceStarted(showNotification: false);

      final client = http.Client();
      final response = await client.send(http.Request('GET', Uri.parse('$serverBaseUrl/download/relay/$tid')));

      if (response.statusCode == 200) {
        final sink = target.openWrite();
        int rx = 0;
        int? tot = response.contentLength;

        await for (var c in response.stream) {
          sink.add(c);
          rx += c.length;

          if (mounted && tot != null) {
            setState(() {
              _progressValue = rx / tot!;
              _progressSubtitle = "${(rx / 1024 / 1024).toStringAsFixed(1)} MB";
            });
          }
        }

        await sink.close();
        await _reportTransferEvent(tid, "completed", "via Relay");
        await OverlayForegroundService.showCompletionNotification(
          "✅ Downloaded: ${p.basename(target.path)}"
        );
      }
    } catch (e) {
      _showSnack("DL Error: $e", isError: true);
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // FORTSETZUNG IN TEIL 3...
// FORTSETZUNG VON TEIL 2...

  Future<void> _addCustomPath() async {
    String? d = await FilePicker.platform.getDirectoryPath();
    if (d != null && !_customPaths.contains(d)) {
      setState(() {
        _customPaths.add(d);
        _selectedPath = d;
      });
      _savePersistent();
    }
  }

  Future<void> _removeCustomPath(String p) async {
    setState(() {
      _customPaths.remove(p);
      if (_selectedPath == p) _selectedPath = "DEFAULT";
    });
    _savePersistent();
  }

  void _showSnack(String m, {bool isError = false}) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(m),
          backgroundColor: isError ? Colors.red : const Color(0xFF00FF41).withValues(alpha: 0.3),
        ),
      );
    }
  }
  
  Future<void> _reportTransferEvent(String transferId, String event, String details) async {
    try {
      await http.post(
        Uri.parse('$serverBaseUrl/transfer/report'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "transfer_id": transferId,
          "client_id": widget.clientId,
          "event": event,
          "details": details,
        }),
      );
    } catch (e) {
      print("Report Error: $e");
    }
  }

  bool _isInSameNetwork(String ip) =>
      (_myLocalIp.startsWith("192.168.") && ip.startsWith("192.168.")) ||
      (_myLocalIp.startsWith("10.") && ip.startsWith("10."));

  @override
  Widget build(BuildContext context) {
    final sameLanPeers = _activePeers.where((p) => _isInSameNetwork(p['ip'])).toList();
    final otherPeers = _activePeers.where((p) => !_isInSameNetwork(p['ip'])).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text("QUALITYLINK HYBRID"),
        backgroundColor: Colors.transparent,
        actions: [
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
          )
        ],
      ),
      body: Column(
        children: [
          if (_isProcessing)
            FuturisticProgressBar(
              progress: _progressValue,
              label: _processingStatus,
              mode: _progressMode,
              subtitle: _progressSubtitle,
            ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    color: const Color(0xFF0F0F0F),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("ID: ${widget.clientId}"),
                        Text("P2P IP: $_myLocalIp", style: const TextStyle(color: Colors.grey, fontSize: 10)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildPathSelector(),
                  const Divider(),
                  if (sameLanPeers.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text("SAME NETWORK (P2P)",
                          style: TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold)),
                    ),
                    _buildPeerList(sameLanPeers),
                  ],
                  if (otherPeers.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text("ONLINE (RELAY ONLY)",
                          style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                    ),
                    _buildPeerList(otherPeers),
                  ],
                  if (_activePeers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text("No devices detected...", style: TextStyle(color: Colors.grey))),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _pickAndSendFiles,
                            icon: const Icon(Icons.file_copy),
                            label: const Text("FILES"),
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF222222)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _pickAndSendFolder,
                            icon: const Icon(Icons.folder),
                            label: const Text("FOLDER"),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFF0055).withValues(alpha: 0.2)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text("ACTIVITY LOG",
                        style: TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold)),
                  ),
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _transfers.length,
                    itemBuilder: (context, i) {
                      final t = _transfers[_transfers.length - 1 - i];
                      final isComplete = _completedTransfers.containsKey(t['meta']['transfer_id']);
                      return ListTile(
                        leading: Icon(
                          isComplete ? Icons.check_circle : Icons.sync,
                          color: isComplete ? const Color(0xFF00FF41) : Colors.white,
                        ),
                        title: Text(t['meta']['file_name']),
                        subtitle: Text(
                          isComplete ? "Complete" : t['status'],
                          style: TextStyle(color: isComplete ? const Color(0xFF00FF41) : Colors.grey),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
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
          const Text("DOWNLOAD LOCATION",
              style: TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          _buildPathOption("DEFAULT", "System Downloads", _systemDownloadPath ?? ""),
          ..._customPaths.map((p) =>
              _buildPathOption(p, p.split(Platform.pathSeparator).last, p, isCustom: true)),
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

  Widget _buildPathOption(String v, String l, String s, {bool isCustom = false}) {
    final sel = _selectedPath == v;
    return GestureDetector(
      onTap: () async {
        setState(() => _selectedPath = v);
        await _savePersistent();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFF00FF41).withValues(alpha: 0.1) : const Color(0xFF151515),
          border: Border.all(color: sel ? const Color(0xFF00FF41) : Colors.grey.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(
              sel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: sel ? const Color(0xFF00FF41) : Colors.grey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l,
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: sel ? const Color(0xFF00FF41) : Colors.white)),
                  Text(s, style: const TextStyle(color: Colors.grey, fontSize: 10)),
                ],
              ),
            ),
            if (isCustom)
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red, size: 16),
                onPressed: () => _removeCustomPath(v),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeerList(List<dynamic> p) {
    return SizedBox(
      height: 100,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: p.length,
        itemBuilder: (c, i) {
          final peer = p[i];
          final sel = _selectedTargetIds.contains(peer['id']);
          return GestureDetector(
            onTap: () => setState(() {
              if (sel) {
                _selectedTargetIds.remove(peer['id']);
              } else {
                _selectedTargetIds.add(peer['id']);
              }
            }),
            child: Container(
              width: 90,
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: sel ? const Color(0xFF00FF41).withValues(alpha: 0.2) : const Color(0xFF111111),
                border: Border.all(color: sel ? const Color(0xFF00FF41) : Colors.grey),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.computer, color: sel ? Colors.white : Colors.grey),
                  Text(peer['name'], style: const TextStyle(fontSize: 10)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}