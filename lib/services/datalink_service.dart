import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:archive/archive_io.dart';

import '../config/server_config.dart';
import '../models/transfer_models.dart';

// =============================================================================
// DATALINK SERVICE - TEIL 1: CORE & STATE MANAGEMENT
// =============================================================================

/// Zentraler Service für File Transfer Management
/// Verwaltet P2P und Relay-Transfers, unabhängig von UI
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
  String _downloadPath = "";  // ✅ NEU: Für event-driven downloads
  
  HttpServer? _localServer;
  Timer? _syncTimer;
  
  final List<Transfer> _transfers = [];
  final Map<String, String> _activeOperations = {}; // transferId -> localFilePath
  final Set<String> _processedTransferIds = {};
  
  // === CALLBACKS ===
  final List<Function(Transfer)> _transferListeners = [];
  final List<Function(String id, double progress, String? message)> _progressListeners = [];
  final List<Function(String message, bool isError)> _messageListeners = [];
  final List<Function(bool isProcessing)> _processingListeners = [];
  
  // === GETTERS ===
  bool get isRunning => _isRunning;
  bool get isProcessing => _isProcessing;
  String get myLocalIp => _myLocalIp;
  List<Transfer> get allTransfers => List.unmodifiable(_transfers);
  List<Transfer> get activeTransfers => 
      _transfers.where((t) => t.isActive).toList();
  List<Transfer> get completedTransfers => 
      _transfers.where((t) => t.isCompleted).toList();

  // =============================================================================
  // LIFECYCLE
  // =============================================================================

  /// Startet den DataLink Service
  Future<void> start({
    required String clientId,
    required String localIp,
  }) async {
    if (_isRunning) {
      print("⚠️ DataLinkService already running");
      return;
    }

    _clientId = clientId;
    _myLocalIp = localIp;

    print("🚀 Starting DataLinkService for client: $_clientId");

    // Local P2P Server starten
    await _startLocalServer();

    // Sync Loop starten
    _startSyncLoop();

    _isRunning = true;
    print("✅ DataLinkService started successfully");
  }

  /// Stoppt den Service
  Future<void> stop() async {
    if (!_isRunning) return;

    print("🛑 Stopping DataLinkService");

    _syncTimer?.cancel();
    _syncTimer = null;

    await _localServer?.close();
    _localServer = null;

    _isRunning = false;
    print("✅ DataLinkService stopped");
  }

  /// Pausiert den Service (z.B. bei App-Minimize)
  void pause() {
    if (!_isRunning) return;
    _syncTimer?.cancel();
    print("⏸️ DataLinkService paused");
  }

  /// Setzt den Service fort
  void resume() {
    if (!_isRunning) return;
    _startSyncLoop();
    print("▶️ DataLinkService resumed");
  }

  /// Setzt den Download-Pfad für automatische Downloads
  void setDownloadPath(String path) {
    _downloadPath = path;
    print("📂 Download path set: $path");
  }

  // =============================================================================
  // LISTENER MANAGEMENT
  // =============================================================================

  void addTransferListener(Function(Transfer) listener) {
    _transferListeners.add(listener);
  }

  void addProgressListener(Function(String id, double progress, String? message) listener) {
    _progressListeners.add(listener);
  }

  void addMessageListener(Function(String message, bool isError) listener) {
    _messageListeners.add(listener);
  }

  void addProcessingListener(Function(bool isProcessing) listener) {
    _processingListeners.add(listener);
  }

  void removeAllListeners() {
    _transferListeners.clear();
    _progressListeners.clear();
    _messageListeners.clear();
    _processingListeners.clear();
  }

  // === PRIVATE NOTIFIERS ===

  void _notifyTransferUpdate(Transfer transfer) {
    for (var listener in _transferListeners) {
      try {
        listener(transfer);
      } catch (e) {
        print("⚠️ Error in transfer listener: $e");
      }
    }
  }

  void _notifyProgress(String id, double progress, [String? message]) {
    for (var listener in _progressListeners) {
      try {
        listener(id, progress, message);
      } catch (e) {
        print("⚠️ Error in progress listener: $e");
      }
    }
  }

  void _notifyMessage(String message, {bool isError = false}) {
    for (var listener in _messageListeners) {
      try {
        listener(message, isError);
      } catch (e) {
        print("⚠️ Error in message listener: $e");
      }
    }
  }

  void _notifyProcessingState(bool isProcessing) {
    _isProcessing = isProcessing;
    for (var listener in _processingListeners) {
      try {
        listener(isProcessing);
      } catch (e) {
        print("⚠️ Error in processing listener: $e");
      }
    }
  }

  // =============================================================================
  // LOCAL P2P SERVER
  // =============================================================================

  Future<void> _startLocalServer() async {
    try {
      // Server auf zufälligem Port starten
      _localServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      
      print("🌐 Local P2P server started on port ${_localServer!.port}");

      _localServer!.listen((request) async {
        await _handleP2PRequest(request);
      });
    } catch (e) {
      print("❌ Failed to start local server: $e");
      _notifyMessage("Failed to start P2P server: $e", isError: true);
    }
  }

  Future<void> _handleP2PRequest(HttpRequest request) async {
    final path = request.uri.path;
    
    // Download Request: /download/{encoded_file_path}
    if (path.startsWith("/download/")) {
      final filePath = Uri.decodeComponent(path.replaceAll("/download/", ""));
      final file = File(filePath);
      
      if (!file.existsSync()) {
        request.response.statusCode = 404;
        request.response.write("File not found");
        await request.response.close();
        return;
      }

      try {
        // Headers setzen
        request.response.headers.add("Connection", "keep-alive");
        request.response.headers.add("Content-Type", "application/octet-stream");
        request.response.headers.add("Content-Length", file.lengthSync());
        request.response.headers.add(
          "Content-Disposition",
          'attachment; filename="${p.basename(filePath)}"',
        );

        // File streamen
        int sentBytes = 0;
        final totalBytes = file.lengthSync();
        
        await for (var chunk in file.openRead()) {
          request.response.add(chunk);
          sentBytes += chunk.length;
          
          // Progress alle 1 MB updaten
          if (sentBytes % (1024 * 1024) == 0 || sentBytes == totalBytes) {
            _notifyProgress(
              filePath,
              sentBytes / totalBytes,
              "${(sentBytes / 1024 / 1024).toStringAsFixed(1)} MB sent",
            );
          }
        }

        await request.response.close();
        print("✅ P2P upload completed: ${p.basename(filePath)}");
        
      } catch (e) {
        print("❌ P2P upload error: $e");
        request.response.statusCode = 500;
        await request.response.close();
      }
    } else {
      request.response.statusCode = 404;
      await request.response.close();
    }
  }

  // =============================================================================
  // SYNC LOOP
  // =============================================================================

  void _startSyncLoop() {
    _syncTimer?.cancel();
    // ✅ Intervall auf 5s erhöht da Downloads jetzt event-driven sind
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
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
        
        // Update local transfer list
        for (var transferData in transferList) {
          final transfer = Transfer.fromServerResponse(transferData);
          
          // Check ob das ein NEUER Transfer ist
          final existingIndex = _transfers.indexWhere((t) => t.id == transfer.id);
          final isNew = existingIndex == -1;
          
          if (existingIndex != -1) {
            // Bestehender Transfer - prüfe auf Status-Änderung
            final oldTransfer = _transfers[existingIndex];
_transfers[existingIndex] = transfer;
            
            // ✅ Bei Status-Änderung zu RELAY_READY → Download starten
            if (oldTransfer.status != TransferStatus.relayReady && 
                transfer.status == TransferStatus.relayReady &&
                !_processedTransferIds.contains(transfer.id) &&
                _downloadPath.isNotEmpty) {
              print("🚀 Status changed to relay ready - downloading immediately!");
              _handleRelayReadyTransfer(transfer, _downloadPath);
            }
          } else {
            // Neuer Transfer
            _transfers.add(transfer);
            _notifyTransferUpdate(transfer);
            
            // ✅ SOFORT Download starten wenn Path gesetzt ist!
            if (_downloadPath.isNotEmpty && !_processedTransferIds.contains(transfer.id)) {
              if (transfer.status == TransferStatus.offered) {
                print("🚀 New transfer detected - starting download immediately!");
                _handleOfferedTransfer(transfer, _downloadPath);
              } else if (transfer.status == TransferStatus.relayReady) {
                print("🚀 Relay ready transfer detected - downloading immediately!");
                _handleRelayReadyTransfer(transfer, _downloadPath);
              }
            }
          }
        }
      }
    } catch (e) {
      print("⚠️ Sync transfers error: $e");
    }
  }

  Future<void> _monitorSenderTasks() async {
    for (var transferId in _activeOperations.keys.toList()) {
      try {
        final response = await http.get(
          Uri.parse('$serverBaseUrl/transfer/status/$transferId'),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final status = data['status'] as String;
          
          // Wenn Relay angefordert wurde, uploade zum Server
          if (status == "RELAY_REQUESTED" && !_isProcessing) {
            final filePath = _activeOperations[transferId]!;
            await _uploadToRelay(filePath, transferId);
          }
        }
      } catch (e) {
        // Ignore errors in monitoring
      }
    }
  }

  // =============================================================================
  // SERVER COMMUNICATION
  // =============================================================================

  Future<void> _reportTransferEvent(
    String transferId,
    String event,
    String details,
  ) async {
    try {
      await http.post(
        Uri.parse('$serverBaseUrl/transfer/report'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "transfer_id": transferId,
          "client_id": _clientId,
          "event": event,
          "details": details,
        }),
      );
    } catch (e) {
      print("⚠️ Failed to report transfer event: $e");
    }
  }

  // =============================================================================
  // UTILITY
  // =============================================================================

  int get localServerPort => _localServer?.port ?? 0;

  Transfer? getTransfer(String transferId) {
    try {
      return _transfers.firstWhere((t) => t.id == transferId);
    } catch (e) {
      return null;
    }
  }
  // =============================================================================
// DATALINK SERVICE - TEIL 2: TRANSFER OPERATIONS
// =============================================================================
// Diese Datei ist die Fortsetzung von datalink_service_part1.dart
// Füge diese Methoden in die DataLinkService Klasse ein

// WICHTIG: Dies sind Extension-Methoden für die DataLinkService Klasse
// In der finalen Version müssen diese in die Klasse integriert werden

// =============================================================================
// SEND OPERATIONS
// =============================================================================

/// Sendet eine einzelne Datei an Ziel-Geräte
  Future<String> sendFile(File file, List<String> targetIds) async {
    if (targetIds.isEmpty) {
      _notifyMessage("No targets selected", isError: true);
      throw Exception("No targets selected");
    }

    if (!file.existsSync()) {
      _notifyMessage("File not found", isError: true);
      throw Exception("File not found: ${file.path}");
    }

    final transferId = _generateTransferId();
    final fileName = p.basename(file.path);
    final fileSize = file.lengthSync();

    print("📤 Sending file: $fileName (${_formatBytes(fileSize)})");

    // Offer an alle Targets senden
    for (var targetId in targetIds) {
      await _offerFile(
        filePath: file.path,
        targetId: targetId,
        transferId: transferId,
      );
    }

    _notifyMessage("✅ File offered: $fileName");
    return transferId;
  }

  /// Sendet mehrere Dateien
  Future<List<String>> sendFiles(List<File> files, List<String> targetIds) async {
    final transferIds = <String>[];
    
    for (var file in files) {
      try {
        final id = await sendFile(file, targetIds);
        transferIds.add(id);
      } catch (e) {
        print("⚠️ Failed to send ${file.path}: $e");
      }
    }
    
    return transferIds;
  }

  /// Komprimiert einen Ordner und sendet ihn
  Future<String> sendFolder(
    Directory folder,
    List<String> targetIds, {
    Function(double progress, String message)? onProgress,
  }) async {
    if (targetIds.isEmpty) {
      _notifyMessage("No targets selected", isError: true);
      throw Exception("No targets selected");
    }

    if (!folder.existsSync()) {
      _notifyMessage("Folder not found", isError: true);
      throw Exception("Folder not found: ${folder.path}");
    }

    _notifyProcessingState(true);
    _notifyProgress("zip", 0.0, "Compressing folder...");

    try {
      // Zip im Isolate erstellen
      final zipPath = await _zipFolderInIsolate(
        folder.path,
        onProgress: onProgress,
      );

      _notifyProgress("zip", 1.0, "Compression complete!");
      _notifyMessage("📦 Folder compressed!");

      // Zip-File senden
      final transferId = await sendFile(File(zipPath), targetIds);
      
      // Zip in active operations speichern für Cleanup
      _activeOperations[transferId] = zipPath;

      return transferId;

    } catch (e) {
      _notifyMessage("Compression failed: $e", isError: true);
      rethrow;
    } finally {
      _notifyProcessingState(false);
    }
  }

  /// Erstellt Offer auf dem Server
  Future<void> _offerFile({
    required String filePath,
    required String targetId,
    required String transferId,
  }) async {
    final fileName = p.basename(filePath);
    final fileSize = File(filePath).lengthSync();
    final directLink = "http://$_myLocalIp:${_localServer!.port}/download/${Uri.encodeComponent(filePath)}";

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
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        _activeOperations[transferId] = filePath;
        print("✅ Offer sent: $fileName → $targetId");
      } else {
        throw Exception("Server returned ${response.statusCode}");
      }
    } catch (e) {
      print("❌ Failed to offer file: $e");
      throw Exception("Failed to offer file: $e");
    }
  }

  // =============================================================================
  // RECEIVE OPERATIONS
  // =============================================================================

  /// Verarbeitet eingehende Transfers (wird von Sync Loop aufgerufen)
  Future<void> processIncomingTransfers(String downloadPath) async {
    if (downloadPath.isEmpty) {
      print("⚠️ No download path specified");
      return;
    }

    for (var transfer in _transfers) {
      // Skip bereits verarbeitete
      if (_processedTransferIds.contains(transfer.id)) continue;

      // Handle basierend auf Status
      if (transfer.status == TransferStatus.offered) {
        await _handleOfferedTransfer(transfer, downloadPath);
      } else if (transfer.status == TransferStatus.relayReady) {
        await _handleRelayReadyTransfer(transfer, downloadPath);
      }
    }
  }

  Future<void> _handleOfferedTransfer(Transfer transfer, String downloadPath) async {
    _processedTransferIds.add(transfer.id);
    
    final targetFile = File(p.join(downloadPath, transfer.fileName));
    
    _notifyMessage("📥 Incoming: ${transfer.fileName}");
    
    // Versuche P2P Download
    final p2pSuccess = await _tryP2PDownload(transfer, targetFile);
    
    if (p2pSuccess) {
      _notifyMessage("✨ Downloaded via P2P: ${transfer.fileName}");
      
      // Update local transfer
      final updatedTransfer = transfer.copyWith(
        status: TransferStatus.completed,
        mode: TransferMode.p2p,
        progress: 1.0,
        completedAt: DateTime.now(),
      );
      
      final index = _transfers.indexWhere((t) => t.id == transfer.id);
      if (index != -1) {
        _transfers[index] = updatedTransfer;
        _notifyTransferUpdate(updatedTransfer);
      }
      
      await _reportTransferEvent(transfer.id, "completed", "via P2P");
    } else {
      _notifyMessage("⚠️ P2P failed, requesting relay...");
      
      // Fordere Relay an
      await _requestRelay(transfer.id);
      
      // Entferne aus processed damit beim nächsten Sync als RELAY_READY behandelt wird
      _processedTransferIds.remove(transfer.id);
    }
  }

  Future<void> _handleRelayReadyTransfer(Transfer transfer, String downloadPath) async {
    _processedTransferIds.add(transfer.id);
final targetFile = File(p.join(downloadPath, transfer.fileName));
    
    _notifyMessage("☁️ Downloading from relay: ${transfer.fileName}");
    
    await _downloadFromRelay(transfer, targetFile);
    
    // Update local transfer
    final updatedTransfer = transfer.copyWith(
      status: TransferStatus.completed,
      mode: TransferMode.relay,
      progress: 1.0,
      completedAt: DateTime.now(),
    );
    
    final index = _transfers.indexWhere((t) => t.id == transfer.id);
    if (index != -1) {
      _transfers[index] = updatedTransfer;
      _notifyTransferUpdate(updatedTransfer);
    }
  }

  // =============================================================================
  // P2P DOWNLOAD
  // =============================================================================

  Future<bool> _tryP2PDownload(Transfer transfer, File targetFile) async {
    if (transfer.directLink == null) return false;

    _notifyProcessingState(true);
    _notifyProgress(transfer.id, 0.0, "Downloading (P2P)...");

    try {
      final request = http.Request('GET', Uri.parse(transfer.directLink!));
      final response = await http.Client()
          .send(request)
          .timeout(const Duration(seconds: 120));

      if (response.statusCode != 200) {
        throw Exception("HTTP ${response.statusCode}");
      }

      final sink = targetFile.openWrite();
      int receivedBytes = 0;
      final totalBytes = response.contentLength ?? transfer.fileSize;

      await for (var chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;

        _notifyProgress(
          transfer.id,
          receivedBytes / totalBytes,
          "${_formatBytes(receivedBytes)} / ${_formatBytes(totalBytes)}",
        );
      }

      await sink.close();
      
      print("✅ P2P download completed: ${transfer.fileName}");
      return true;

    } catch (e) {
      print("❌ P2P download failed: $e");
      
      // Cleanup partial file
      try {
        if (targetFile.existsSync()) await targetFile.delete();
      } catch (_) {}
      
      return false;
    } finally {
      _notifyProcessingState(false);
    }
  }

  // =============================================================================
  // RELAY OPERATIONS
  // =============================================================================

  Future<void> _requestRelay(String transferId) async {
    try {
      await http.post(
        Uri.parse('$serverBaseUrl/transfer/request_relay'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({"transfer_id": transferId}),
      ).timeout(const Duration(seconds: 10));
      
      print("📡 Relay requested for $transferId");
    } catch (e) {
      print("❌ Failed to request relay: $e");
    }
  }

  Future<void> _uploadToRelay(String filePath, String transferId) async {
    _notifyProcessingState(true);
    _notifyProgress(transferId, 0.0, "Uploading to relay...");

    try {
      final file = File(filePath);
      final fileSize = file.lengthSync();
      
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$serverBaseUrl/upload'),
      );

      request.fields['transfer_id'] = transferId;
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      final streamedResponse = await request.send().timeout(
        const Duration(minutes: 60),
      );

      if (streamedResponse.statusCode == 200) {
        _activeOperations.remove(transferId);
        await _reportTransferEvent(transferId, "completed", "Upload via Relay");
        _notifyMessage("☁️ Upload completed!");
        print("✅ Relay upload completed: ${p.basename(filePath)}");
      } else {
        throw Exception("HTTP ${streamedResponse.statusCode}");
      }

    } catch (e) {
      print("❌ Relay upload failed: $e");
      await _reportTransferEvent(transferId, "failed", "Upload error: $e");
      _notifyMessage("Upload failed: $e", isError: true);
    } finally {
      _notifyProcessingState(false);
    }
  }

  Future<void> _downloadFromRelay(Transfer transfer, File targetFile) async {
    _notifyProcessingState(true);
    _notifyProgress(transfer.id, 0.0, "Downloading from relay...");

    try {
      final response = await http.Client().send(
        http.Request('GET', Uri.parse('$serverBaseUrl/download/relay/${transfer.id}')),
      );

      if (response.statusCode != 200) {
        throw Exception("HTTP ${response.statusCode}");
      }

      final sink = targetFile.openWrite();
      int receivedBytes = 0;
      final totalBytes = response.contentLength ?? transfer.fileSize;

      await for (var chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;

        _notifyProgress(
          transfer.id,
          receivedBytes / totalBytes,
          "${_formatBytes(receivedBytes)} / ${_formatBytes(totalBytes)}",
        );
      }

      await sink.close();
      
      await _reportTransferEvent(transfer.id, "completed", "Downloaded via Relay");
      _notifyMessage("✅ Downloaded: ${transfer.fileName}");
      print("✅ Relay download completed: ${transfer.fileName}");

    } catch (e) {
      print("❌ Relay download failed: $e");
      
      // Cleanup partial file
      try {
        if (targetFile.existsSync()) await targetFile.delete();
      } catch (_) {}
      
      await _reportTransferEvent(transfer.id, "failed", "Download error: $e");
      _notifyMessage("Download failed: $e", isError: true);
    } finally {
      _notifyProcessingState(false);
    }
  }

  // =============================================================================
  // FOLDER ZIP (ISOLATE)
  // =============================================================================

  Future<String> _zipFolderInIsolate(
    String folderPath, {
    Function(double progress, String message)? onProgress,
  }) async {
    final receivePort = ReceivePort();
    
    await Isolate.spawn(_zipIsolateEntry, [receivePort.sendPort, folderPath]);

    String? resultPath;
    
    await for (final message in receivePort) {
      if (message is ZipProgress) {
        if (message.error != null) {
          receivePort.close();
          throw Exception(message.error);
        }

        if (message.resultPath != null) {
          resultPath = message.resultPath;
          receivePort.close();
          break;
        } else {
          onProgress?.call(message.progress, message.message);
          _notifyProgress("zip", message.progress, message.message);
        }
      }
    }

    if (resultPath == null) {
      throw Exception("Zip failed: No result path");
    }

    return resultPath;
  }

  // =============================================================================
  // UTILITY
  // =============================================================================

  String _generateTransferId() {
    return "${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}";
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / 1024 / 1024).toStringAsFixed(1)} MB";
    return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }
}

// =============================================================================
// ISOLATE FUNCTIONS (AUSSERHALB DER KLASSE!)
// =============================================================================

/// Isolate Entry Point für Folder-Komprimierung
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
    } catch (e) {
      totalBytes = 1;
    }

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
  ZipFileEncoder encoder,
  Directory dir,
  String relPath,
  Function(int) onBytesAdded,
) async {
  try {
    final entities = dir.listSync(recursive: false, followLinks: false);
    for (var entity in entities) {
      final name = p.basename(entity.path);
      if (name.startsWith('.') || name.startsWith(r'$') || name == "System Volume Information") {
        continue;
      }

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