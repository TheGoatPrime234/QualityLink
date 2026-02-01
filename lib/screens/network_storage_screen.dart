import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;

import '../config/server_config.dart';
import '../services/heartbeat_service.dart';
import '../services/datalink_service.dart';

// =============================================================================
// NETWORK STORAGE SCREEN - Browse files on other devices
// =============================================================================

class NetworkStorageScreen extends StatefulWidget {
  const NetworkStorageScreen({super.key});

  @override
  State<NetworkStorageScreen> createState() => _NetworkStorageScreenState();
}

class _NetworkStorageScreenState extends State<NetworkStorageScreen> {
  List<dynamic> _devices = [];
  bool _loading = true;
  bool _isConnected = false;
  Timer? _refreshTimer;
  
  final HeartbeatService _heartbeatService = HeartbeatService();

  @override
  void initState() {
    super.initState();
    
    // Registriere Listener für Connection-Status
    _heartbeatService.addConnectionListener(_onConnectionChanged);
    
    // Registriere Listener für Peer-Updates
    _heartbeatService.addPeerListener(_onPeersUpdated);
    
    // Initiales Laden
    _loadDevices();
    
    // Optimiert: Nur alle 5 Sekunden refreshen (HeartbeatService macht den Rest)
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (t) => _loadDevices());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    // Listener werden beim Dispose des Services aufgeräumt
    super.dispose();
  }

  /// Callback wenn sich der Connection-Status ändert
  void _onConnectionChanged(bool isConnected) {
    if (mounted) {
      setState(() {
        _isConnected = isConnected;
      });
      
      if (isConnected) {
        _showSnack("✅ Connected to server", isError: false);
        _loadDevices(); // Devices neu laden wenn wieder verbunden
      } else {
        _showSnack("❌ Disconnected from server", isError: true);
      }
    }
  }

  /// Callback wenn sich die Peer-Liste aktualisiert
  void _onPeersUpdated(List<dynamic> peers) {
    // Peers werden automatisch geladen durch _loadDevices()
    // Dieser Callback kann für zusätzliche Logik genutzt werden
    print("📱 Peers updated: ${peers.length} devices");
  }

  Future<void> _loadDevices() async {
    try {
      final response = await http.get(Uri.parse('$serverBaseUrl/storage/devices'))
          .timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200 && mounted) {
        final data = json.decode(response.body);
        setState(() {
          _devices = data['devices'] ?? [];
          _loading = false;
        });
      } else {
        throw Exception("Server returned ${response.statusCode}");
      }
    } catch (e) {
      print("❌ Error loading devices: $e");
      if (mounted) {
        setState(() {
          _loading = false;
          if (_devices.isEmpty) {
            // Nur als Fehler anzeigen wenn wir keine Devices haben
            _isConnected = false;
          }
        });
      }
    }
  }

  void _openDevice(Map<String, dynamic> device) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FileBrowserScreen(device: device),
      ),
    );
  }

  IconData _getDeviceIcon(String type) {
    switch (type.toLowerCase()) {
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'windows':
        return Icons.computer;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.desktop_mac;
      default:
        return Icons.devices;
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError 
              ? Colors.red 
              : const Color(0xFF00FF41).withValues(alpha: 0.3),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Row(
          children: [
            const Text("NETWORK STORAGE"),
            const SizedBox(width: 12),
            // Connection Status Indicator
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: _isConnected ? const Color(0xFF00FF41) : Colors.red,
                shape: BoxShape.circle,
                boxShadow: _isConnected 
                    ? [
                        BoxShadow(
                          color: const Color(0xFF00FF41).withValues(alpha: 0.5),
                          blurRadius: 8,
                          spreadRadius: 2,
                        )
                      ]
                    : null,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.transparent,
        actions: [
          // Debug Info Button
          IconButton(
            icon: const Icon(Icons.info_outline, size: 20),
            onPressed: _showDebugInfo,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              setState(() => _loading = true);
              // Force Heartbeat um sofortige Synchronisation zu triggern
              await _heartbeatService.forceHeartbeat();
              await _loadDevices();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00FF41)))
          : _devices.isEmpty
              ? _buildEmptyState()
              : _buildDeviceList(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.devices_other, size: 64, color: Colors.grey.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(
            _isConnected 
                ? "No devices with storage found"
                : "Not connected to server",
            style: const TextStyle(color: Colors.grey, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            _isConnected 
                ? "Make sure other devices are online and have file sharing enabled"
                : "Waiting for connection...",
            style: const TextStyle(color: Colors.grey, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          if (!_isConnected) ...[
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () async {
                setState(() => _loading = true);
                await _heartbeatService.forceHeartbeat();
                await _loadDevices();
              },
              icon: const Icon(Icons.refresh),
              label: const Text("Retry Connection"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00FF41),
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _devices.length,
      itemBuilder: (context, index) {
        final device = _devices[index];
        final isOnline = device['online'] == true;
        final hasFileServer = device['file_server_port'] != null && device['file_server_port'] > 0;
        
        return GestureDetector(
          onTap: (isOnline && hasFileServer) ? () => _openDevice(device) : null,
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF111111),
              border: Border(
                left: BorderSide(
                  color: (isOnline && hasFileServer) 
                      ? const Color(0xFF00FF41) 
                      : Colors.grey,
                  width: 4,
                ),
              ),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _getDeviceIcon(device['type'] ?? 'unknown'),
                  color: (isOnline && hasFileServer) 
                      ? const Color(0xFF00FF41) 
                      : Colors.grey,
                  size: 32,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device['name'] ?? 'Unknown Device',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "${device['ip'] ?? 'N/A'} • ${device['type'] ?? 'unknown'}",
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (hasFileServer) ...[
                            Icon(
                              Icons.folder_shared,
                              size: 12,
                              color: const Color(0xFF00FF41).withValues(alpha: 0.7),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              "${(device['available_paths'] as List?)?.length ?? 0} storage location(s)",
                              style: TextStyle(
                                color: const Color(0xFF00FF41).withValues(alpha: 0.7),
                                fontSize: 11,
                              ),
                            ),
                          ] else ...[
                            Icon(
                              Icons.folder_off,
                              size: 12,
                              color: Colors.grey.withValues(alpha: 0.5),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              "File sharing not available",
                              style: TextStyle(
                                color: Colors.grey.withValues(alpha: 0.5),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(
                  (isOnline && hasFileServer) 
                      ? Icons.chevron_right 
                      : Icons.cloud_off,
                  color: Colors.grey,
                  size: 24,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showDebugInfo() {
    final debugInfo = _heartbeatService.getDebugInfo();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text("Debug Info", style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDebugRow("Service Running", debugInfo['isRunning'].toString()),
              _buildDebugRow("Connected", debugInfo['isConnected'].toString()),
              _buildDebugRow("Client ID", debugInfo['clientId'] ?? 'N/A'),
              _buildDebugRow("Device Name", debugInfo['deviceName'] ?? 'N/A'),
              _buildDebugRow("Local IP", debugInfo['localIp'] ?? 'N/A'),
              _buildDebugRow("File Server Port", debugInfo['fileServerPort']?.toString() ?? 'N/A'),
              _buildDebugRow("Heartbeat Interval", "${debugInfo['heartbeatInterval']}s"),
              const Divider(color: Colors.grey),
              _buildDebugRow("Devices Found", _devices.length.toString()),
              _buildDebugRow("Server URL", serverBaseUrl),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close", style: TextStyle(color: Color(0xFF00FF41))),
          ),
        ],
      ),
    );
  }

  Widget _buildDebugRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
// =============================================================================
// FILE BROWSER SCREEN - Browse specific device
// =============================================================================

// ✅ NEU: Enum für Sortier-Optionen
enum FileSortOption { name, date, size, type }

class FileBrowserScreen extends StatefulWidget {
  final Map<String, dynamic> device;
  
  const FileBrowserScreen({super.key, required this.device});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  final DataLinkService _datalink = DataLinkService();
  
  List<dynamic> _files = [];
  bool _loading = true;
  String _currentPath = "";
  final List<String> _pathHistory = [];

  // ✅ NEU: Sortier-Status
  FileSortOption _currentSort = FileSortOption.name;
  bool _sortAscending = true;
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _originalFiles = [];
  bool _isMultiSelectMode = false;
  final Set<String> _selectedPaths = {};

  @override
  void initState() {
    super.initState();
    _loadRootPaths();
  }

  IconData _getDeviceIcon(String type) {
    switch (type.toLowerCase()) {
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'windows':
        return Icons.computer;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.desktop_mac;
      default:
        return Icons.devices;
    }
  }

  // ✅ NEU: Zentrale Sortier-Methode
  void _applySort() {
    setState(() {
      _files.sort((a, b) {
        // 1. Regel: Ordner immer zuerst
        if (a['is_directory'] != b['is_directory']) {
          return a['is_directory'] ? -1 : 1;
        }

        // 2. Regel: Gewählte Sortierung
        int result = 0;
        switch (_currentSort) {
          case FileSortOption.name:
            result = (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase());
            break;
          case FileSortOption.date:
            result = (a['modified'] as int).compareTo(b['modified'] as int);
            break;
          case FileSortOption.size:
            result = (a['size'] as int).compareTo(b['size'] as int);
            break;
          case FileSortOption.type:
            // Bei Typ erst nach Typ sortieren, dann nach Namen
            final typeA = a['type'] as String;
            final typeB = b['type'] as String;
            result = typeA.compareTo(typeB);
            if (result == 0) {
              result = (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase());
            }
            break;
        }

        // 3. Regel: Richtung (Ascending/Descending)
        return _sortAscending ? result : -result;
      });
    });
  }

  // ✅ NEU: Mini-Browser für das Zielgerät
  Future<String?> _showRemoteFolderPicker(Map<String, dynamic> targetDevice) async {
    String currentPath = "Root"; // Start im Root des Zielgeräts
    List<dynamic> folders = [];
    bool loading = true;
    
    // Hilfsfunktion zum Laden der Ordner des ZIEL-Geräts
    Future<void> loadTargetFolders(StateSetter setState, String path) async {
      setState(() => loading = true);
      try {
        final ip = targetDevice['ip'];
        final port = targetDevice['file_server_port'];
        
        // Wenn Root, verfügbare Pfade laden, sonst Ordnerinhalt
        String url;
        if (path == "Root") {
          url = 'http://$ip:$port/files/paths'; // Endpoint muss existieren (haben wir in file_server_service)
        } else {
          url = 'http://$ip:$port/files/list?path=${Uri.encodeComponent(path)}';
        }

        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
        
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          List<dynamic> items;
          
          if (path == "Root") {
             // Root Pfade normalisieren
             final paths = List<String>.from(data['paths'] ?? []);
             items = paths.map((pathStr) => {
               "name": p.basename(pathStr), // Jetzt nutzt 'p' das Paket und 'pathStr' den String
               "path": pathStr,
               "is_directory": true,
             }).toList();
          } else {
             // Nur Ordner filtern
             final allFiles = List<dynamic>.from(data['files'] ?? []);
             items = allFiles.where((f) => f['is_directory'] == true).toList();
          }

          setState(() {
            folders = items;
            currentPath = path;
            loading = false;
          });
        }
      } catch (e) {
        print("Folder picker error: $e");
        setState(() => loading = false);
      }
    }

    // Dialog anzeigen
    return await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          // Initial laden
          if (loading && folders.isEmpty && currentPath == "Root") {
            loadTargetFolders(setState, "Root");
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Select Destination", style: TextStyle(color: Colors.white, fontSize: 16)),
                Text(
                  targetDevice['name'], 
                  style: const TextStyle(color: Color(0xFF00FF41), fontSize: 12)
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 300,
              child: Column(
                children: [
                  // Pfad Header mit Back Button
                  Container(
                    padding: const EdgeInsets.only(bottom: 8),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Colors.grey, width: 0.5)),
                    ),
                    child: Row(
                      children: [
                        if (currentPath != "Root")
                          IconButton(
                            icon: const Icon(Icons.arrow_upward, size: 16, color: Colors.grey),
                            onPressed: () {
                              // Einfache Parent-Logik
                              final parent = Directory(currentPath).parent.path;
                              // Wenn wir nicht mehr in den erlaubten Pfaden sind -> Root
                              // Einfachheitshalber: Wenn Parent gleich Current -> Root
                              if (parent == currentPath) {
                                loadTargetFolders(setState, "Root");
                              } else {
                                loadTargetFolders(setState, parent);
                              }
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            currentPath == "Root" ? "Root Folders" : p.basename(currentPath),
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  // Ordner Liste
                  Expanded(
                    child: loading
                        ? const Center(child: CircularProgressIndicator(color: Color(0xFF00FF41)))
                        : folders.isEmpty
                            ? const Center(child: Text("No folders", style: TextStyle(color: Colors.grey)))
                            : ListView.builder(
                                shrinkWrap: true,
                                itemCount: folders.length,
                                itemBuilder: (context, index) {
                                  final folder = folders[index];
                                  return ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.folder, color: Color(0xFF00E5FF)),
                                    title: Text(folder['name'], style: const TextStyle(color: Colors.white)),
                                    onTap: () => loadTargetFolders(setState, folder['path']),
                                  );
                                },
                              ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context), // Abbrechen
                child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
              ),
              if (currentPath != "Root") // Nur erlauben wenn nicht Root-Auswahl
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, currentPath), // Pfad zurückgeben
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00FF41)),
                  child: const Text("Select Here", style: TextStyle(color: Colors.black)),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showDevicePickerAndSend({String? singlePath, bool selectDestination = false}) async {
    final pathsToSend = singlePath != null ? [singlePath] : _selectedPaths.toList();
    if (pathsToSend.isEmpty) return;

    List<dynamic> targets = [];
    bool loading = true;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          if (loading && targets.isEmpty) {
             http.get(Uri.parse('$serverBaseUrl/storage/devices')).then((response) {
               if (response.statusCode == 200 && mounted) {
                 final data = json.decode(response.body);
                 final allDevices = List<dynamic>.from(data['devices'] ?? []);
                 setState(() {
                   targets = allDevices.where((d) => 
                     d['client_id'] != widget.device['client_id'] && 
                     d['online'] == true
                   ).toList();
                   loading = false;
                 });
               }
             });
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: Text(
              selectDestination ? "Select Target & Folder" : "Send to Device", 
              style: const TextStyle(color: Colors.white)
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: loading 
                  ? const LinearProgressIndicator(color: Color(0xFF00FF41))
                  : targets.isEmpty
                      ? const Text("No other online devices.", style: TextStyle(color: Colors.grey))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: targets.length,
                          itemBuilder: (context, index) {
                            final device = targets[index];
                            return ListTile(
                              leading: Icon(_getDeviceIcon(device['type']), color: Colors.white),
                              title: Text(device['name'], style: const TextStyle(color: Colors.white)),
                              subtitle: Text(device['ip'], style: const TextStyle(color: Colors.grey, fontSize: 12)),
                              onTap: () async {
                                Navigator.pop(context); // Geräte-Dialog zu
                                
                                String? destPath;
                                if (selectDestination) {
                                  // ✅ Folder Picker öffnen!
                                  destPath = await _showRemoteFolderPicker(device);
                                  if (destPath == null) return; // Abgebrochen
                                }
                                
                                _triggerRemoteSend(pathsToSend, device, destinationPath: destPath);
                              },
                            );
                          },
                        ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _triggerRemoteSend(
    List<String> paths, 
    Map<String, dynamic> targetDevice, 
    {String? destinationPath} // ✅ Optionaler Parameter
  ) async {
    _showSnack("🚀 Initiating transfer to ${targetDevice['name']}...");
    
    if (_isMultiSelectMode) _exitMultiSelectMode();

    final ip = widget.device['ip'];
    final port = widget.device['file_server_port'];
    final targetId = targetDevice['client_id'];

    int successCount = 0;

    for (var path in paths) {
      try {
        final Map<String, dynamic> body = {
          "path": path,
          "targets": [targetId]
        };
        
        // ✅ Zielpfad hinzufügen
        if (destinationPath != null) {
          body['destination_path'] = destinationPath;
        }

        final response = await http.post(
          Uri.parse('http://$ip:$port/files/share'),
          headers: {"Content-Type": "application/json"},
          body: json.encode(body),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) successCount++;
      } catch (e) {
        print("Failed to share $path: $e");
      }
    }
    // ... (Rest bleibt gleich)
  }

  Future<void> _loadRootPaths() async {
    setState(() {
      _loading = true;
      _currentPath = "Root";
    });
    
    final paths = List<String>.from(widget.device['available_paths'] ?? []);
    
    setState(() {
      _files = paths.map((path) => {
        "name": p.basename(path),
        "path": path,
        "is_directory": true,
        "size": 0,
        "type": "folder",
        "modified": DateTime.now().millisecondsSinceEpoch,
      }).toList();
      _loading = false;
      
      _applySort(); // ✅ Sofort sortieren
    });
  }

  Future<void> _loadPath(String path) async {
    setState(() => _loading = true);
    
    try {
      final ip = widget.device['ip'];
      final port = widget.device['file_server_port'];
      
      if (ip == null || port == null) {
        throw Exception("Device IP or port not available");
      }

      final url = Uri.parse('http://$ip:$port/files/list?path=${Uri.encodeComponent(path)}');
      
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final files = List<dynamic>.from(data['files'] ?? []);
        
        if (mounted) {
          setState(() {
            _files = files;
            _currentPath = path;
            _loading = false;
            
            _applySort(); // ✅ Dateien sortiert anzeigen
          });
        }
      } else if (response.statusCode == 403) {
        throw Exception("Access denied");
      } else if (response.statusCode == 404) {
        throw Exception("Directory not found");
      } else {
        throw Exception("Server error: ${response.statusCode}");
      }
    } catch (e) {
      print("❌ Error loading path: $e");
      if (mounted) {
        _showError("Failed to load directory: $e");
        setState(() => _loading = false);
      }
    }
  }

  void _openItem(Map<String, dynamic> file) {
    if (file['is_directory'] == true) {
      _pathHistory.add(_currentPath);
      _loadPath(file['path']);
    } else {
      _showFileDetails(file);
    }
  }

  void _downloadFile(Map<String, dynamic> file) {
    final ip = widget.device['ip'];
    final port = widget.device['file_server_port'];
    
    if (ip == null || port == null) {
      _showSnack("Invalid device configuration", isError: true);
      return;
    }

    final url = 'http://$ip:$port/files/download?path=${Uri.encodeComponent(file['path'])}';
    
    _datalink.startDirectDownload(
      fileName: file['name'],
      fileSize: file['size'],
      url: url,
      senderId: widget.device['client_id'] ?? "Unknown",
    );

    _showSnack("⬇️ Download started: ${file['name']}");
  }

  // ✅ NEU: Führt die Suche aus
  Future<void> _performSearch(String query) async {
    if (query.isEmpty) return;

    setState(() => _loading = true);

    try {
      final ip = widget.device['ip'];
      final port = widget.device['file_server_port'];
      
      // Nutzt den neuen Search Endpoint
      final url = Uri.parse(
        'http://$ip:$port/files/search?path=${Uri.encodeComponent(_currentPath == "Root" ? widget.device['available_paths'][0] : _currentPath)}&query=${Uri.encodeComponent(query)}'
      );
      
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = List<dynamic>.from(data['files'] ?? []);
        
        setState(() {
          _files = results; // Überschreibe Liste mit Ergebnissen
          _loading = false;
        });
      } else {
        throw Exception("Search failed");
      }
    } catch (e) {
      _showSnack("Search failed: $e", isError: true);
      setState(() => _loading = false);
    }
  }

  // ✅ NEU: Beendet Suche und stellt Ordner wieder her
  void _stopSearch() {
    setState(() {
      _isSearching = false;
      _searchController.clear();
      // Wenn wir im Root waren, lade Root neu, sonst den Pfad
      if (_currentPath == "Root") {
        _loadRootPaths();
      } else {
        _loadPath(_currentPath);
      }
    });
  }
  
  Future<void> _uploadFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return;

    final file = File(result.files.single.path!);
    final targetId = widget.device['client_id'];

    if (targetId == null) {
      _showSnack("Target ID not found", isError: true);
      return;
    }

    _showSnack("📤 Preparing upload to $_currentPath...");

    try {
      await _datalink.sendFile(
        file, 
        [targetId], 
        destinationPath: _currentPath
      );
    } catch (e) {
      _showSnack("Upload failed: $e", isError: true);
    }
  }

  

  void _showFileDetails(Map<String, dynamic> file) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(file['name'], style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow("Type", file['type'].toString().toUpperCase()),
            _buildDetailRow("Size", _formatSize(file['size'] ?? 0)),
            _buildDetailRow("Modified", _formatDate(file['modified'] ?? 0)),
          ],
        ),
        actions: [
          // ✅ NEU: Delete Button (Rot)
          TextButton.icon(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            label: const Text("Delete", style: TextStyle(color: Colors.red)),
            onPressed: () {
              Navigator.pop(context); // Dialog schließen
              _deleteItem(file);      // Lösch-Dialog öffnen
            },
          ),
          const Spacer(), // Schiebt Download & Close nach rechts
          GestureDetector( // Wrap mit GestureDetector für LongPress
            onLongPress: () {
              Navigator.pop(context);
              // ✅ Mit Folder Picker starten
              _showDevicePickerAndSend(singlePath: file['path'], selectDestination: true);
            },
            child: TextButton.icon(
              icon: const Icon(Icons.send, color: Color(0xFF00E5FF)),
              label: const Text("Send", style: TextStyle(color: Color(0xFF00E5FF))),
              onPressed: () {
                Navigator.pop(context);
                // Normales Senden (ohne Picker)
                _showDevicePickerAndSend(singlePath: file['path']);
              },
            ),
          ),
          TextButton.icon(
             icon: const Icon(Icons.download, color: Color(0xFF00FF41)),
             label: const Text("Download", style: TextStyle(color: Color(0xFF00FF41))),
             onPressed: () {
               Navigator.pop(context);
               _downloadFile(file);
             },
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close", style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  // ✅ NEU: Lösch-Funktion mit Sicherheitsabfrage
  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final isFolder = item['is_directory'] == true;
    final name = item['name'];

    // 1. Bestätigungs-Dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text("Delete $name?", style: const TextStyle(color: Colors.white)),
        content: Text(
          isFolder 
              ? "Are you sure you want to delete this folder and all its contents?\nThis cannot be undone."
              : "Are you sure you want to delete this file?\nThis cannot be undone.",
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Delete", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // 2. Lösch-Request an Server
    setState(() => _loading = true);
    
    try {
      final ip = widget.device['ip'];
      final port = widget.device['file_server_port'];
      
      // Request senden (DELETE Method)
      final url = Uri.parse('http://$ip:$port/files/delete?path=${Uri.encodeComponent(item['path'])}');
      final response = await http.delete(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        _showSnack("🗑️ Deleted $name");
        
        // Liste neu laden
        if (_isSearching) {
          _performSearch(_searchController.text);
        } else {
          _loadPath(_currentPath);
        }
      } else {
        throw Exception("Server error ${response.statusCode}");
      }
    } catch (e) {
      _showSnack("Failed to delete: $e", isError: true);
      setState(() => _loading = false);
    }
  }

  // ✅ NEU: Auswahl umschalten
  void _toggleSelection(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
        if (_selectedPaths.isEmpty) {
          _isMultiSelectMode = false;
        }
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  // ✅ NEU: Alles auswählen / abwählen
  void _toggleSelectAll() {
    setState(() {
      if (_selectedPaths.length == _files.length) {
        _selectedPaths.clear();
        _isMultiSelectMode = false;
      } else {
        _selectedPaths.clear();
        for (var file in _files) {
          _selectedPaths.add(file['path']);
        }
      }
    });
  }

  // ✅ NEU: Modus beenden
  void _exitMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = false;
      _selectedPaths.clear();
    });
  }

  // ✅ NEU: Batch Download
  void _downloadSelected() {
    int count = 0;
    for (var file in _files) {
      if (_selectedPaths.contains(file['path']) && file['is_directory'] == false) {
        _downloadFile(file); // Existierende Methode nutzen
        count++;
      }
    }
    _showSnack("⬇️ Started $count downloads");
    _exitMultiSelectMode();
  }

  // ✅ NEU: Dialog um Zielgerät zu wählen und Senden anzustoßen

  // ✅ NEU: Batch Delete
  Future<void> _deleteSelected() async {
    final count = _selectedPaths.length;
    
    // Sicherheitsabfrage
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text("Delete $count items?", style: const TextStyle(color: Colors.white)),
        content: const Text(
          "This action cannot be undone.",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Delete", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _loading = true);
    
    // Löschen
    int successCount = 0;
    final ip = widget.device['ip'];
    final port = widget.device['file_server_port'];

    // Wir erstellen eine Kopie der Liste, da wir während der Iteration UI updaten wollen
    final pathsToDelete = List<String>.from(_selectedPaths);

    for (var path in pathsToDelete) {
      try {
        final url = Uri.parse('http://$ip:$port/files/delete?path=${Uri.encodeComponent(path)}');
        final response = await http.delete(url).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          successCount++;
        }
      } catch (e) {
        print("Failed to delete $path: $e");
      }
    }

    _showSnack("🗑️ Deleted $successCount / $count items");
    _exitMultiSelectMode();
    
    // Neu laden
    if (_currentPath == "Root") _loadRootPaths();
    else _loadPath(_currentPath);
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }

  IconData _getFileIcon(String type) {
    switch (type) {
      case 'folder': return Icons.folder;
      case 'image': return Icons.image;
      case 'video': return Icons.videocam;
      case 'audio': return Icons.audiotrack;
      case 'pdf': return Icons.picture_as_pdf;
      case 'document': return Icons.description;
      case 'archive': return Icons.archive;
      case 'apk': return Icons.android;
      case 'executable': return Icons.settings_applications;
      default: return Icons.insert_drive_file;
    }
  }

  Color _getFileColor(String type) {
    switch (type) {
      case 'folder': return const Color(0xFF00E5FF);
      case 'image': return Colors.purple;
      case 'video': return Colors.red;
      case 'audio': return Colors.orange;
      case 'pdf': return Colors.red;
      case 'document': return Colors.blue;
      case 'archive': return Colors.yellow;
      default: return Colors.grey;
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / 1024 / 1024).toStringAsFixed(1)} MB";
    return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }

  String _formatDate(int timestamp) {
    if (timestamp == 0) return "Unknown";
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final diff = now.difference(date);
    
    if (diff.inDays == 0) return "${date.hour}:${date.minute.toString().padLeft(2, '0')}";
    if (diff.inDays == 1) return "Yesterday";
    return "${date.day}.${date.month}.${date.year}";
  }

  void _showError(String message) {
    _showSnack(message, isError: true);
  }

  void _showSnack(String message, {bool isError = false}) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Colors.red : const Color(0xFF00FF41).withValues(alpha: 0.3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: _isMultiSelectMode 
            ? const Color(0xFF00FF41).withValues(alpha: 0.1) // Grüner Schimmer im Select Mode
            : const Color(0xFF050505),
        elevation: 0,
        
        // LEADING: Back oder Close (X)
        leading: IconButton(
          icon: Icon(
            _isMultiSelectMode || _isSearching ? Icons.close : Icons.arrow_back,
            color: Colors.white
          ),
          onPressed: () {
            if (_isMultiSelectMode) {
              _exitMultiSelectMode();
            } else if (_isSearching) {
              _stopSearch();
            } else if (_pathHistory.isEmpty) {
              Navigator.pop(context);
            } else {
              final prev = _pathHistory.removeLast();
              if (prev == "Root") _loadRootPaths();
              else _loadPath(prev);
            }
          },
        ),

        // TITLE: Suchfeld, Counter oder Pfad
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: "Search files...",
                  hintStyle: TextStyle(color: Colors.grey),
                  border: InputBorder.none,
                ),
                onSubmitted: _performSearch,
              )
            : _isMultiSelectMode
                ? Text(
                    "${_selectedPaths.length} Selected",
                    style: const TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.device['name'] ?? 'Unknown', style: const TextStyle(fontSize: 14)),
                      Text(_currentPath, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    ],
                  ),

        // ACTIONS: Menu, Select All, etc.
        actions: [
          if (_isMultiSelectMode) ...[
            // Select All Button
            IconButton(
              icon: Icon(
                _selectedPaths.length == _files.length 
                    ? Icons.library_add_check 
                    : Icons.check_box_outline_blank,
                color: Colors.white,
              ),
              tooltip: "Select All",
              onPressed: _toggleSelectAll,
            ),
            // ✅ DAS 3-PUNKTE MENU FÜR MULTI-SELECT
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              onSelected: (value) {
                  if (value == 'download') _downloadSelected();
                  if (value == 'delete') _deleteSelected();
                  if (value == 'share') _showDevicePickerAndSend();
                  if (value == 'share_custom') _showDevicePickerAndSend(selectDestination: true); // ✅
                },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'download',
                  child: Row(
                    children: [
                      Icon(Icons.download, color: Color(0xFF00FF41)),
                      SizedBox(width: 12),
                      Text("Download Selected"),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'share',
                  child: Row(
                    children: [
                      Icon(Icons.send, color: Color(0xFF00E5FF)),
                      SizedBox(width: 12),
                      Text("Send to Device"),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete, color: Colors.red),
                      SizedBox(width: 12),
                      Text("Delete Selected", style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'share_custom', // Neuer Value
                  child: Row(
                    children: [
                      Icon(Icons.drive_file_move, color: Color(0xFF00E5FF)), // Anderes Icon
                      SizedBox(width: 12),
                      Text("Send to Folder..."),
                    ],
                  ),
                ),
              ],
            ),
          ] else if (!_isSearching) ...[
            // Normale Buttons (Suche, Sortierung)
            IconButton(
              icon: const Icon(Icons.search, color: Color(0xFF00FF41)),
              onPressed: () => setState(() => _isSearching = true),
            ),
            PopupMenuButton<FileSortOption>(
               // ... (Dein existierender Sort Code bleibt hier gleich) ...
               icon: const Icon(Icons.sort, color: Color(0xFF00FF41)),
               onSelected: (FileSortOption result) {
                 if (_currentSort == result) {
                    setState(() {
                      _sortAscending = !_sortAscending;
                      _applySort();
                    });
                  } else {
                    setState(() {
                      _currentSort = result;
                      _sortAscending = true;
                      _applySort();
                    });
                  }
               },
               itemBuilder: (BuildContext context) => <PopupMenuEntry<FileSortOption>>[
                  _buildSortItem(FileSortOption.name, "Name", Icons.sort_by_alpha),
                  _buildSortItem(FileSortOption.date, "Date", Icons.access_time),
                  _buildSortItem(FileSortOption.size, "Size", Icons.data_usage),
                  _buildSortItem(FileSortOption.type, "Type", Icons.category),
               ],
            ),
          ],
        ],
      ),
      
      floatingActionButton: _currentPath != "Root" ? FloatingActionButton(
        backgroundColor: const Color(0xFF00FF41),
        onPressed: _uploadFile,
        child: const Icon(Icons.upload, color: Colors.black),
      ) : null,
      
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00FF41)))
          : _files.isEmpty
              ? const Center(child: Text("Empty folder", style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                final file = _files[index];
                final isDirectory = file['is_directory'] ?? false;
                final isSelected = _selectedPaths.contains(file['path']); // Check Status
                
                return GestureDetector(
                  // ✅ LOGIK:
                  // Normal: Tap -> Öffnen/Details, LongPress -> MultiSelect Start
                  // MultiSelect: Tap -> Toggle Selection, LongPress -> Toggle Selection
                  onTap: () {
                    if (_isMultiSelectMode) {
                      _toggleSelection(file['path']);
                    } else {
                      isDirectory ? _openItem(file) : _showFileDetails(file);
                    }
                  },
                  onLongPress: () {
                    if (!_isMultiSelectMode) {
                      setState(() => _isMultiSelectMode = true);
                    }
                    _toggleSelection(file['path']);
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      // ✅ Farbe ändert sich bei Auswahl
                      color: isSelected 
                          ? const Color(0xFF00FF41).withValues(alpha: 0.1) 
                          : const Color(0xFF111111),
                      border: Border(
                        left: BorderSide(
                          // ✅ Rand wird grün bei Auswahl
                          color: isSelected 
                              ? const Color(0xFF00FF41) 
                              : _getFileColor(file['type'] ?? 'file'),
                          width: 3,
                        ),
                      ),
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(4),
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                    child: Row(
                      children: [
                        // ✅ Icon ändert sich zu Checkbox im Select Mode
                        if (_isMultiSelectMode)
                          Icon(
                            isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                            color: isSelected ? const Color(0xFF00FF41) : Colors.grey,
                            size: 28,
                          )
                        else
                          Icon(
                            _getFileIcon(file['type'] ?? 'file'),
                            color: _getFileColor(file['type'] ?? 'file'),
                            size: 28,
                          ),
                          
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                file['name'] ?? 'Unknown',
                                style: TextStyle(
                                  color: isSelected ? const Color(0xFF00FF41) : Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (!isDirectory) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Text(
                                      _formatSize(file['size'] ?? 0),
                                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      "• ${_formatDate(file['modified'] ?? 0)}",
                                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        
                        // ✅ Buttons rechts ausblenden im MultiSelect Mode
                        if (!_isMultiSelectMode) ...[
                          Icon(
                            isDirectory ? Icons.chevron_right : Icons.more_vert,
                            color: Colors.grey,
                            size: 20,
                          ),
                          IconButton(
                            icon: Icon(
                              isDirectory ? Icons.chevron_right : Icons.download,
                              color: isDirectory ? Colors.grey : const Color(0xFF00FF41),
                            ),
                            onPressed: () {
                              if (isDirectory) {
                                _openItem(file);
                              } else {
                                _downloadFile(file);
                              }
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
                ),
    );
  }

  // Helper für Sortier-Items
  PopupMenuItem<FileSortOption> _buildSortItem(FileSortOption option, String label, IconData icon) {
    final isSelected = _currentSort == option;
    return PopupMenuItem<FileSortOption>(
      value: option,
      child: Row(
        children: [
          Icon(
            icon, 
            color: isSelected ? const Color(0xFF00FF41) : Colors.grey,
            size: 20,
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? const Color(0xFF00FF41) : Colors.white,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if (isSelected) ...[
            const Spacer(),
            Icon(
              _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
              color: const Color(0xFF00FF41),
              size: 16,
            ),
          ],
        ],
      ),
    );
  }
}