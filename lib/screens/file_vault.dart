import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;

// Deine Imports (Lasse diese so, wie sie in deinem Projekt sind)
import '../config/server_config.dart';
import '../ui/theme_constants.dart';
import '../ui/tech_card.dart';
import '../ui/parallelogram_button.dart';
import '../ui/scifi_background.dart';

// =============================================================================
// 1. VFS MODEL
// =============================================================================
enum VfsNodeType { folder, drive, image, video, audio, code, archive, document, unknown }

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

  VfsNode({
    required this.name,
    required this.path,
    required this.deviceId,
    required this.deviceName,
    required this.isDirectory,
    this.size = 0,
    this.modified = 0,
    this.isSelected = false,
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
    if (['.pdf', '.doc', '.docx', '.txt', '.md'].contains(ext)) return VfsNodeType.document;
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
      default: return Icons.insert_drive_file;
    }
  }
}

// =============================================================================
// 2. CONTROLLER
// =============================================================================

class FileVaultController extends ChangeNotifier {
  bool isLoading = false;
  String? errorMessage;
  String currentPath = "ROOT";
  String currentDeviceId = "";
  String currentDeviceName = "Network";
  
  // Suche
  String searchQuery = "";
  bool isSearching = false;
  bool isDeepSearchActive = false;
  
  List<VfsNode> files = [];
  List<Map<String, String>> history = [];

  final String _serverUrl = serverBaseUrl;

  // WICHTIG: Die init Methode, die gefehlt hat!
  void init() {
    loadRoot();
  }

  List<VfsNode> get displayFiles {
    if (isDeepSearchActive) return files; 
    if (searchQuery.isEmpty) return files;
    return files.where((node) => 
      node.name.toLowerCase().contains(searchQuery.toLowerCase())
    ).toList();
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
      print("📡 Fetching devices from $_serverUrl/storage/devices");
      final response = await http.get(Uri.parse('$_serverUrl/storage/devices'));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final devices = List<dynamic>.from(data['devices'] ?? []);
        
        files = devices.map((d) => VfsNode(
          name: d['name'],
          path: "ROOT", 
          deviceId: d['client_id'],
          deviceName: d['name'],
          isDirectory: true,
        )).toList();
      } else {
        errorMessage = "Server Error: ${response.statusCode}";
      }
    } catch (e) {
      print("❌ Error loading root: $e");
      errorMessage = "Connection Failed: $e";
    } finally {
      _setLoading(false);
    }
  }

  void updateSearchQuery(String query) {
    searchQuery = query;
    notifyListeners();
  }

  Future<void> open(VfsNode node) async {
    if (!node.isDirectory) return;

    history.add({
      'path': currentPath, 
      'deviceId': currentDeviceId, 
      'name': currentDeviceName
    });

    if (currentPath == "ROOT") {
      currentDeviceId = node.deviceId;
      currentDeviceName = node.deviceName;
      await _loadRemotePath(node.deviceId, null);
    } else {
      await _loadRemotePath(currentDeviceId, node.path);
    }
  }

  Future<void> performDeepSearch(String query) async {
    // FEHLER WAR HIER: Hier stand Code, der auf 'response' zugriff, bevor es existierte.
    
    if (query.isEmpty) return;
    
    _setLoading(true);
    isDeepSearchActive = true; 
    searchQuery = query; 
    files.clear(); 
    errorMessage = null;

    try {
      String searchRoot = (currentPath == "ROOT" || currentPath == "Drives") ? "" : currentPath;
      
      if (currentDeviceId.isEmpty) {
        errorMessage = "SELECT A DRIVE FIRST";
        _setLoading(false);
        return;
      }
      
      final devResponse = await http.get(Uri.parse('$_serverUrl/storage/devices'));
      final devData = json.decode(devResponse.body);
      final device = (devData['devices'] as List).firstWhere(
        (d) => d['client_id'] == currentDeviceId, orElse: () => null
      );

      if (device != null) {
        final ip = device['ip'];
        final port = device['file_server_port'];
        
        final url = 'http://$ip:$port/files/search?query=${Uri.encodeComponent(query)}&path=${Uri.encodeComponent(searchRoot)}';
        
        print("🔎 DEEP SCAN: $url");
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));

        // HIER IST DER RICHTIGE ORT FÜR DIE LOGIK:
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final rawFiles = List<dynamic>.from(data['files']);
          
          files = rawFiles.map((f) {
            // WICHTIG: Die neue Logik für Cloud-Dateien
            final sourceDevice = f['device_id'] ?? currentDeviceId;
            
            return VfsNode(
              name: f['name'],
              path: f['path'],
              deviceId: sourceDevice, 
              deviceName: sourceDevice == currentDeviceId ? currentDeviceName : "Remote ($sourceDevice)",
              isDirectory: f['is_directory'],
              size: f['size'] ?? 0,
              modified: f['modified'] ?? 0,
            );
          }).toList();
        } else {
          errorMessage = "SCAN FAILED: ${response.statusCode}";
        }
      }
    } catch (e) {
      errorMessage = "SCAN ERROR: $e";
    } finally {
      _setLoading(false);
    }
  }

  void toggleSearch() {
    isSearching = !isSearching;
    if (!isSearching) {
      searchQuery = "";
      isDeepSearchActive = false;
      if (currentPath == "ROOT") loadRoot();
      else _loadRemotePath(currentDeviceId, currentPath);
    }
    notifyListeners();
  }
  
  Future<void> _sendCommandToRelay(String action, Map<String, dynamic> params) async {
    if (currentDeviceId.isEmpty) return;
    
    final bodyData = json.encode({
      "sender_id": "MASTER_CONTROL", // Oder deine ClientID
      "target_id": currentDeviceId,  // Das Zielgerät (PC/Handy)
      "action": action,
      "params": params
    });

    print("🚀 Sending Relay Command: $action to $currentDeviceId");

    final response = await http.post(
      Uri.parse('$_serverUrl/storage/remote/command'),
      headers: {"Content-Type": "application/json"},
      body: bodyData,
    ).timeout(const Duration(seconds: 5));

    if (response.statusCode != 200) {
      throw Exception("Server Relay Error: ${response.statusCode}");
    }
  }


  // 2. Löschen - jetzt über Relay
  Future<void> deleteNodes() async {
    if (selectedNodes.isEmpty) return;
    _setLoading(true);
    
    for (var node in selectedNodes) {
      try {
        await _sendCommandToRelay("delete", {
          "path": node.path
        });
      } catch (e) {
        print("❌ Delete Error: $e");
        errorMessage = "Delete Failed: $e";
      }
    }

    clearSelection();
    await Future.delayed(const Duration(seconds: 1));
    // Wenn wir im Root waren, Root neu laden, sonst Ordner
    if (currentPath == "ROOT" || currentPath == "Drives") {
        loadRoot();
    } else {
        _loadRemotePath(currentDeviceId, currentPath);
    }
  }

  // 3. Umbenennen - jetzt über Relay
  Future<void> renameNode(VfsNode node, String newName) async {
    _setLoading(true);
    try {
      await _sendCommandToRelay("rename", {
        "path": node.path,
        "new_name": newName
      });
      await Future.delayed(const Duration(milliseconds: 500));
      _loadRemotePath(currentDeviceId, currentPath);
    } catch (e) {
      errorMessage = "Rename failed: $e";
      _setLoading(false);
    }
  }

  Future<void> _loadRemotePath(String deviceId, String? path) async {
    // Reset Suche beim Navigieren
    searchQuery = "";
    isSearching = false;
    
    _setLoading(true);
    errorMessage = null;
    try {
      // 1. Geräte-IP holen
      final devResponse = await http.get(Uri.parse('$_serverUrl/storage/devices'));
      final devData = json.decode(devResponse.body);
      final device = (devData['devices'] as List).firstWhere(
        (d) => d['client_id'] == deviceId, orElse: () => null
      );

      if (device != null) {
        final ip = device['ip'];
        final port = device['file_server_port'];
        
        String url;
        
        // --- DER FIX IST HIER ---
        // Wenn path "Drives" ist, wollen wir in den else-Block rutschen (Dateiliste laden)!
        if (path == null || path == "ROOT") {
           url = 'http://$ip:$port/files/paths';
           currentPath = "Drives";
        } else {
           // Ruft /files/list auf -> Der Server gibt uns endlich die Dateien!
           url = 'http://$ip:$port/files/list?path=${Uri.encodeComponent(path)}';
           currentPath = path;
        }
        // ------------------------

        print("📡 Calling Remote: $url");
        
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
        
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          
          // Fall A: Wir sind ganz oben (Pfade anzeigen)
          if (currentPath == "Drives" && data.containsKey('paths')) {
            final paths = List<String>.from(data['paths']);
            files = paths.map((p) => VfsNode(
              name: p,
              path: p,
              deviceId: deviceId,
              deviceName: device['name'],
              isDirectory: true,
            )).toList();
          } 
          // Fall B: Wir zeigen echte Dateien an
          else {
            final rawFiles = List<dynamic>.from(data['files']);
            files = rawFiles.map((f) => VfsNode(
              name: f['name'],
              path: f['path'],
              deviceId: deviceId,
              deviceName: device['name'],
              isDirectory: f['is_directory'],
              size: f['size'] ?? 0,
              modified: f['modified'] ?? 0,
            )).toList();
          }
        } else {
           errorMessage = "Remote Device Error: ${response.statusCode}";
        }
      } else {
        errorMessage = "Device offline or not found.";
      }
    } catch (e) {
      print("❌ Error loading remote: $e");
      errorMessage = "Remote connection failed: $e";
    } finally {
      _setLoading(false);
    }
  }

  bool handleBackPress() {
    if (isSelectionMode) {
      clearSelection();
      return false; 
    }
    if (history.isNotEmpty) {
      navigateUp();
      return false; 
    }
    return true; 
  }

  void navigateUp() {
    if (history.isEmpty) return;
    final last = history.removeLast();
    
    if (last['path'] == "ROOT") {
      loadRoot();
    } else {
      currentDeviceId = last['deviceId']!;
      currentDeviceName = last['name']!;
      _loadRemotePath(currentDeviceId, last['path'] == "Drives" ? null : last['path']);
    }
  }

  bool get isSelectionMode => files.any((f) => f.isSelected);
  List<VfsNode> get selectedNodes => files.where((f) => f.isSelected).toList();

  void toggleSelection(VfsNode node) {
    node.isSelected = !node.isSelected;
    notifyListeners();
  }

  void clearSelection() {
    for (var f in files) f.isSelected = false;
    notifyListeners();
  }

  void _setLoading(bool val) {
    isLoading = val;
    notifyListeners();
  }
}

// =============================================================================
// 3. UI VIEW
// =============================================================================

class NetworkStorageScreen extends StatelessWidget {
  const NetworkStorageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        final controller = FileVaultController();
        controller.init(); // Jetzt funktioniert das, weil "init()" oben existiert!
        return controller;
      },
      child: const _FileVaultView(),
    );
  }
}

class _FileVaultView extends StatelessWidget {
  const _FileVaultView();

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<FileVaultController>(context);
    
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final shouldClose = controller.handleBackPress();
        if (shouldClose && context.mounted) {
           Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent, 
        body: Stack(
          children: [
            Column(
              children: [
                _buildHeader(context, controller),
                
                if (controller.isLoading)
                  const LinearProgressIndicator(
                    backgroundColor: AppColors.background,
                    color: AppColors.primary,
                    minHeight: 2,
                  ),

                if (controller.errorMessage != null)
                   Container(
                     padding: const EdgeInsets.all(8),
                     color: Colors.red.withOpacity(0.2), 
                     width: double.infinity,
                     child: Text(
                       controller.errorMessage!, 
                       style: const TextStyle(color: Colors.red),
                       textAlign: TextAlign.center,
                     ),
                   ),

                Expanded(
                  child: controller.displayFiles.isEmpty && !controller.isLoading && controller.errorMessage == null
                    ? Center(
                        child: Text(
                          controller.searchQuery.isEmpty ? "NO DATA STREAM" : "NO MATCH FOUND", 
                          style: const TextStyle(color: AppColors.textDim, letterSpacing: 2)
                        )
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 8, bottom: 100),
                        itemCount: controller.displayFiles.length,
                        itemBuilder: (context, index) {
                          return _buildFileItem(context, controller, controller.displayFiles[index]);
                        },
                      ),
                ),
              ],
            ),

            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutExpo,
              bottom: controller.isSelectionMode ? 20 : -100,
              left: 20,
              right: 20,
              child: _buildActionBar(context, controller),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, FileVaultController controller) {
    if (controller.isSearching) {
      return _buildSearchBar(context, controller);
    }

    List<Widget> breadcrumbs = [];
    
    breadcrumbs.add(
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: ParallelogramButton(
          text: "NET",
          icon: Icons.hub,
          skew: 0.2,
          color: controller.currentPath == "ROOT" ? AppColors.primary : Colors.grey,
          onTap: () => controller.loadRoot(),
        ),
      )
    );

    if (controller.currentPath != "ROOT") {
       breadcrumbs.add(
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: ParallelogramButton(
            text: "BACK", 
            skew: 0.2,
            color: AppColors.accent,
            onTap: () => controller.navigateUp(),
          ),
        )
      );
    }

    return Container(
      padding: const EdgeInsets.only(top: 50, bottom: 10, left: 10, right: 10),
      color: AppColors.card.withOpacity(0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: breadcrumbs),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.search, color: AppColors.primary),
                onPressed: () => controller.toggleSearch(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "${controller.files.length} NODES • ${controller.currentPath}",
                style: const TextStyle(color: AppColors.textDim, fontSize: 10, letterSpacing: 1.5),
              ),
              if (controller.isSelectionMode)
                Text(
                  "${controller.selectedNodes.length} SELECTED",
                  style: const TextStyle(color: AppColors.primary, fontSize: 10, fontWeight: FontWeight.bold),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, FileVaultController controller) {
    return Container(
      padding: const EdgeInsets.only(top: 50, bottom: 10, left: 16, right: 16),
      color: AppColors.card.withOpacity(0.8),
      child: Column(
        children: [
          TechCard(
            borderColor: controller.isDeepSearchActive ? AppColors.warning : AppColors.primary,
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Icon(
                    controller.isDeepSearchActive ? Icons.travel_explore : Icons.search, 
                    color: controller.isDeepSearchActive ? AppColors.warning : AppColors.primary
                  ),
                ),
                Expanded(
                  child: TextField(
                    autofocus: true,
                    style: GoogleFonts.rajdhani(color: Colors.white, fontSize: 18),
                    cursorColor: AppColors.primary,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: controller.isDeepSearchActive ? "DEEP SCAN ACTIVE..." : "TYPE TO FILTER / ENTER TO SCAN",
                      hintStyle: const TextStyle(color: AppColors.textDim, fontSize: 12),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: (value) => controller.updateSearchQuery(value),
                    onSubmitted: (value) => controller.performDeepSearch(value),
                  ),
                ),
                if (controller.isDeepSearchActive)
                   IconButton(
                    icon: const Icon(Icons.refresh, color: AppColors.warning),
                    onPressed: () => controller.performDeepSearch(controller.searchQuery),
                   ),
                IconButton(
                  icon: const Icon(Icons.close, color: AppColors.warning),
                  onPressed: () => controller.toggleSearch(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              "${controller.displayFiles.length} MATCHES",
              style: const TextStyle(color: AppColors.primary, fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileItem(BuildContext context, FileVaultController controller, VfsNode node) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TechCard(
        borderColor: node.isSelected 
            ? AppColors.primary 
            : node.type == VfsNodeType.folder 
                ? AppColors.accent.withOpacity(0.3) 
                : Colors.white.withOpacity(0.05),
        
        onTap: () {
          if (controller.isSelectionMode) {
            controller.toggleSelection(node);
          } else {
            if (node.isDirectory) {
              controller.open(node);
            } else {
              print("Open File: ${node.name}");
            }
          }
        },
        onLongPress: () => controller.toggleSelection(node),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: node.color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: node.color.withOpacity(0.3)),
              ),
              child: Icon(node.icon, color: node.color, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.name,
                    style: GoogleFonts.rajdhani(
                      color: node.isSelected ? AppColors.primary : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (controller.isDeepSearchActive)
                    Text(
                      "PATH: ${node.path}", 
                      style: const TextStyle(color: AppColors.accent, fontSize: 10),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else if (node.type != VfsNodeType.folder && node.type != VfsNodeType.drive)
                    Text(
                      "${(node.size/1024).toStringAsFixed(1)} KB",
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                ],
              ),
            ),
            if (controller.isSelectionMode)
              Icon(
                node.isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                color: node.isSelected ? AppColors.primary : Colors.grey,
              )
            else if (node.isDirectory)
              const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildActionBar(BuildContext context, FileVaultController controller) {
    return TechCard(
      borderColor: AppColors.primary,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildActionButton(Icons.close, "CANCEL", () => controller.clearSelection()),
          _buildActionButton(Icons.copy, "COPY", () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Not implemented")))),
          _buildActionButton(Icons.drive_file_move, "MOVE", () {}),
          _buildActionButton(Icons.download, "GET", () {}),
          _buildActionButton(Icons.delete, "DEL", () => controller.deleteNodes(), isDanger: true),
        ],
      ),
    );
  }

  Widget _buildActionButton(IconData icon, String label, VoidCallback onTap, {bool isDanger = false}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isDanger ? AppColors.warning : Colors.white),
            const SizedBox(height: 4),
            Text(
              label, 
              style: TextStyle(
                color: isDanger ? AppColors.warning : Colors.white, 
                fontSize: 10, 
                fontWeight: FontWeight.bold
              )
            ),
          ],
        ),
      ),
    );
  }
}