import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;

import '../config/server_config.dart';

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
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadDevices();
    // ✅ Optimiert: Nur alle 5 Sekunden refreshen (HeartbeatService macht den Rest)
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (t) => _loadDevices());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    try {
      final response = await http.get(Uri.parse('$serverBaseUrl/storage/devices'));
      
      if (response.statusCode == 200 && mounted) {
        final data = json.decode(response.body);
        setState(() {
          _devices = data['devices'];
          _loading = false;
        });
      }
    } catch (e) {
      print("❌ Error loading devices: $e");
      if (mounted) setState(() => _loading = false);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("NETWORK STORAGE"),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadDevices,
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
          Icon(Icons.devices_other, size: 64, color: Colors.grey.withOpacity(0.3)),
          const SizedBox(height: 16),
          const Text(
            "No devices with storage found",
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text(
            "Make sure other devices are online",
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
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
        
        return GestureDetector(
          onTap: isOnline ? () => _openDevice(device) : null,
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF111111),
              border: Border(
                left: BorderSide(
                  color: isOnline ? const Color(0xFF00FF41) : Colors.grey,
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
                  _getDeviceIcon(device['type']),
                  color: isOnline ? const Color(0xFF00FF41) : Colors.grey,
                  size: 32,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device['name'],
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "${device['ip']} • ${device['type']}",
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "${device['available_paths'].length} storage location(s)",
                        style: TextStyle(
                          color: const Color(0xFF00FF41).withOpacity(0.7),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  isOnline ? Icons.chevron_right : Icons.cloud_off,
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
}

// =============================================================================
// FILE BROWSER SCREEN - Browse specific device
// =============================================================================

class FileBrowserScreen extends StatefulWidget {
  final Map<String, dynamic> device;
  
  const FileBrowserScreen({super.key, required this.device});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  List<dynamic> _files = [];
  bool _loading = true;
  String _currentPath = "";
  final List<String> _pathHistory = [];

  @override
  void initState() {
    super.initState();
    _loadRootPaths();
  }

  Future<void> _loadRootPaths() async {
    setState(() => _loading = true);
    
    // Zeige verfügbare Root-Pfade als Ordner
    final paths = List<String>.from(widget.device['available_paths']);
    
    setState(() {
      _files = paths.map((path) => {
        "name": p.basename(path),
        "path": path,
        "is_directory": true,
        "size": 0,
        "type": "folder",
      }).toList();
      _currentPath = "Root";
      _loading = false;
    });
  }

  Future<void> _loadPath(String path) async {
    setState(() => _loading = true);

    try {
      final targetIp = widget.device['ip'];
      final targetPort = widget.device['file_server_port'];
      
      final url = 'http://$targetIp:$targetPort/files/list?path=${Uri.encodeComponent(path)}';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200 && mounted) {
        final data = json.decode(response.body);
        setState(() {
          _files = data['files'];
          _currentPath = path;
          _loading = false;
        });
      } else {
        _showError("Failed to load files");
        setState(() => _loading = false);
      }
    } catch (e) {
      _showError("Connection error: $e");
      setState(() => _loading = false);
    }
  }

  void _openItem(Map<String, dynamic> item) {
    if (item['is_directory']) {
      _pathHistory.add(_currentPath);
      _loadPath(item['path']);
    } else {
      _showFileOptions(item);
    }
  }

  void _goBack() {
    if (_pathHistory.isEmpty) {
      Navigator.pop(context);
    } else {
      final previousPath = _pathHistory.removeLast();
      if (previousPath == "Root") {
        _loadRootPaths();
      } else {
        _loadPath(previousPath);
      }
    }
  }

  void _showFileOptions(Map<String, dynamic> file) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(_getFileIcon(file['type']), color: const Color(0xFF00FF41)),
              title: Text(file['name'], style: const TextStyle(color: Colors.white)),
              subtitle: Text(_formatSize(file['size']), style: const TextStyle(color: Colors.grey)),
            ),
            const Divider(color: Colors.grey),
            ListTile(
              leading: const Icon(Icons.download, color: Color(0xFF00FF41)),
              title: const Text("Download", style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _downloadFile(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline, color: Colors.grey),
              title: const Text("Details", style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showFileDetails(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _downloadFile(Map<String, dynamic> file) {
    // TODO: Implement download (ähnlich wie DataLink Transfer)
    _showSnack("Download feature coming soon...");
  }

  void _showFileDetails(Map<String, dynamic> file) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text("File Details", style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow("Name", file['name']),
            _buildDetailRow("Size", _formatSize(file['size'])),
            _buildDetailRow("Type", file['type']),
            _buildDetailRow("Modified", _formatDate(file['modified'])),
            const Divider(color: Colors.grey),
            Text(
              file['path'],
              style: const TextStyle(color: Colors.grey, fontSize: 10),
            ),
          ],
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
      case 'folder':
        return Icons.folder;
      case 'image':
        return Icons.image;
      case 'video':
        return Icons.videocam;
      case 'audio':
        return Icons.audiotrack;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'document':
        return Icons.description;
      case 'archive':
        return Icons.archive;
      case 'apk':
        return Icons.android;
      case 'executable':
        return Icons.settings_applications;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getFileColor(String type) {
    switch (type) {
      case 'folder':
        return const Color(0xFF00E5FF);
      case 'image':
        return Colors.purple;
      case 'video':
        return Colors.red;
      case 'audio':
        return Colors.orange;
      case 'pdf':
        return Colors.red;
      case 'document':
        return Colors.blue;
      case 'archive':
        return Colors.yellow;
      default:
        return Colors.grey;
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / 1024 / 1024).toStringAsFixed(1)} MB";
    return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }

  String _formatDate(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final diff = now.difference(date);
    
    if (diff.inDays == 0) return "Today";
    if (diff.inDays == 1) return "Yesterday";
    if (diff.inDays < 7) return "${diff.inDays} days ago";
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
          backgroundColor: isError ? Colors.red : const Color(0xFF00FF41).withOpacity(0.3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _goBack,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.device['name'], style: const TextStyle(fontSize: 14)),
            Text(
              _currentPath.length > 30 
                ? "...${_currentPath.substring(_currentPath.length - 30)}" 
                : _currentPath,
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              if (_currentPath == "Root") {
                _loadRootPaths();
              } else {
                _loadPath(_currentPath);
              }
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00FF41)))
          : _files.isEmpty
              ? const Center(child: Text("Empty folder", style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    final isDirectory = file['is_directory'];
                    
                    return GestureDetector(
                      onTap: () => _openItem(file),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111111),
                          border: Border(
                            left: BorderSide(
                              color: _getFileColor(file['type']),
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
                              _getFileIcon(file['type']),
                              color: _getFileColor(file['type']),
                              size: 28,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    file['name'],
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
                                    Text(
                                      _formatSize(file['size']),
                                      style: const TextStyle(
                                        color: Colors.grey,
                                        fontSize: 11,
                                      ),
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
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}