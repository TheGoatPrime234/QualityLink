import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/server_config.dart';

/// Zentraler Heartbeat-Service für die Ecosystem-Kommunikation
/// Verwaltet die Verbindung zum Server und hält die Gerätepräsenz aufrecht
class HeartbeatService {
  // Singleton Pattern für globalen Zugriff
  static final HeartbeatService _instance = HeartbeatService._internal();
  factory HeartbeatService() => _instance;
  HeartbeatService._internal();

  // Service State
  Timer? _heartbeatTimer;
  bool _isRunning = false;
  bool _isConnected = false;
  String _localIp = "0.0.0.0";
  
  // Client Informationen
  String? _clientId;
  String? _deviceName;
  int? _fileServerPort;
  
  // Callbacks für Status-Updates
  final List<Function(bool isConnected)> _connectionListeners = [];
  final List<Function(List<dynamic> peers)> _peerListeners = [];
  final List<Function(String error)> _errorListeners = [];
  
  // Konfigurierbare Parameter
  Duration heartbeatInterval = const Duration(seconds: 3);
  Duration connectionTimeout = const Duration(seconds: 10);
  int maxRetries = 3;
  bool autoReconnect = true;

  // Getter für externen Zugriff
  bool get isRunning => _isRunning;
  bool get isConnected => _isConnected;
  String get localIp => _localIp;

  /// Initialisiert und startet den Heartbeat-Service
  Future<void> start({
    required String clientId,
    required String deviceName,
    int? fileServerPort,
  }) async {
    if (_isRunning) {
      print("⚠️ HeartbeatService is already running");
      return;
    }

    _clientId = clientId;
    _deviceName = deviceName;
    _fileServerPort = fileServerPort;

    print("🚀 Starting HeartbeatService for client: $clientId");

    // Lokale IP ermitteln
    await _detectLocalIp();

    // Ersten Heartbeat sofort senden
    await _sendHeartbeat();

    // Periodischen Timer starten
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (timer) {
      _sendHeartbeat();
    });

    _isRunning = true;
    print("✅ HeartbeatService started successfully");
  }

  /// Stoppt den Heartbeat-Service
  Future<void> stop() async {
    if (!_isRunning) return;

    print("🛑 Stopping HeartbeatService");
    
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _isRunning = false;
    _isConnected = false;

    // Finalen Disconnect-Heartbeat senden (optional)
    await _sendDisconnectHeartbeat();

    print("✅ HeartbeatService stopped");
  }

  /// Pausiert den Service (z.B. bei App-Minimize)
  void pause() {
    if (!_isRunning) return;
    _heartbeatTimer?.cancel();
    print("⏸️ HeartbeatService paused");
  }

  /// Setzt den Service fort
  void resume() {
    if (!_isRunning) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (timer) {
      _sendHeartbeat();
    });
    _sendHeartbeat(); // Sofort senden nach Resume
    print("▶️ HeartbeatService resumed");
  }

  /// Aktualisiert den File-Server-Port
  Future<void> updateFileServerPort(int port) async {
    _fileServerPort = port;
    print("🔄 File server port updated to: $port");
    
    // Sofortigen Heartbeat senden um Server zu informieren
    await _sendHeartbeat();
  }

  /// Registriert einen Connection-Status Listener
  void addConnectionListener(Function(bool isConnected) listener) {
    _connectionListeners.add(listener);
  }

  /// Registriert einen Peer-Update Listener
  void addPeerListener(Function(List<dynamic> peers) listener) {
    _peerListeners.add(listener);
  }

  /// Registriert einen Error Listener
  void addErrorListener(Function(String error) listener) {
    _errorListeners.add(listener);
  }

  /// Entfernt alle Listener
  void clearListeners() {
    _connectionListeners.clear();
    _peerListeners.clear();
    _errorListeners.clear();
  }

  /// Ermittelt die lokale IP-Adresse des Geräts
  Future<void> _detectLocalIp() async {
    try {
      _localIp = "0.0.0.0";
      
      // Durchsuche alle Netzwerk-Interfaces
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.address.startsWith("127.")) {
            // Priorisiere 192.168.x.x (typisches lokales Netzwerk)
            if (addr.address.startsWith("192.168.")) {
              _localIp = addr.address;
              print("📡 Local IP detected: $_localIp (Priority: Home Network)");
              return;
            } 
            // Fallback zu 10.x.x.x oder 172.x.x.x
            else if (addr.address.startsWith("10.") || addr.address.startsWith("172.")) {
              if (_localIp == "0.0.0.0") {
                _localIp = addr.address;
              }
            }
          }
        }
      }

      // Fallback: Verbindung zum Server herstellen um eigene IP zu erfahren
      if (_localIp == "0.0.0.0") {
        try {
          final socket = await Socket.connect(serverIp, int.parse(serverPort))
              .timeout(const Duration(seconds: 5));
          _localIp = socket.address.address;
          socket.destroy();
          print("📡 Local IP detected via server connection: $_localIp");
        } catch (e) {
          _localIp = "127.0.0.1";
          print("⚠️ Could not detect IP, using localhost");
        }
      }
    } catch (e) {
      print("❌ Error detecting local IP: $e");
      _localIp = "127.0.0.1";
    }
  }

  /// Sendet einen Heartbeat an den Server
  Future<void> _sendHeartbeat() async {
    if (_clientId == null || _deviceName == null) {
      print("⚠️ Cannot send heartbeat: Client not initialized");
      return;
    }

    // File Server Port aus Preferences laden falls nicht gesetzt
    if (_fileServerPort == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        _fileServerPort = prefs.getInt('file_server_port');
      } catch (e) {
        print("⚠️ Could not load file_server_port from preferences");
      }
    }

    int retryCount = 0;
    bool success = false;

    while (retryCount < maxRetries && !success) {
      try {
        print("💓 Sending heartbeat (attempt ${retryCount + 1}/$maxRetries)");
        
        final response = await http.post(
          Uri.parse('$serverBaseUrl/heartbeat'),
          headers: {"Content-Type": "application/json"},
          body: json.encode({
            "client_id": _clientId,
            "client_name": _deviceName,
            "device_type": Platform.operatingSystem,
            "local_ip": _localIp,
            "file_server_port": _fileServerPort,
            "timestamp": DateTime.now().toIso8601String(),
            "app_version": "1.0.0", // TODO: Von Package-Info holen
          }),
        ).timeout(connectionTimeout);

        if (response.statusCode == 200) {
          success = true;
          
          // Connection Status aktualisieren
          if (!_isConnected) {
            _isConnected = true;
            print("✅ Connected to server");
            _notifyConnectionListeners(true);
          }

          // Peer-Liste verarbeiten
          try {
            final data = json.decode(response.body);
            final peers = data['active_peers'] as List<dynamic>? ?? [];
            
            print("👥 Active peers: ${peers.length}");
            _notifyPeerListeners(peers);
            
          } catch (e) {
            print("⚠️ Error parsing peer data: $e");
          }

          // Storage registrieren (wenn aktiviert)
          await _registerStorage();
          
        } else {
          throw Exception("Server returned ${response.statusCode}");
        }

      } catch (e) {
        retryCount++;
        print("❌ Heartbeat failed (attempt $retryCount/$maxRetries): $e");
        
        if (retryCount >= maxRetries) {
          if (_isConnected) {
            _isConnected = false;
            print("🔴 Disconnected from server");
            _notifyConnectionListeners(false);
            _notifyErrorListeners("Connection lost after $maxRetries retries");
          }
          
          // Auto-Reconnect Logic
          if (autoReconnect && retryCount >= maxRetries) {
            print("🔄 Will retry on next heartbeat cycle");
          }
        } else {
          // Kurze Pause vor nächstem Retry
          await Future.delayed(Duration(seconds: 2));
        }
      }
    }
  }

  /// Sendet finalen Disconnect-Heartbeat
  Future<void> _sendDisconnectHeartbeat() async {
    if (_clientId == null) return;

    try {
      await http.post(
        Uri.parse('$serverBaseUrl/disconnect'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "client_id": _clientId,
          "timestamp": DateTime.now().toIso8601String(),
        }),
      ).timeout(const Duration(seconds: 5));
      
      print("👋 Disconnect heartbeat sent");
    } catch (e) {
      print("⚠️ Could not send disconnect heartbeat: $e");
    }
  }

  /// Registriert verfügbare Storage-Pfade beim Server
  Future<void> _registerStorage() async {
    // Hier wird die Storage-Registrierung durchgeführt
    // Dies kann später erweitert werden wenn FileServerService verfügbar ist
    
    // Placeholder für Storage-Registrierung
    // TODO: Integration mit FileServerService
    try {
      // Dummy-Implementation - später durch echte Paths ersetzen
      final availablePaths = <String>[];
      
      if (availablePaths.isNotEmpty) {
        final response = await http.post(
          Uri.parse('$serverBaseUrl/storage/register'),
          headers: {"Content-Type": "application/json"},
          body: json.encode({
            "client_id": _clientId,
            "available_paths": availablePaths,
          }),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          print("📂 Storage registered successfully");
        }
      }
    } catch (e) {
      print("⚠️ Storage registration failed: $e");
    }
  }

  /// Benachrichtigt alle Connection-Listeners
  void _notifyConnectionListeners(bool isConnected) {
    for (var listener in _connectionListeners) {
      try {
        listener(isConnected);
      } catch (e) {
        print("⚠️ Error in connection listener: $e");
      }
    }
  }

  /// Benachrichtigt alle Peer-Listeners
  void _notifyPeerListeners(List<dynamic> peers) {
    for (var listener in _peerListeners) {
      try {
        listener(peers);
      } catch (e) {
        print("⚠️ Error in peer listener: $e");
      }
    }
  }

  /// Benachrichtigt alle Error-Listeners
  void _notifyErrorListeners(String error) {
    for (var listener in _errorListeners) {
      try {
        listener(error);
      } catch (e) {
        print("⚠️ Error in error listener: $e");
      }
    }
  }

  /// Erzwingt sofortigen Heartbeat (für manuelle Sync-Trigger)
  Future<void> forceHeartbeat() async {
    print("🔄 Forcing immediate heartbeat");
    await _sendHeartbeat();
  }

  /// Gibt Debug-Informationen zurück
  Map<String, dynamic> getDebugInfo() {
    return {
      'isRunning': _isRunning,
      'isConnected': _isConnected,
      'clientId': _clientId,
      'deviceName': _deviceName,
      'localIp': _localIp,
      'fileServerPort': _fileServerPort,
      'heartbeatInterval': heartbeatInterval.inSeconds,
      'activeListeners': {
        'connection': _connectionListeners.length,
        'peer': _peerListeners.length,
        'error': _errorListeners.length,
      },
    };
  }
}