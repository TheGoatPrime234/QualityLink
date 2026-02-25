import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/server_config.dart';

// 1. DAS NEUE, GLOBALE GERÄTE-MODELL
class NetworkDevice {
  final String id;
  final String name;
  final String type;
  final String ip;
  final bool isOnline;
  final bool isSameLan;
  final int fileServerPort;

  // Stats (Für SystemPulse)
  final int lastSeenAgo;
  final int transfersSent;
  final int transfersReceived;
  final int clipboardEntries;

  NetworkDevice({
    required this.id, required this.name, required this.type, required this.ip,
    required this.isOnline, required this.isSameLan, this.fileServerPort = 0,
    this.lastSeenAgo = 0, this.transfersSent = 0, this.transfersReceived = 0, this.clipboardEntries = 0,
  });

  static bool isSameSubnet(String myIp, String peerIp) {
    try {
      if (myIp.startsWith('100.') && peerIp.startsWith('100.')) return true;
      final p1 = myIp.split('.');
      final p2 = peerIp.split('.');
      return p1[0] == p2[0] && p1[1] == p2[1] && p1[2] == p2[2];
    } catch (_) {
      return false;
    }
  }
}

// 2. DER MANAGER (Zentrale Verwaltung)
class DeviceManager extends ChangeNotifier {
  static final DeviceManager _instance = DeviceManager._internal();
  factory DeviceManager() => _instance;
  DeviceManager._internal();

  List<NetworkDevice> _devices = [];
  String _myIp = "0.0.0.0";
  Timer? _pollTimer;
  bool _isRunning = false;

  List<NetworkDevice> get devices => _devices;
  List<NetworkDevice> get onlineDevices => _devices.where((d) => d.isOnline).toList();
  
  int get totalDevices => _devices.length;
  int get activeDevicesCount => onlineDevices.length;

  void start(String myIp) {
    if (_isRunning) return;
    _myIp = myIp;
    _isRunning = true;
    resume(); 
  }

  void stop() {
    _isRunning = false;
    _pollTimer?.cancel();
  }

  void pause() {
    if (!_isRunning) return;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => refresh()); // Eco-Mode
  }

  void resume() {
    if (!_isRunning) return;
    _pollTimer?.cancel();
    refresh(); 
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => refresh()); // Active-Mode
  }

  // 🔥 Die Kern-Funktion: Holt Admin-Stats UND Storage-Ports auf einmal!
  Future<void> refresh() async {
    try {
      final adminResFuture = http.get(Uri.parse('$serverBaseUrl/admin/devices')).timeout(const Duration(seconds: 5));
      final storageResFuture = http.get(Uri.parse('$serverBaseUrl/storage/devices')).timeout(const Duration(seconds: 5));
      
      final results = await Future.wait([adminResFuture, storageResFuture]);
      final adminRes = results[0];
      final storageRes = results[1];

      if (adminRes.statusCode == 200 && storageRes.statusCode == 200) {
        final adminData = json.decode(adminRes.body)['devices'] as List;
        final storageData = json.decode(storageRes.body)['devices'] as List;

        final Map<String, int> portMap = {};
        for (var s in storageData) {
          portMap[s['client_id']] = s['file_server_port'] ?? 0;
        }

        _devices = adminData.map((d) {
          final id = (d['client_id'] ?? 'unknown').toString();
          return NetworkDevice(
            id: id,
            name: (d['name'] ?? 'Unknown').toString(),
            type: (d['type'] ?? 'desktop').toString(),
            ip: (d['ip'] ?? '0.0.0.0').toString(),
            isOnline: d['online'] == true,
            isSameLan: NetworkDevice.isSameSubnet(_myIp, (d['ip'] ?? '0.0.0.0').toString()),
            fileServerPort: portMap[id] ?? 0,
            lastSeenAgo: d['last_seen_ago'] ?? 0,
            transfersSent: d['transfers_sent'] ?? 0,
            transfersReceived: d['transfers_received'] ?? 0,
            clipboardEntries: d['clipboard_entries'] ?? 0,
          );
        }).toList();

        notifyListeners(); // Sagt der ganzen App bescheid!
      }
    } catch (e) {
      // Bei Verbindungsabbruch alten Cache behalten, kein Absturz!
    }
  }

  NetworkDevice? getDeviceById(String id) {
    try { return _devices.firstWhere((d) => d.id == id); } catch (_) { return null; }
  }
}