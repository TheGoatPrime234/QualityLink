import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';

import '../services/data_link_service.dart';
import '../config/server_config.dart';
import '../ui/theme_constants.dart';

// =============================================================================
// 1. VFS MODEL & ENUMS
// =============================================================================
enum VfsNodeType { folder, drive, image, video, audio, code, archive, document, pdf, unknown }
enum SortOption { name, date, size, type }

class VfsNode {
  final String name;
  final String path;
  final String deviceId;
  final String deviceName;
  final bool isDirectory;
  final int size;
  final int modified;
  final VfsNodeType type;
  bool isSelected = false;
  final String? downloadUrl;

  VfsNode({
    required this.name,
    required this.path,
    required this.deviceId,
    required this.deviceName,
    required this.isDirectory,
    this.size = 0,
    this.modified = 0,
    this.isSelected = false,
    this.downloadUrl, 
  }) : type = _determineType(name, isDirectory, path);

  static VfsNodeType _determineType(String name, bool isDir, String path) {
    if (path == "ROOT") return VfsNodeType.drive;
    if (isDir) return VfsNodeType.folder;
    final ext = p.extension(name).toLowerCase();
    
    if (['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext)) return VfsNodeType.image;
    if (['.mp4', '.mkv', '.mov', '.avi', '.webm'].contains(ext)) return VfsNodeType.video;
    if (['.mp3', '.wav', '.flac', '.ogg'].contains(ext)) return VfsNodeType.audio;
    if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) return VfsNodeType.archive;
    if (['.dart', '.py', '.js', '.json', '.xml', '.html', '.css'].contains(ext)) return VfsNodeType.code;
    if (['.pdf'].contains(ext)) return VfsNodeType.pdf;
    if (['.doc', '.docx', '.txt', '.md'].contains(ext)) return VfsNodeType.document;
    
    return VfsNodeType.unknown;
  }

  Color get color {
    if (isSelected) return AppColors.primary;
    switch (type) {
      case VfsNodeType.drive: return Colors.white;
      case VfsNodeType.folder: return AppColors.accent;
      case VfsNodeType.image: return Colors.purpleAccent;
      case VfsNodeType.video: return AppColors.warning;
      case VfsNodeType.code: return const Color(0xFF00FF00);
      case VfsNodeType.archive: return Colors.orange;
      case VfsNodeType.audio: return Colors.blueAccent;
      case VfsNodeType.pdf: return Colors.redAccent; 
      default: return Colors.grey;
    }
  }

  IconData get icon {
    switch (type) {
      case VfsNodeType.drive: return Icons.computer;
      case VfsNodeType.folder: return Icons.folder_open;
      case VfsNodeType.image: return Icons.image;
      case VfsNodeType.video: return Icons.movie_filter;
      case VfsNodeType.audio: return Icons.graphic_eq;
      case VfsNodeType.code: return Icons.code;
      case VfsNodeType.archive: return Icons.inventory_2;
      case VfsNodeType.document: return Icons.description;
      case VfsNodeType.pdf: return Icons.picture_as_pdf; 
      default: return Icons.insert_drive_file;
    }
  }
}

// =============================================================================
// 2. CONTROLLER (State & Logic)
// =============================================================================
class FileVaultController extends ChangeNotifier {
  bool _isMoveOperation = false;
  bool showThumbnails = true; 
  int _requestCounter = 0;
  
  // Der SWR Cache für sofortiges Laden (Prefetching)
  final Map<String, List<VfsNode>> _folderCache = {}; 
  
  bool isLoading = false;
  String? errorMessage;
  String currentPath = "ROOT";
  String currentDeviceId = "";
  String currentDeviceName = "Network";
  VfsNodeType? activeFilter;
  String searchQuery = "";
  bool isSearching = false;
  bool isDeepSearchActive = false;
  String myClientId = "";
  String myDeviceName = "";
  List<VfsNode> _clipboardNodes = []; 

  SortOption currentSort = SortOption.name; 
  bool sortAscending = true;
  
  List<VfsNode> files = [];
  List<Map<String, String>> history = [];

  final String _serverUrl = serverBaseUrl;

  List<VfsNode> get displayFiles {
    List<VfsNode> results = files;

    if (!isDeepSearchActive && searchQuery.isNotEmpty) {
      results = files.where((node) => 
        node.name.toLowerCase().contains(searchQuery.toLowerCase())
      ).toList();
    }
    if (activeFilter != null) {
      results = results.where((node) => node.type == activeFilter).toList();
    }
    results = List.from(results);
    
    results.sort((a, b) {
      int cmp = 0;
      switch (currentSort) {
        case SortOption.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case SortOption.date:
          cmp = a.modified.compareTo(b.modified);
          break;
        case SortOption.size:
          cmp = a.size.compareTo(b.size);
          break;
        case SortOption.type:
          cmp = a.type.index.compareTo(b.type.index);
          break;
      }
      return sortAscending ? cmp : -cmp;
    });
    return results;
  }

  void init(String id, String name) {
    myClientId = id;
    myDeviceName = name;
    loadRoot();
  }

  void toggleThumbnails() {
    showThumbnails = !showThumbnails;
    notifyListeners();
  }

  void changeSort(SortOption option) {
    if (currentSort == option) {
      sortAscending = !sortAscending;
    } else {
      currentSort = option;
      sortAscending = (option != SortOption.date && option != SortOption.size);
    }
    notifyListeners();
  }

  void copySelection() {
    _clipboardNodes = List.from(selectedNodes);
    _isMoveOperation = false;
    clearSelection();
  }

  void cutSelection() {
    _clipboardNodes = List.from(selectedNodes);
    _isMoveOperation = true;
    clearSelection();
  }

  bool get canPaste => _clipboardNodes.isNotEmpty;

  Future<void> pasteFiles() async {
    if (_clipboardNodes.isEmpty) return;
    String destination = (currentPath == "ROOT" || currentPath == "Drives") ? "" : currentPath;

    _setLoading(true);
    errorMessage = null;

    int successCount = 0;
    int failCount = 0;
    final nodesToPaste = List<VfsNode>.from(_clipboardNodes);

    for (var node in nodesToPaste) {
      try {
        if (node.deviceId == myClientId && currentDeviceId == myClientId) {
          await _handleLocalPaste(node, destination);
          successCount++;
        }
        else if (node.deviceId == myClientId && currentDeviceId != myClientId) {
          if (node.isDirectory) {
             await DataLinkService().sendFolder(Directory(node.path), [currentDeviceId]);
          } else {
             await DataLinkService().sendFile(File(node.path), [currentDeviceId], destinationPath: destination);
          }
          successCount++;
        }
        else if (node.deviceId != myClientId && currentDeviceId == myClientId) {
           await _sendCommandToRelay("request_transfer", {
             "path": node.path, "requester_id": myClientId, "destination_path": destination 
           });
           successCount++;
        } else {
           failCount++;
        }
      } catch (e) {
        failCount++;
      }
    }

    if (_isMoveOperation) _clipboardNodes.clear();
    
    errorMessage = failCount > 0 ? "Success: $successCount, Failed: $failCount" : "Transfer started for $successCount items";
    Future.delayed(const Duration(seconds: 2), () => errorMessage = null);

    _setLoading(false);
    await Future.delayed(const Duration(seconds: 1));
    _loadRemotePath(currentDeviceId, currentPath);
  }

  Future<void> _handleLocalPaste(VfsNode node, String destination) async {
    final sourceFile = File(node.path);
    final sourceDir = Directory(node.path);
    final fileName = p.basename(node.path);
    String destPath = p.join(destination.isEmpty ? Directory.current.path : destination, fileName);

    if (await File(destPath).exists() || await Directory(destPath).exists()) {
       final name = p.basenameWithoutExtension(fileName);
       final ext = p.extension(fileName);
       destPath = p.join(p.dirname(destPath), "${name}_copy$ext");
    }

    if (_isMoveOperation) {
       if (await sourceFile.exists()) await sourceFile.rename(destPath);
       else if (await sourceDir.exists()) await sourceDir.rename(destPath);
    } else {
       if (await sourceFile.exists()) await sourceFile.copy(destPath);
    }
  }

  Future<void> downloadSelection() async {
    if (selectedNodes.isEmpty) return;
    _setLoading(true);

    int count = 0;
    for (var node in selectedNodes) {
      try {
        if (node.deviceId != myClientId) {
           await _sendCommandToRelay("request_transfer", {"path": node.path, "requester_id": myClientId});
           count++;
        }
      } catch (e) {
        errorMessage = "Download Request Failed: $e";
      }
    }
    
    clearSelection();
    _setLoading(false);
    
    if (count > 0) {
      errorMessage = "REQUESTED $count DOWNLOADS via DATALINK";
      Future.delayed(const Duration(seconds: 2), () => errorMessage = null);
    }
  }

Future<void> uploadFile() async {
    if (currentDeviceId.isEmpty || currentDeviceId == myClientId) {
      errorMessage = "SELECT A REMOTE FOLDER FIRST";
      return;
    }
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result != null) {
        _setLoading(true);
        List<File> files = result.paths.map((path) => File(path!)).toList();
        String destination = (currentPath == "ROOT" || currentPath == "Drives") ? "" : currentPath;
        await DataLinkService().sendFiles(files, [currentDeviceId], destinationPath: destination);
        _setLoading(false);
        Future.delayed(const Duration(seconds: 2), () => _loadRemotePath(currentDeviceId, currentPath));
      }
    } catch (e) {
      _setLoading(false);
      errorMessage = "Upload Failed: $e";
    }
  }

  void setFilter(VfsNodeType type) {
    activeFilter = (activeFilter == type) ? null : type;
    notifyListeners();
  }

  void updateSearchQuery(String query) {
    searchQuery = query;
    notifyListeners();
  }

  Future<void> loadRoot() async {
    _setLoading(true);
    errorMessage = null;
    searchQuery = "";
    isSearching = false;
    currentPath = "ROOT";
    currentDeviceId = "";
    currentDeviceName = "Network";
    files.clear();
    history.clear();

    try {
      final response = await http.get(Uri.parse('$_serverUrl/storage/devices'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final devices = List<dynamic>.from(data['devices'] ?? []);
        files = devices.map((d) => VfsNode(
          name: d['name'], path: "ROOT", deviceId: d['client_id'], deviceName: d['name'], isDirectory: true,
        )).toList();
      } else {
        errorMessage = "Server Error: ${response.statusCode}";
      }
    } catch (e) {
      errorMessage = "Connection Failed: $e";
    } finally {
      _setLoading(false);
    }
  }

  Future<void> open(VfsNode node) async {
    if (!node.isDirectory || isLoading) return;
    history.add({'path': currentPath, 'deviceId': currentDeviceId, 'name': currentDeviceName});

    if (currentPath == "ROOT") {
      currentDeviceId = node.deviceId;
      currentDeviceName = node.deviceName;
      await _loadRemotePath(node.deviceId, null);
    } else {
      await _loadRemotePath(currentDeviceId, node.path);
    }
  }

  Future<void> performDeepSearch(String query) async {
    if (query.isEmpty) return;
    _setLoading(true);
    isDeepSearchActive = true; 
    searchQuery = query; 
    files.clear(); 
    errorMessage = null;

    try {
      String searchUrl;
      if (currentDeviceId.isEmpty || currentPath == "ROOT" || currentPath == "Drives") {
         searchUrl = '$_serverUrl/files/search?query=${Uri.encodeComponent(query)}';
      } else {
        final devResponse = await http.get(Uri.parse('$_serverUrl/storage/devices'));
        final device = (json.decode(devResponse.body)['devices'] as List).firstWhere((d) => d['client_id'] == currentDeviceId, orElse: () => null);
        if (device == null) throw Exception("Device not found");
        searchUrl = 'http://${device['ip']}:${device['file_server_port']}/files/search?query=${Uri.encodeComponent(query)}&path=${Uri.encodeComponent(currentPath)}';
      }

      final response = await http.get(Uri.parse(searchUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
          final rawFiles = List<dynamic>.from(json.decode(response.body)['files']);
          files = rawFiles.map((f) {
            final sourceDevice = f['device_id'] ?? currentDeviceId;
            return VfsNode(
              name: f['name'], path: f['path'], deviceId: sourceDevice, 
              deviceName: sourceDevice == currentDeviceId ? currentDeviceName : (sourceDevice == "SERVER" ? "QualityLink Core" : sourceDevice),
              isDirectory: f['is_directory'], size: f['size'] ?? 0, modified: f['modified'] ?? 0,
            );
          }).toList();
      } else {
         errorMessage = "Search failed: ${response.statusCode}";
      }
    } catch (e) {
      errorMessage = "Search Error: $e";
    } finally {
      _setLoading(false);
    }
  }

  void toggleSearch() {
    isSearching = !isSearching;
    if (!isSearching) {
      searchQuery = "";
      activeFilter = null; 
      isDeepSearchActive = false;
      if (currentPath == "ROOT") loadRoot();
      else if (currentPath == "Drives") _loadRemotePath(currentDeviceId, null); 
      else _loadRemotePath(currentDeviceId, currentPath);
    } else {
      notifyListeners();
    }
  }
  
  Future<void> _sendCommandToRelay(String action, Map<String, dynamic> params) async {
    if (currentDeviceId.isEmpty) return;
    final response = await http.post(
      Uri.parse('$_serverUrl/storage/remote/command'),
      headers: {"Content-Type": "application/json"},
      body: json.encode({"sender_id": "MASTER_CONTROL", "target_id": currentDeviceId, "action": action, "params": params}),
    ).timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) throw Exception("Server Relay Error: ${response.statusCode}");
  }

  Future<void> deleteNodes() async {
    if (selectedNodes.isEmpty) return;
    _setLoading(true);
    final pathAtDeletion = currentPath;
    
    for (var node in selectedNodes) {
      try { await _sendCommandToRelay("delete", {"path": node.path}); } catch (e) { errorMessage = "Delete Failed: $e"; }
    }
    clearSelection();
    await Future.delayed(const Duration(milliseconds: 600)); 
    if (currentPath != pathAtDeletion) { _setLoading(false); return; }
    
    if (currentPath == "ROOT" || currentPath == "Drives") loadRoot();
    else _loadRemotePath(currentDeviceId, currentPath);
  }

  Future<void> renameNode(VfsNode node, String newName) async {
    _setLoading(true);
    final pathAtRename = currentPath; 
    try {
      await _sendCommandToRelay("rename", {"path": node.path, "new_name": newName});
      await Future.delayed(const Duration(milliseconds: 500));
      if (currentPath == pathAtRename) _loadRemotePath(currentDeviceId, currentPath);
      else _setLoading(false);
    } catch (e) {
      errorMessage = "Rename failed: $e";
      _setLoading(false);
    }
  }

  Future<void> _loadRemotePath(String deviceId, String? path) async {
    final int currentRequest = ++_requestCounter;
    final String cacheKey = "${deviceId}_${path ?? 'ROOT'}";
    searchQuery = "";
    isSearching = false;
    
    if (_folderCache.containsKey(cacheKey)) {
      files = List.from(_folderCache[cacheKey]!);
      _setLoading(false); 
    } else {
      _setLoading(true);
      errorMessage = null;
    }

    try {
      final devResponse = await http.get(Uri.parse('$_serverUrl/storage/devices'));
      final device = (json.decode(devResponse.body)['devices'] as List).firstWhere((d) => d['client_id'] == deviceId, orElse: () => null);

      if (device != null) {
        final ip = device['ip'];
        final port = device['file_server_port'];
        String url = (path == null || path == "ROOT" || path == "Drives") 
            ? 'http://$ip:$port/files/paths' 
            : 'http://$ip:$port/files/list?path=${Uri.encodeComponent(path)}';
        currentPath = (path == null || path == "ROOT" || path == "Drives") ? "Drives" : path;

        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
        if (currentRequest != _requestCounter) return; 
        
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          List<VfsNode> newFiles = [];
          
          if (currentPath == "Drives" && data.containsKey('paths')) {
            newFiles = (data['paths'] as List).map((p) => VfsNode(
              name: p, path: p, deviceId: deviceId, deviceName: device['name'], isDirectory: true,
            )).toList();
          } else {
            newFiles = (data['files'] as List).map((f) => VfsNode(
              name: f['name'], path: f['path'], deviceId: deviceId, deviceName: device['name'],
              isDirectory: f['is_directory'], size: f['size'] ?? 0, modified: f['modified'] ?? 0,
              downloadUrl: 'http://$ip:$port/files/download?path=${Uri.encodeComponent(f['path'])}',
            )).toList();
          }
          
          _folderCache[cacheKey] = newFiles;
          files = List.from(newFiles);
          
          if (currentRequest == _requestCounter) {
            _setLoading(false);
            _prefetchTopFolders(deviceId, ip, port, files);
          }
        } else {
           if (currentRequest == _requestCounter && !_folderCache.containsKey(cacheKey)) errorMessage = "Remote Device Error: ${response.statusCode}";
        }
      } else {
        if (currentRequest == _requestCounter && !_folderCache.containsKey(cacheKey)) errorMessage = "Device offline or not found.";
      }
    } catch (e) {
      if (currentRequest == _requestCounter && !_folderCache.containsKey(cacheKey)) errorMessage = "Remote connection failed: $e";
    } finally {
      if (currentRequest == _requestCounter) _setLoading(false);
    }
  }

  Future<void> _prefetchTopFolders(String deviceId, String ip, int port, List<VfsNode> currentNodes) async {
    if (!showThumbnails) return;
    final topFolders = currentNodes.where((n) => n.isDirectory && n.path != "ROOT" && n.path != "Drives").take(3).toList();

    for (var folder in topFolders) {
      final cacheKey = "${deviceId}_${folder.path}";
      if (_folderCache.containsKey(cacheKey)) continue; 

      try {
        final response = await http.get(Uri.parse('http://$ip:$port/files/list?path=${Uri.encodeComponent(folder.path)}')).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final rawFiles = List<dynamic>.from(json.decode(response.body)['files']);
          _folderCache[cacheKey] = rawFiles.map((f) => VfsNode(
            name: f['name'], path: f['path'], deviceId: deviceId, deviceName: folder.deviceName,
            isDirectory: f['is_directory'], size: f['size'] ?? 0, modified: f['modified'] ?? 0,
            downloadUrl: 'http://$ip:$port/files/download?path=${Uri.encodeComponent(f['path'])}',
          )).toList();
        }
      } catch (_) {}
    }
  }

  bool handleBackPress() {
    if (isSelectionMode) { clearSelection(); return false; }
    if (history.isNotEmpty) { navigateUp(); return false; }
    return true; 
  }

  void navigateUp() {
    if (history.isEmpty) return;
    final last = history.removeLast();
    if (last['path'] == "ROOT") loadRoot();
    else {
      currentDeviceId = last['deviceId']!;
      currentDeviceName = last['name']!;
      _loadRemotePath(currentDeviceId, last['path'] == "Drives" ? null : last['path']);
    }
  }

  bool get isSelectionMode => files.any((f) => f.isSelected);
  List<VfsNode> get selectedNodes => files.where((f) => f.isSelected).toList();

  void toggleSelection(VfsNode node) { node.isSelected = !node.isSelected; notifyListeners(); }
  void clearSelection() { for (var f in files) { f.isSelected = false; } notifyListeners(); }
  void _setLoading(bool val) { isLoading = val; notifyListeners(); }
}