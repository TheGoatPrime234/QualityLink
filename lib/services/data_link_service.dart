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

    print("🚀 Starting DataLinkService v4 (Fast Boot) for: $_clientId");

    // 1. WebSocket SOFORT verbinden (für Echtzeit-Status)
    _connectWebSocket();

    // 2. SOFORT "Hallo" an den Server senden (Heartbeat)
    // Damit erscheinst du sofort auf dem Laptop!
    _sendHeartbeat(); 

    // 3. Lokalen Server parallel starten (nicht warten!)
    _startLocalServer().then((_) {
      print("🌐 Local Server ready (Background)");
    });

    // 4. Sync Loop starten (für Fallback)
    _startSyncLoop();

    _isRunning = true;
    print("✅ DataLinkService started (Instant Mode)");
  }

  Future<void> _sendHeartbeat() async {
    try {
      // Wir sagen dem Server: "Hier bin ich, das ist meine IP, das ist mein Port"
      await http.post(
        Uri.parse('$serverBaseUrl/heartbeat'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "client_id": _clientId,
          "client_name": Platform.localHostname, // Oder dein App-Name
          "device_type": Platform.isAndroid || Platform.isIOS ? "mobile" : "desktop",
          "local_ip": _myLocalIp,
          "file_server_port": _localServer?.port ?? 0, // 0 falls Server noch startet
        }),
      ).timeout(const Duration(seconds: 2)); // Kurzer Timeout, darf App nicht blockieren!
    } catch (e) {
      // Leise scheitern, wir versuchen es im Loop gleich wieder
      print("💓 Heartbeat skipped: $e");
    }
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

  // In lib/services/data_link_service.dart

  void _handleWebSocketMessage(String message) {
    try {
      final data = json.decode(message);
      final event = data['event'];

      // Fall A: Jemand bietet mir eine Datei an
      if (event == 'transfer_offer') {
        print("🚀 INSTANT OFFER RECEIVED via WebSocket!");
        final transferData = data['transfer'];
        _handleInstantOffer(transferData);
      } 
      
      // Fall B: Remote Command (Löschen, Umbenennen...)
      else if (event == 'execute_command') {
        _handleRemoteCommand(data);
      }
      
      // Fall C: RELAY UPDATE (Das hat gefehlt!)
      // Der Server sagt: "Datei liegt jetzt auf der Festplatte bereit!"
      // Fall C: RELAY UPDATE
      else if (event == 'transfer_update') {
          final transferData = data['transfer'];
          
          // 🔥 FIX 1: Wir wrappen die Daten im erwarteten 'meta'-Format
          final transfer = Transfer.fromServerResponse({
             'meta': transferData,
             'status': transferData['status'] ?? 'RELAY_READY',
             'timestamp': transferData['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
          });
          
          // UI Update
          _notifyTransferUpdate(transfer);
          
          // ENTSCHEIDUNG: Ist das für mich? Und ist es bereit?
          if (transfer.status == TransferStatus.relayReady && 
              !_processedTransferIds.contains(transfer.id) &&
              _downloadPath.isNotEmpty) {
                
            print("🔔 Relay Download Triggered via WebSocket!");
            // Download vom Pi starten
            _handleRelayReadyTransfer(transfer, _downloadPath);
          }
      }
    } catch (e) {
      print("⚠️ WS Message Parse Error: $e");
    }
  }
  // ✅ NEUE METHODE: Führt Befehle vom Server aus
  // In lib/services/data_link_service.dart

  Future<void> _handleRemoteCommand(Map<String, dynamic> data) async {
    final action = data['action'];
    final params = data['params'];
    final senderId = data['sender_id'];

    print("🤖 Executing remote command: $action");

    try {
      // 1. LÖSCHEN
      if (action == 'delete') {
        final path = params['path'];
        if (path != null) {
          final entity = File(path);
          if (await entity.exists()) {
            await entity.delete();
          } else {
            final dir = Directory(path);
            if (await dir.exists()) await dir.delete(recursive: true);
          }
          print("🗑️ Deleted: $path");
        }
      } 
      // 2. UMBENENNEN
      else if (action == 'rename') {
        final path = params['path'];
        final newName = params['new_name'];
        if (path != null && newName != null) {
          final file = File(path);
          final dir = Directory(path);
          String newPath = p.join(p.dirname(path), newName);
          
          if (await file.exists()) {
            await file.rename(newPath);
          } else if (await dir.exists()) {
            await dir.rename(newPath);
          }
          print("✏️ Renamed to: $newPath");
        }
      }
      // 3. KOPIEREN (Lokal)
      else if (action == 'copy') {
        final path = params['path'];
        final destination = params['destination'];
        if (path != null && destination != null) {
          final file = File(path);
          if (await file.exists()) {
            final fileName = p.basename(path);
            // Verhindere Überschreiben durch "_copy" Suffix falls nötig
            String newPath = p.join(destination, fileName);
            if (await File(newPath).exists()) {
               final name = p.basenameWithoutExtension(fileName);
               final ext = p.extension(fileName);
               newPath = p.join(destination, "${name}_copy$ext");
            }
            await file.copy(newPath);
            print("©️ Copied to: $newPath");
          }
        }
      }
      // 4. VERSCHIEBEN (Lokal)
      else if (action == 'move') {
        final path = params['path'];
        final destination = params['destination'];
        if (path != null && destination != null) {
          final file = File(path);
          final dir = Directory(path);
          final fileName = p.basename(path);
          final newPath = p.join(destination, fileName);
          
          if (await file.exists()) {
            await file.rename(newPath); 
          } else if (await dir.exists()) {
            await dir.rename(newPath);
          }
          print("🚚 Moved to: $newPath");
        }
      }
      // 5. TRANSFER REQUEST (Download mit Ordner-Support!)
      else if (action == 'request_transfer') {
        final path = params['path'];
        final requesterId = params['requester_id'];
        // NEU: Zielpfad empfangen (wohin will der Anforderer die Datei haben?)
        final destPath = params['destination_path']; 
        
        if (path != null && requesterId != null) {
          print("📤 Handling transfer request for $path -> $requesterId");
          
          if (await File(path).exists()) {
            // Wir senden die Datei UND geben den gewünschten Zielpfad weiter!
            await sendFile(
              File(path), 
              [requesterId], 
              destinationPath: destPath // <--- Das ist das Echo!
            );
          } else if (await Directory(path).exists()) {
            // Ordner senden (Target Path wird hier nicht unterstützt, landet im Download)
            await sendFolder(Directory(path), [requesterId]);
          } else {
             print("❌ Item not found: $path");
          }
        }
      }
      
      // Feedback senden (Optional für später)
      _sendToWebSocket({
        "event": "command_result",
        "target_id": senderId,
        "status": "success",
        "action": action
      });

    } catch (e) {
      print("❌ Command '$action' failed: $e");
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
    
    // SOFORT ausführen!
    _syncTransfers();
    _monitorSenderTasks();
    _sendHeartbeat(); // Wichtig!

    // Dann alle 5 Sekunden wiederholen (schnelleres Update)
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _sendHeartbeat(); // Regelmäßiges "Ich lebe noch"
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
          // 🔥 FIX 2: Auch beim Polling-Fallback die Daten richtig wrappen!
          final transfer = Transfer.fromServerResponse({
             'meta': transferData,
             'status': transferData['status'] ?? 'OFFERED',
             'timestamp': transferData['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
          });
          
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

  // In lib/services/data_link_service.dart

  Future<void> _handleP2PRequest(HttpRequest request) async {
    try {
      // Wir prüfen, ob der Pfad mit /download/ beginnt
      if (request.uri.pathSegments.isNotEmpty && request.uri.pathSegments.first == 'download') {
        
        // Den Rest des Pfades holen (alles nach /download/)
        String rawPath = request.uri.pathSegments.skip(1).join("/");
        
        // 🛡️ FIX: Sicherheit gegen "Illegal Percent Encoding"
        String filePath;
        try {
          filePath = Uri.decodeComponent(rawPath);
        } catch (e) {
          // Fallback: Wenn decode knallt, nehmen wir den Pfad so wie er ist
          print("⚠️ URI Decode failed, using raw path: $rawPath");
          filePath = rawPath;
        }

        print("📂 P2P Request for: $filePath"); 
        final file = File(filePath);
        
        if (!file.existsSync()) {
          request.response.statusCode = 404;
          request.response.write("File not found");
          await request.response.close();
          return;
        }

        final totalBytes = file.lengthSync();
        // Header sicher machen (encodeComponent verhindert Header-Fehler bei Umlauten)
        final safeName = Uri.encodeComponent(p.basename(filePath));
        
        request.response.statusCode = 200;
        request.response.headers.add("Content-Type", "application/octet-stream");
        request.response.headers.add("Content-Length", totalBytes);
        request.response.headers.add("Content-Disposition", 'attachment; filename="$safeName"');

        // Streaming...
        try {
          await request.response.addStream(file.openRead());
          await request.response.close();
        } catch (_) {
          // Client hat abgebrochen
        }

      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    } catch (e) {
      print("❌ P2P Server Error: $e");
      try {
        request.response.statusCode = 500;
        request.response.write("Internal Error");
        await request.response.close();
      } catch (_) {}
    }
  }

  // =============================================================================
  // SEND OPERATIONS
  // =============================================================================

  // In lib/services/data_link_service.dart

  Future<String> sendFile(File file, List<String> targetIds, {String? destinationPath}) async {
    if (targetIds.isEmpty) throw Exception("No targets selected");
    if (!file.existsSync()) throw Exception("File not found");

    final transferId = _generateTransferId();
    // Pfad für Windows & Server sicher machen
    final fileName = p.basename(file.path); 

    print("📤 Sending file: $fileName");

    for (var targetId in targetIds) {
      // 1. Dem Server Bescheid sagen ("Ich will was senden")
      await _offerFile(
        filePath: file.path,
        targetId: targetId,
        transferId: transferId,
        destinationPath: destinationPath,
      );

      if (targetId == "SERVER") {
         print("⚡ Target is SERVER. Bypassing P2P, requesting direct Upload...");
         await _requestRelay(transferId, file.path);
         continue; // Direkt zum nächsten Gerät springen
      }

      // 2. Der entscheidende Moment: P2P oder Relay?
      try {
         print("⚡ Trying P2P connection to $targetId...");
         await Future.delayed(const Duration(seconds: 2));
         
         // Wenn der Transfer noch nicht läuft/fertig ist, nehmen wir an, P2P ist gescheitert.
         if (!_activeOperations.containsKey(transferId)) {
           throw Exception("P2P too slow, switching to Relay");
         }
         
       } catch (p2pError) {
         print("⚠️ P2P unavailable ($p2pError). Switching to RELAY Cloud Upload...");
         
         // 3. FALLBACK: Relay anfordern!
         // Das lädt die Datei auf den Raspberry Pi hoch.
         await _requestRelay(transferId, file.path);
       }
    }
    
    _notifyMessage("✅ Transfer started: $fileName");
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

  Future<void> _handleOfferedTransfer(Transfer t, String path) async {
    _processedTransferIds.add(t.id);
    
    // Zielpfad bestimmen
    File target = File(p.join(t.destinationPath ?? path, t.fileName));
    
    // Versuch 1: P2P Download
    bool p2pSuccess = await _tryP2PDownload(t, target);
    
    if (p2pSuccess) {
      _reportTransferEvent(t.id, "completed", "P2P");
      _updateTransferStatus(t, TransferStatus.completed);
      _notifyMessage("✨ P2P Success: ${t.fileName}");
    } else {
      // P2P FEHLGESCHLAGEN
      _notifyMessage("⚠️ P2P failed via Mobile/Remote. Requesting Sender Relay...");
      
      // 🛑 STOP! Wir laden NICHT hoch (wir haben die Datei ja nicht).
      // Wir bitten den Server, dem SENDER Bescheid zu sagen.
      await _requestRelayFromSender(t.id);
      
      // Wir entfernen die ID aus "processed", damit wir später das Relay-Update akzeptieren
      _processedTransferIds.remove(t.id);
    }
  }

  // Neue Hilfsmethode: Fordert den Sender auf, das Relay zu nutzen
  Future<void> _requestRelayFromSender(String transferId) async {
    try {
      await http.post(
        Uri.parse('$serverBaseUrl/transfer/request_relay'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({"transfer_id": transferId}),
      );
      print("📡 Sent Relay Request to Server (waiting for Sender upload)");
    } catch (e) {
      print("❌ Failed to request relay: $e");
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
      // 🔥 FIX: HttpClient verwenden, um einen strikten Connection-Timeout zu setzen!
      // Wenn das Gerät in einem anderen Netzwerk ist, schlägt dies in 3 Sekunden fehl 
      // (anstatt nach 2 Minuten) und löst sofort den Cloud-Relay Fallback aus!
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);

      final request = await client.getUrl(Uri.parse(transfer.directLink!));
      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception("HTTP ${response.statusCode}");
      }

      final sink = targetFile.openWrite();
      int received = 0;
      final total = response.contentLength; // Kann -1 sein, falls nicht bekannt

      await for (var chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _notifyProgress(transfer.id, received / total, "${_formatBytes(received)} / ${_formatBytes(total)}");
        } else {
          _notifyProgress(transfer.id, 0.5, "Downloading...");
        }
      }
      
      await sink.close();
      client.close();
      return true;
      
    } catch (e) {
      print("❌ P2P Fast-Fail triggered: $e");
      try { if (targetFile.existsSync()) await targetFile.delete(); } catch (_) {}
      return false;
    } finally {
      _notifyProcessingState(false);
    }
  }

  // =============================================================================
  // RELAY HELPERS
  // =============================================================================

  Future<void> _requestRelay(String transferId, String filePath) async {
    // Pfad vorab bereinigen
    String cleanPath = p.normalize(filePath.trim());
    
    // Versuch, den echten Pfad aufzulösen, falls die Datei existiert
    try {
      final f = File(cleanPath);
      if (f.existsSync()) {
        cleanPath = f.resolveSymbolicLinksSync();
      }
    } catch (_) {}

    print("⚠️ P2P failed. Requesting Relay for $cleanPath...");
    _notifyProgress(transferId, 0.0, "Requesting Cloud Relay...");

    try {
      // ... (Rest der Funktion bleibt gleich, nur beim Aufruf unten cleanPath nutzen) ...
      
      final uri = Uri.parse('$serverBaseUrl/transfer/request_relay');
      final response = await http.post(
        uri,
        headers: {"Content-Type": "application/json"}, 
        body: json.encode({"transfer_id": transferId}),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'relay_requested') {
          print("✅ Server approved relay. Starting upload...");
          
          // HIER den sauberen Pfad nutzen!
          await _uploadToRelay(cleanPath, transferId);
          
        } else {
          throw Exception("Server denied relay: ${data['status']}");
        }
      } 
      // ... (Rest der Fehlerbehandlung) ...
    } catch (e) {
      print("❌ Relay Request Failed: $e");
      _notifyMessage("Relay failed: $e", isError: true);
    }
  }

  Future<void> _monitorSenderTasks() async {
    // Wir schauen uns alle Transfers an, die wir gerade versenden ("activeOperations")
    for (var transferId in _activeOperations.keys.toList()) {
      try {
        final response = await http.get(Uri.parse('$serverBaseUrl/transfer/status/$transferId'));
        
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          
          // Wenn der Status "RELAY_REQUESTED" ist, heißt das:
          // Der Empfänger hat gesagt "P2P geht nicht, bitte lad hoch!"
          if (data['status'] == "RELAY_REQUESTED" && !_isProcessing) {
            print("🚀 Empfänger hat Relay angefordert. Starte Upload...");
            
            final filePath = _activeOperations[transferId]!;
            
            // JETZT laden wir hoch (wir sind ja der Sender!)
            await _uploadToRelay(filePath, transferId);
          }
        }
      } catch (e) {
        // Fehler ignorieren, nächster Check kommt bald
      }
    }
  }

  // In lib/services/data_link_service.dart

  Future<void> _uploadToRelay(String filePath, String transferId) async {
    _notifyProcessingState(true);
    _notifyProgress(transferId, 0.0, "Preparing upload...");

    try {
      // ---------------------------------------------------------
      // 🧹 PFAD BEREINIGUNG (Der Fix für Windows & Sonderzeichen)
      // ---------------------------------------------------------
      String cleanPath = filePath.trim();

      if (cleanPath.contains('%')) {
        try { cleanPath = Uri.decodeFull(cleanPath); } catch (_) {}
      }

      cleanPath = p.normalize(cleanPath);
      File file = File(cleanPath);
      
      if (!file.existsSync()) {
        try {
           cleanPath = file.resolveSymbolicLinksSync();
           file = File(cleanPath);
        } catch (_) {}
      }
      
      if (!file.existsSync()) {
        file = File(filePath);
        if (!file.existsSync()) {
           throw Exception("OS Error: File not found at '$cleanPath'");
        }
      }
      // ---------------------------------------------------------

      final fileSize = file.lengthSync();
      final fileName = p.basename(cleanPath);
      
      final safeFileName = Uri.encodeComponent(fileName);

      print("🚀 Uploading $fileName to Relay");

      final uri = Uri.parse('$serverBaseUrl/upload');
      final request = http.StreamedRequest('POST', uri);
      
      final boundary = 'dart-boundary-${DateTime.now().millisecondsSinceEpoch}';
      request.headers['Content-Type'] = 'multipart/form-data; boundary=$boundary';
      
      final transferIdField = '--$boundary\r\nContent-Disposition: form-data; name="transfer_id"\r\n\r\n$transferId\r\n';
      
      final fileHeader = '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$safeFileName"\r\nContent-Type: application/octet-stream\r\n\r\n';
      final endBoundary = '\r\n--$boundary--\r\n';
      
      final totalRequestSize = utf8.encode(transferIdField + fileHeader + endBoundary).length + fileSize;
      request.contentLength = totalRequestSize;
      
      // 🔥 FIX 1: Die Verbindung MUSS gestartet werden, BEVOR wir die Datei in den Speicher streamen!
      // Sonst blockiert der Arbeitsspeicher bei größeren Dateien und der Upload hängt sich auf.
      final responseFuture = request.send();
      
      request.sink.add(utf8.encode(transferIdField));
      request.sink.add(utf8.encode(fileHeader));
      
      int sentFileBytes = 0;
      Stream<List<int>> stream = file.openRead();
      
      await for (var chunk in stream) {
        request.sink.add(chunk);
        sentFileBytes += chunk.length;
        // Updates reduzieren, um die UI flüssig zu halten
        if (sentFileBytes % (512 * 1024) == 0 || sentFileBytes == fileSize) {
           _notifyProgress(transferId, sentFileBytes / fileSize, "Uploading...");
        }
      }
      
      request.sink.add(utf8.encode(endBoundary));
      await request.sink.close();
      
      _notifyProgress(transferId, 1.0, "Finalizing..."); 
      
      // 🔥 FIX 2: Jetzt warten wir auf die Server-Antwort des Streams, der im Hintergrund hochgeladen hat
      final response = await responseFuture;
      
      if (response.statusCode == 200) {
        _activeOperations.remove(transferId);
        _notifyMessage("☁️ Upload completed");
        await _reportTransferEvent(transferId, "completed", "Relay Upload");
      } else {
        final respStr = await response.stream.bytesToString();
        throw Exception("Server Error ${response.statusCode}: $respStr");
      }
    } catch (e) {
      print("❌ Upload Failed: $e");
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