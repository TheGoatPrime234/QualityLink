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
  List<dynamic> _originalFiles = []; // Backup für die Ordner-Ansicht

  @override
  void initState() {
    super.initState();
    _loadRootPaths();
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
        backgroundColor: const Color(0xFF050505),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            // ✅ Logik für Back-Button angepasst
            if (_isSearching) {
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
        // ✅ Dynamischer Titel: Entweder Pfad oder Suchfeld
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
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.device['name'] ?? 'Unknown', style: const TextStyle(fontSize: 14)),
                  Text(_currentPath, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ),
        actions: [
          // ✅ Search Toggle Button
          if (!_isSearching)
            IconButton(
              icon: const Icon(Icons.search, color: Color(0xFF00FF41)),
              onPressed: () {
                setState(() {
                  _isSearching = true;
                  // Backup machen nicht nötig, da wir bei stopSearch eh neu laden
                });
              },
            )
          else
            IconButton(
              icon: const Icon(Icons.close, color: Colors.red),
              onPressed: _stopSearch,
            ),

          // Sort Menu (nur anzeigen wenn nicht gesucht wird)
          if (!_isSearching)
            PopupMenuButton<FileSortOption>(
              // ... (Dein existierender Sort Code) ...
              icon: const Icon(Icons.sort, color: Color(0xFF00FF41)),
               onSelected: (FileSortOption result) {
                 // ... dein bestehender Code ...
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
               // ... item builder ...
               itemBuilder: (BuildContext context) => <PopupMenuEntry<FileSortOption>>[
                  _buildSortItem(FileSortOption.name, "Name", Icons.sort_by_alpha),
                  _buildSortItem(FileSortOption.date, "Date", Icons.access_time),
                  _buildSortItem(FileSortOption.size, "Size", Icons.data_usage),
                  _buildSortItem(FileSortOption.type, "Type", Icons.category),
               ],
            ),
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
                    
                    return GestureDetector(
                      onTap: () => isDirectory ? _openItem(file) : _showFileDetails(file),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111111),
                          border: Border(
                            left: BorderSide(
                              color: _getFileColor(file['type'] ?? 'file'),
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
                                    style: const TextStyle(
                                      color: Colors.white,
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
                            Icon(
                              isDirectory ? Icons.chevron_right : Icons.more_vert,
                              color: Colors.grey,
                              size: 20,
                            ),
                            // Quick Action Button
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