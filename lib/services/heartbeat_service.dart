import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/server_config.dart';
import 'file_server_service.dart';

class HeartbeatService {
  static final HeartbeatService _instance = HeartbeatService._internal();
  factory HeartbeatService() => _instance;
  HeartbeatService._internal();

  Timer? _heartbeatTimer;
  bool _isRunning = false;
  bool _isConnected = false;
  String _localIp = "0.0.0.0";
  
  String? _clientId;
  String? _deviceName;
  int? _fileServerPort;
  
  final List<Function(bool isConnected)> _connectionListeners = [];
  final List<Function(List<dynamic> peers)> _peerListeners = [];
  final List<Function(String error)> _errorListeners = [];
  
  Duration heartbeatInterval = const Duration(seconds: 3);
  Duration connectionTimeout = const Duration(seconds: 10);
  int maxRetries = 3;
  bool autoReconnect = true;

  bool get isRunning => _isRunning;
  bool get isConnected => _isConnected;
  String get localIp => _localIp;

Future<void> start({
    required String clientId,
    required String deviceName,
    int? fileServerPort,
  }) async {
    if (_isRunning) return;

    _clientId = clientId;
    _deviceName = deviceName;
    _fileServerPort = fileServerPort;

    await _detectLocalIp();
    await _sendHeartbeat();

    _heartbeatTimer = Timer.periodic(heartbeatInterval, (timer) {
      _sendHeartbeat();
    });

    _isRunning = true;
  }

  Future<void> stop() async {
    if (!_isRunning) return;

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _isRunning = false;
    _isConnected = false;

    await _sendDisconnectHeartbeat();
  }

  void pause() {
    if (!_isRunning) return;
    _heartbeatTimer?.cancel();
  }

  void resume() {
    if (!_isRunning) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (timer) {
      _sendHeartbeat();
    });
    _sendHeartbeat();
  }

  Future<void> updateFileServerPort(int port) async {
    _fileServerPort = port;
    await _sendHeartbeat();
  }

void addConnectionListener(Function(bool isConnected) listener) {
    _connectionListeners.add(listener);
  }

  void addPeerListener(Function(List<dynamic> peers) listener) {
    _peerListeners.add(listener);
  }

  void addErrorListener(Function(String error) listener) {
    _errorListeners.add(listener);
  }

  void clearListeners() {
    _connectionListeners.clear();
    _peerListeners.clear();
    _errorListeners.clear();
  }

  Future<void> _detectLocalIp() async {
    try {
      _localIp = "0.0.0.0";
      
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.address.startsWith("127.")) {
            if (addr.address.startsWith("192.168.")) {
              _localIp = addr.address;
              return;
            } else if (addr.address.startsWith("10.") || addr.address.startsWith("172.")) {
              if (_localIp == "0.0.0.0") {
                _localIp = addr.address;
              }
            }
          }
        }
      }

      if (_localIp == "0.0.0.0") {
        try {
          final socket = await Socket.connect(serverIp, int.parse(serverPort))
              .timeout(const Duration(seconds: 5));
          _localIp = socket.address.address;
          socket.destroy();
        } catch (e) {
          _localIp = "127.0.0.1";
        }
      }
    } catch (e) {
      _localIp = "127.0.0.1";
    }
  }

Future<void> _sendHeartbeat() async {
    if (_clientId == null || _deviceName == null) return;

    if (_fileServerPort == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        _fileServerPort = prefs.getInt('file_server_port');
      } catch (e) {}
    }

    int retryCount = 0;
    bool success = false;

    while (retryCount < maxRetries && !success) {
      try {
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
            "app_version": "1.0.0",
          }),
        ).timeout(connectionTimeout);

        if (response.statusCode == 200) {
          success = true;
          
          if (!_isConnected) {
            _isConnected = true;
            _notifyConnectionListeners(true);
          }

          try {
            final data = json.decode(response.body);
            final peers = data['active_peers'] as List<dynamic>? ?? [];
            _notifyPeerListeners(peers);
          } catch (e) {}

          await _registerStorage();
          
        } else {
          throw Exception("Server error");
        }

      } catch (e) {
        retryCount++;
        
        if (retryCount >= maxRetries) {
          if (_isConnected) {
            _isConnected = false;
            _notifyConnectionListeners(false);
            _notifyErrorListeners("Connection lost");
          }
        } else {
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }
  }

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
    } catch (e) {}
  }

  Future<void> _registerStorage() async {
    try {
      if (_fileServerPort == null || _fileServerPort == 0) return;
      
      final availablePaths = FileServerService.availablePaths;
      if (availablePaths.isEmpty) return;
      
      await http.post(
        Uri.parse('$serverBaseUrl/storage/register'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "client_id": _clientId,
          "available_paths": availablePaths,
        }),
      ).timeout(const Duration(seconds: 5));
    } catch (e) {}
  }

  void _notifyConnectionListeners(bool isConnected) {
    for (var listener in _connectionListeners) {
      try {
        listener(isConnected);
      } catch (e) {}
    }
  }

  void _notifyPeerListeners(List<dynamic> peers) {
    for (var listener in _peerListeners) {
      try {
        listener(peers);
      } catch (e) {}
    }
  }

  void _notifyErrorListeners(String error) {
    for (var listener in _errorListeners) {
      try {
        listener(error);
      } catch (e) {}
    }
  }

  Future<void> forceHeartbeat() async {
    await _sendHeartbeat();
  }

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