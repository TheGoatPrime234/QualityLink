import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:archive/archive_io.dart';
import 'package:web_socket_channel/web_socket_channel.dart'; // ✅ NEU

import '../config/server_config.dart';
import '../models/transfer_models.dart';

// =============================================================================
// DATALINK SERVICE v3 (Realtime WebSockets)
// =============================================================================

/// Zentraler Service für File Transfer Management
/// Verwaltet P2P und Relay-Transfers via WebSocket Push & HTTP Fallback
class DataLinkService {
  // Singleton Pattern
  static final DataLinkService _instance = DataLinkService._internal();
  factory DataLinkService() => _instance;
  DataLinkService._internal();

  // === STATE ===
  bool _isRunning = false;
  bool _isProcessing = false;
  String _clientId = "";
  String _myLocalIp = "0.0.0.0";
  String _downloadPath = "";
  
  HttpServer? _localServer;
  Timer? _syncTimer;
  
  // ✅ NEU: WebSocket State
  WebSocketChannel? _wsChannel;
  bool _isWsConnected = false;
  
  final List<Transfer> _transfers = [];
  final Map<String, String> _activeOperations = {}; // transferId -> localFilePath
  final Set<String> _processedTransferIds = {};
  
  // === CALLBACKS ===
  final List<Function(Transfer)> _transferListeners = [];
  final List<Function(String id, double progress, String? message)> _progressListeners = [];
  final List<Function(String message, bool isError)> _messageListeners = [];
  final List<Function(bool isProcessing)> _processingListeners = [];
  final List<Function()> _historyClearedListeners = [];
  
  // === GETTERS ===
  bool get isRunning => _isRunning;
  bool get isProcessing => _isProcessing;
  String get myLocalIp => _myLocalIp;
  bool get isRealtimeConnected => _isWsConnected; // ✅ Für UI Status
  
  List<Transfer> get allTransfers => List.unmodifiable(_transfers);
  List<Transfer> get activeTransfers => _transfers.where((t) => t.isActive).toList();
  List<Transfer> get completedTransfers => _transfers.where((t) => t.isCompleted).toList();
  int get localServerPort => _localServer?.port ?? 0;

  // =============================================================================
  // LIFECYCLE
  // =============================================================================

  Future<void> start({
    required String clientId,
    required String localIp,
  }) async {
    if (_isRunning) return;

    _clientId = clientId;
    _myLocalIp = localIp;

    print("🚀 Starting DataLinkService v3 (Realtime) for: $_clientId");

    // 1. Local P2P Server starten
    await _startLocalServer();

    // 2. ✅ WebSocket verbinden (Instant Push)
    _connectWebSocket();

    // 3. Fallback Sync Loop starten
    _startSyncLoop();

    _isRunning = true;
    print("✅ DataLinkService started");
  }

  Future<void> stop() async {
    if (!_isRunning) return;

    print("🛑 Stopping DataLinkService");

    _syncTimer?.cancel();
    _syncTimer = null;
    
    // ✅ WebSocket schließen
    _wsChannel?.sink.close();
    _wsChannel = null;
    _isWsConnected = false;

    await _localServer?.close();
    _localServer = null;

    _isRunning = false;
  }

  void pause() {
    if (!_isRunning) return;
    _syncTimer?.cancel();
    // WebSocket lassen wir offen, oder schließen ihn um Akku zu sparen (hier lassen wir ihn offen)
  }

  void resume() {
    if (!_isRunning) return;
    _startSyncLoop();
    if (!_isWsConnected) _connectWebSocket();
  }

  void setDownloadPath(String path) {
    _downloadPath = path;
    print("📂 Download path set: $path");
  }

  void addHistoryClearedListener(Function() listener) {
    _historyClearedListeners.add(listener);
  }

  void clearTransferHistory() { // ✅ NEU
    _transfers.clear();
    _activeOperations.clear();
    _processedTransferIds.clear();
    
    // UI benachrichtigen
    for (var listener in _historyClearedListeners) {
      try { listener(); } catch (_) {}
    }
    
    print("🧹 Local transfer history cleared");
  }

  // =============================================================================
  // WEBSOCKET LOGIC (🔥 NEU in v3)
  // =============================================================================

  void _connectWebSocket() {
    if (_wsChannel != null) return;

    try {
      // serverWsUrl muss in server_config.dart definiert sein (ws://...)
      final url = Uri.parse('$serverWsUrl/$_clientId');
      print("🔌 Connecting to WebSocket: $url");
      
      _wsChannel = WebSocketChannel.connect(url);
      _isWsConnected = true;

      _wsChannel!.stream.listen(
        (message) {
          _handleWebSocketMessage(message);
        },
        onError: (error) {
          print("⚠️ WebSocket Error: $error");
          _isWsConnected = false;
          _scheduleReconnect();
        },
        onDone: () {
          print("🔌 WebSocket Disconnected");
          _isWsConnected = false;
          _scheduleReconnect();
        },
      );
    } catch (e) {
      print("❌ WebSocket Init Failed: $e");
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_isRunning) return;
    _wsChannel = null;
    // Versuche Reconnect in 5 Sekunden
    Future.delayed(const Duration(seconds: 5), () {
      if (_isRunning && !_isWsConnected) {
        print("🔄 Reconnecting WebSocket...");
        _connectWebSocket();
      }
    });
  }

  void _handleWebSocketMessage(String message) {
    try {
      final data = json.decode(message);
      final event = data['event'];

      if (event == 'transfer_offer') {
        print("🚀 INSTANT OFFER RECEIVED via WebSocket!");
        final transferData = data['transfer'];
        _handleInstantOffer(transferData);
      } 
      // ✅ NEU: Remote Commands ausführen
      else if (event == 'execute_command') {
        _handleRemoteCommand(data);
      }
    } catch (e) {
      print("⚠️ WS Message Parse Error: $e");
    }
  }

  // ✅ NEUE METHODE: Führt Befehle vom Server aus
  Future<void> _handleRemoteCommand(Map<String, dynamic> data) async {
    final action = data['action'];
    final params = data['params'];
    final senderId = data['sender_id'];

    print("🤖 Executing remote command: $action");

    if (action == 'delete') {
      final path = params['path'];
      if (path != null) {
        try {
          final entity = File(path);
          if (await entity.exists()) {
            await entity.delete();
            print("🗑️ File deleted: $path");
          } else {
            final dir = Directory(path);
            if (await dir.exists()) {
              await dir.delete(recursive: true);
              print("🗑️ Folder deleted: $path");
            }
          }
          
          // Optional: Erfolgsmeldung zurück an Server senden (für Phase 3)
          _sendToWebSocket({
            "event": "command_result",
            "target_id": senderId,
            "status": "success",
            "action": "delete",
            "path": path
          });
          
        } catch (e) {
          print("❌ Delete failed: $e");
        }
      }
    }
  }
  
  // Hilfsmethode um WS Nachrichten zu senden (falls noch nicht vorhanden)
  void _sendToWebSocket(Map<String, dynamic> data) {
    if (_wsChannel != null && _isWsConnected) {
      _wsChannel!.sink.add(json.encode(data));
    }
  }

  void _handleInstantOffer(Map<String, dynamic> transferMeta) {
    try {
      // Transfer Objekt aus Metadaten bauen
      final transfer = Transfer.fromServerResponse({
        'meta': transferMeta,
        'status': 'OFFERED',
        'timestamp': DateTime.now().millisecondsSinceEpoch
      });

      if (!_transfers.any((t) => t.id == transfer.id)) {
        _transfers.add(transfer);
        _notifyTransferUpdate(transfer);
        
        // Sofort Download starten!
        if (_downloadPath.isNotEmpty) {
          _handleOfferedTransfer(transfer, _downloadPath);
        }
      }
    } catch (e) {
      print("❌ Failed to handle instant offer: $e");
    }
  }

  // =============================================================================
  // LISTENER MANAGEMENT
  // =============================================================================

  void addTransferListener(Function(Transfer) listener) => _transferListeners.add(listener);
  void addProgressListener(Function(String, double, String?) listener) => _progressListeners.add(listener);
  void addMessageListener(Function(String, bool) listener) => _messageListeners.add(listener);
  void addProcessingListener(Function(bool) listener) => _processingListeners.add(listener);

  void removeAllListeners() {
    _transferListeners.clear();
    _progressListeners.clear();
    _messageListeners.clear();
    _processingListeners.clear();
  }

  void _notifyTransferUpdate(Transfer transfer) {
    for (var l in _transferListeners) try { l(transfer); } catch (_) {}
  }
  void _notifyProgress(String id, double p, [String? m]) {
    for (var l in _progressListeners) try { l(id, p, m); } catch (_) {}
  }
  void _notifyMessage(String m, {bool isError = false}) {
    for (var l in _messageListeners) try { l(m, isError); } catch (_) {}
  }
  void _notifyProcessingState(bool isProcessing) {
    _isProcessing = isProcessing;
    for (var l in _processingListeners) try { l(isProcessing); } catch (_) {}
  }

  // =============================================================================
  // SYNC LOOP (FALLBACK)
  // =============================================================================

  void _startSyncLoop() {
    _syncTimer?.cancel();
    // ✅ Langsameres Intervall (10s), da WebSocket primär ist
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _syncTransfers();
      _monitorSenderTasks();
    });
  }

  Future<void> _syncTransfers() async {
    try {
      final response = await http.get(
        Uri.parse('$serverBaseUrl/transfer/check/$_clientId'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> transferList = data['transfers'] ?? [];
        
        for (var transferData in transferList) {
          final transfer = Transfer.fromServerResponse(transferData);
          final existingIndex = _transfers.indexWhere((t) => t.id == transfer.id);
          
          if (existingIndex != -1) {
            final oldTransfer = _transfers[existingIndex];
            if (oldTransfer.status != transfer.status) {
               _transfers[existingIndex] = transfer;
               _notifyTransferUpdate(transfer);
            }
            
            // Relay Ready Check (falls WS versagt hat)
            if (oldTransfer.status != TransferStatus.relayReady && 
                transfer.status == TransferStatus.relayReady &&
                !_processedTransferIds.contains(transfer.id) &&
                _downloadPath.isNotEmpty) {
              _handleRelayReadyTransfer(transfer, _downloadPath);
            }
          } else {
            // Neuer Transfer (WS verpasst?)
            _transfers.add(transfer);
            _notifyTransferUpdate(transfer);
            
            if (_downloadPath.isNotEmpty && !_processedTransferIds.contains(transfer.id)) {
              if (transfer.status == TransferStatus.offered) {
                print("⚠️ Polling picked up offer (WebSocket missed it?)");
                _handleOfferedTransfer(transfer, _downloadPath);
              }
            }
          }
        }
      }
    } catch (e) { /* silent */ }
  }

  // =============================================================================
  // LOCAL SERVER & P2P
  // =============================================================================

  Future<void> _startLocalServer() async {
    try {
      _localServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      print("🌐 Local P2P server started on port ${_localServer!.port}");
      _localServer!.listen((request) async => await _handleP2PRequest(request));
    } catch (e) {
      print("❌ Failed to start local server: $e");
    }
  }

  Future<void> _handleP2PRequest(HttpRequest request) async {
    final path = request.uri.path;
    if (path.startsWith("/download/")) {
      final filePath = Uri.decodeComponent(path.replaceAll("/download/", ""));
      final file = File(filePath);
      
      if (!file.existsSync()) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }

      try {
        final totalBytes = file.lengthSync();
        request.response.headers.add("Content-Type", "application/octet-stream");
        request.response.headers.add("Content-Length", totalBytes);
        request.response.headers.add("Content-Disposition", 'attachment; filename="${p.basename(filePath)}"');

        _notifyProcessingState(true);
        _notifyProgress(filePath, 0.0, "Sending via P2P...");

        int sentBytes = 0;
        await for (var chunk in file.openRead()) {
          request.response.add(chunk);
          sentBytes += chunk.length;
          if (sentBytes % (512 * 1024) == 0 || sentBytes == totalBytes) {
            _notifyProgress(filePath, sentBytes / totalBytes, "Sending...");
          }
        }
        await request.response.close();
        _notifyProgress(filePath, 1.0, "Complete!");
        _notifyProcessingState(false);
      } catch (e) {
        request.response.statusCode = 500;
        await request.response.close();
        _notifyProcessingState(false);
      }
    } else {
      request.response.statusCode = 404;
      await request.response.close();
    }
  }

  // =============================================================================
  // SEND OPERATIONS
  // =============================================================================

  Future<String> sendFile(File file, List<String> targetIds, {String? destinationPath}) async {
    if (targetIds.isEmpty) throw Exception("No targets selected");
    if (!file.existsSync()) throw Exception("File not found");

    final transferId = _generateTransferId();
    final fileName = p.basename(file.path);
    final fileSize = file.lengthSync();

    print("📤 Sending file: $fileName");

    for (var targetId in targetIds) {
      await _offerFile(
        filePath: file.path,
        targetId: targetId,
        transferId: transferId,
        destinationPath: destinationPath,
      );
    }
    _notifyMessage("✅ File offered: $fileName");
    return transferId;
  }

  Future<List<String>> sendFiles(List<File> files, List<String> targetIds, {String? destinationPath}) async {
    final ids = <String>[];
    for (var f in files) {
      try { ids.add(await sendFile(f, targetIds, destinationPath: destinationPath)); } catch (e) { print(e); }
    }
    return ids;
  }

  Future<String> sendFolder(Directory folder, List<String> targetIds, {Function(double, String)? onProgress}) async {
    if (!folder.existsSync()) throw Exception("Folder not found");
    
    _notifyProcessingState(true);
    try {
      final zipPath = await _zipFolderInIsolate(folder.path, onProgress: onProgress);
      final transferId = await sendFile(File(zipPath), targetIds);
      _activeOperations[transferId] = zipPath;
      return transferId;
    } finally {
      _notifyProcessingState(false);
    }
  }

  Future<void> _offerFile({
    required String filePath,
    required String targetId,
    required String transferId,
    String? destinationPath,
  }) async {
    final fileName = p.basename(filePath);
    final fileSize = File(filePath).lengthSync();
    String directLink = "http://$_myLocalIp:${_localServer!.port}/download/${Uri.encodeComponent(filePath)}";
    
    if (destinationPath != null) {
      directLink += "?save_path=${Uri.encodeComponent(destinationPath)}";
    }

    try {
      final response = await http.post(
        Uri.parse('$serverBaseUrl/transfer/offer'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "transfer_id": transferId,
          "sender_id": _clientId,
          "target_id": targetId,
          "file_name": fileName,
          "file_size": fileSize,
          "direct_link": directLink,
          if (destinationPath != null) "destination_path": destinationPath,
        }),
      );

      if (response.statusCode == 200) {
        _activeOperations[transferId] = filePath;
      }
    } catch (e) {
      print("❌ Failed to offer: $e");
    }
  }

  // =============================================================================
  // RECEIVE & DOWNLOAD LOGIC
  // =============================================================================

  Future<void> _handleOfferedTransfer(Transfer transfer, String downloadPath) async {
    _processedTransferIds.add(transfer.id);
    
    File targetFile;
    if (transfer.destinationPath != null && transfer.destinationPath!.isNotEmpty) {
      targetFile = File(p.join(transfer.destinationPath!, transfer.fileName));
    } else {
      targetFile = File(p.join(downloadPath, transfer.fileName));
    }
    
    _notifyMessage("📥 Incoming: ${transfer.fileName}");
    
    final p2pSuccess = await _tryP2PDownload(transfer, targetFile);
    
    if (p2pSuccess) {
      _notifyMessage("✨ P2P Success: ${transfer.fileName}");
      _updateTransferStatus(transfer, TransferStatus.completed);
      await _reportTransferEvent(transfer.id, "completed", "via P2P");
    } else {
      _notifyMessage("⚠️ P2P failed, requesting relay...");
      await _requestRelay(transfer.id);
      _processedTransferIds.remove(transfer.id);
    }
  }

  Future<void> _handleRelayReadyTransfer(Transfer transfer, String downloadPath) async {
    _processedTransferIds.add(transfer.id);
    final targetFile = File(p.join(downloadPath, transfer.fileName));
    
    _notifyMessage("☁️ Downloading from relay...");
    await _downloadFromRelay(transfer, targetFile);
    _updateTransferStatus(transfer, TransferStatus.completed);
  }

  Future<bool> _tryP2PDownload(Transfer transfer, File targetFile) async {
    if (transfer.directLink == null) return false;
    _notifyProcessingState(true);
    _notifyProgress(transfer.id, 0.0, "Downloading (P2P)...");

    try {
      final request = http.Request('GET', Uri.parse(transfer.directLink!));
      final response = await http.Client().send(request).timeout(const Duration(seconds: 120));

      if (response.statusCode != 200) throw Exception("HTTP ${response.statusCode}");

      final sink = targetFile.openWrite();
      int received = 0;
      final total = response.contentLength ?? transfer.fileSize;

      await for (var chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        _notifyProgress(transfer.id, received / total, "${_formatBytes(received)} / ${_formatBytes(total)}");
      }
      await sink.close();
      return true;
    } catch (e) {
      try { if (targetFile.existsSync()) await targetFile.delete(); } catch (_) {}
      return false;
    } finally {
      _notifyProcessingState(false);
    }
  }

  // =============================================================================
  // RELAY HELPERS
  // =============================================================================

  Future<void> _requestRelay(String transferId) async {
    try {
      await http.post(
        Uri.parse('$serverBaseUrl/transfer/request_relay'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({"transfer_id": transferId}),
      );
    } catch (e) { print(e); }
  }

  Future<void> _monitorSenderTasks() async {
    for (var transferId in _activeOperations.keys.toList()) {
      try {
        final response = await http.get(Uri.parse('$serverBaseUrl/transfer/status/$transferId'));
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          if (data['status'] == "RELAY_REQUESTED" && !_isProcessing) {
            final filePath = _activeOperations[transferId]!;
            await _uploadToRelay(filePath, transferId);
          }
        }
      } catch (e) {}
    }
  }

  Future<void> _uploadToRelay(String filePath, String transferId) async {
    _notifyProcessingState(true);
    _notifyProgress(transferId, 0.0, "Uploading to relay...");

    try {
      final file = File(filePath);
      final uri = Uri.parse('$serverBaseUrl/upload');
      final request = http.StreamedRequest('POST', uri);
      final boundary = 'dart-boundary-${DateTime.now().millisecondsSinceEpoch}';
      request.headers['Content-Type'] = 'multipart/form-data; boundary=$boundary';
      
      final transferIdField = '--$boundary\r\nContent-Disposition: form-data; name="transfer_id"\r\n\r\n$transferId\r\n';
      final fileHeader = '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="${p.basename(filePath)}"\r\nContent-Type: application/octet-stream\r\n\r\n';
      final endBoundary = '\r\n--$boundary--\r\n';
      
      final totalSize = utf8.encode(transferIdField + fileHeader + endBoundary).length + file.lengthSync();
      request.contentLength = totalSize;
      
      request.sink.add(utf8.encode(transferIdField));
      request.sink.add(utf8.encode(fileHeader));
      
      int sent = 0;
      await for (var chunk in file.openRead()) {
        request.sink.add(chunk);
        sent += chunk.length;
        if (sent % (256 * 1024) == 0) _notifyProgress(transferId, sent / totalSize, "Uploading...");
      }
      request.sink.add(utf8.encode(endBoundary));
      await request.sink.close();

      final response = await request.send();
      if (response.statusCode == 200) {
        _activeOperations.remove(transferId);
        _notifyMessage("☁️ Upload completed");
        await _reportTransferEvent(transferId, "completed", "Relay Upload");
      }
    } catch (e) {
      _notifyMessage("Upload failed: $e", isError: true);
    } finally {
      _notifyProcessingState(false);
    }
  }

  Future<void> _downloadFromRelay(Transfer transfer, File targetFile) async {
    _notifyProcessingState(true);
    _notifyProgress(transfer.id, 0.0, "Relay Download...");
    try {
      final response = await http.Client().send(http.Request('GET', Uri.parse('$serverBaseUrl/download/relay/${transfer.id}')));
      final sink = targetFile.openWrite();
      int received = 0;
      final total = response.contentLength ?? transfer.fileSize;
      
      await for (var chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        _notifyProgress(transfer.id, received / total, "Downloading...");
      }
      await sink.close();
      await _reportTransferEvent(transfer.id, "completed", "Relay Download");
      _notifyMessage("✅ Downloaded: ${transfer.fileName}");
    } catch (e) {
      _notifyMessage("Download error: $e", isError: true);
    } finally {
      _notifyProcessingState(false);
    }
  }

  // Für FileVault Downloads
  Future<void> startDirectDownload({
    required String fileName,
    required String url,
    required int fileSize,
    required String senderId,
  }) async {
    final transferId = _generateTransferId();
    final saveDir = Directory(_downloadPath.isNotEmpty ? _downloadPath : Directory.systemTemp.path);
    final targetFile = File(p.join(saveDir.path, fileName));

    final transfer = Transfer(
      id: transferId,
      fileName: fileName,
      fileSize: fileSize,
      senderId: senderId,
      targetIds: [_clientId],
      status: TransferStatus.downloading,
      mode: TransferMode.p2p,
      directLink: url,
    );

    _transfers.insert(0, transfer);
    _notifyTransferUpdate(transfer);
    
    final success = await _tryP2PDownload(transfer, targetFile);
    if (success) {
      _updateTransferStatus(transfer, TransferStatus.completed);
      _notifyMessage("✅ Download complete: $fileName");
    } else {
      _notifyMessage("❌ Download failed", isError: true);
    }
  }

  Future<void> _reportTransferEvent(String id, String event, String details) async {
    try {
      await http.post(Uri.parse('$serverBaseUrl/transfer/report'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({"transfer_id": id, "client_id": _clientId, "event": event, "details": details}));
    } catch (_) {}
  }

  void _updateTransferStatus(Transfer t, TransferStatus s) {
    final idx = _transfers.indexWhere((tr) => tr.id == t.id);
    if (idx != -1) {
      final updated = t.copyWith(status: s, completedAt: s == TransferStatus.completed ? DateTime.now() : null);
      _transfers[idx] = updated;
      _notifyTransferUpdate(updated);
    }
  }

  String _generateTransferId() => "${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}";
  String _formatBytes(int bytes) => bytes < 1024 ? "$bytes B" : "${(bytes / 1024 / 1024).toStringAsFixed(1)} MB";

  Future<String> _zipFolderInIsolate(String folderPath, {Function(double, String)? onProgress}) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_zipIsolateEntry, [receivePort.sendPort, folderPath]);
    String? resultPath;
    await for (final msg in receivePort) {
      if (msg is ZipProgress) {
        if (msg.error != null) throw Exception(msg.error);
        if (msg.resultPath != null) { resultPath = msg.resultPath; receivePort.close(); }
        else { onProgress?.call(msg.progress, msg.message); _notifyProgress("zip", msg.progress, msg.message); }
      }
    }
    return resultPath!;
  }
}

// =============================================================================
// HELPER CLASSES & ISOLATES
// =============================================================================

class ZipProgress {
  final double progress;
  final String message;
  final String? resultPath;
  final String? error;
  ZipProgress({this.progress = 0.0, this.message = "", this.resultPath, this.error});
}

void _zipIsolateEntry(List<dynamic> args) async {
  final SendPort sendPort = args[0];
  final String sourcePath = args[1];
  try {
    final sourceDir = Directory(sourcePath);
    final folderName = p.basename(sourcePath).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final zipPath = p.join(Directory.systemTemp.path, '${folderName}_${DateTime.now().millisecondsSinceEpoch}.zip');
    
    sendPort.send(ZipProgress(message: "Analyzing..."));
    int totalBytes = _calculateDirectorySize(sourceDir);
    var encoder = ZipFileEncoder();
    encoder.create(zipPath);
    
    int processed = 0;
    await _addDirectoryWithProgress(encoder, sourceDir, "", (bytes) {
      processed += bytes;
      sendPort.send(ZipProgress(progress: processed / (totalBytes == 0 ? 1 : totalBytes), message: "Zipping..."));
    });
    
    encoder.close();
    sendPort.send(ZipProgress(progress: 1.0, message: "Done", resultPath: zipPath));
  } catch (e) {
    sendPort.send(ZipProgress(error: e.toString()));
  }
}

int _calculateDirectorySize(Directory dir) {
  int size = 0;
  try {
    dir.listSync(recursive: false).forEach((e) {
      if (e is File) size += e.lengthSync();
      else if (e is Directory) size += _calculateDirectorySize(e);
    });
  } catch (_) {}
  return size;
}

Future<void> _addDirectoryWithProgress(ZipFileEncoder encoder, Directory dir, String relPath, Function(int) onAdd) async {
  try {
    dir.listSync(recursive: false).forEach((e) {
      final name = p.basename(e.path);
      if (name.startsWith('.') || name == "System Volume Information") return;
      if (e is File) {
        encoder.addFile(e, p.join(relPath, name));
        onAdd(e.lengthSync());
      } else if (e is Directory) {
        _addDirectoryWithProgress(encoder, e, p.join(relPath, name), onAdd);
      }
    });
  } catch (_) {}
}