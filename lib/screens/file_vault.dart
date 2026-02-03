import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart'; // Für Datumsformatierung

import '../config/server_config.dart';
import '../ui/theme_constants.dart';
import '../ui/tech_card.dart';
import '../ui/parallelogram_button.dart';
import '../ui/scifi_background.dart';

// =============================================================================
// VFS MODEL - Das intelligente Dateiobjekt
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
    if (path == "ROOT") return VfsNodeType.drive; // Gerät selbst
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
// CONTROLLER - State Management
// =============================================================================

class FileVaultController extends ChangeNotifier {
  bool isLoading = false;
  String currentPath = "ROOT";
  String currentDeviceId = "";
  String currentDeviceName = "Network";
  
  List<VfsNode> files = [];
  List<Map<String, String>> history = []; // [{'path': '...', 'deviceId': '...', 'name': '...'}]

  final String _serverUrl = serverBaseUrl;

  void init() {
    loadRoot();
  }

  // Root: Liste aller Geräte
  Future<void> loadRoot() async {
    _setLoading(true);
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
          name: d['name'],
          path: "ROOT", 
          deviceId: d['client_id'],
          deviceName: d['name'],
          isDirectory: true,
        )).toList();
      }
    } catch (e) {
      print("❌ Error loading root: $e");
    } finally {
      _setLoading(false);
    }
  }

  // Öffnen
  Future<void> open(VfsNode node) async {
    if (!node.isDirectory) return;

    history.add({
      'path': currentPath, 
      'deviceId': currentDeviceId, 
      'name': currentDeviceName
    });

    if (currentPath == "ROOT") {
      // In ein Gerät hinein
      currentDeviceId = node.deviceId;
      currentDeviceName = node.deviceName;
      await _loadRemotePath(node.deviceId, null);
    } else {
      // Im Gerät navigieren
      await _loadRemotePath(currentDeviceId, node.path);
    }
  }

  // Laden
  Future<void> _loadRemotePath(String deviceId, String? path) async {
    _setLoading(true);
    try {
      // 1. IP des Geräts holen (via Server Proxy oder Cache)
      final devResponse = await http.get(Uri.parse('$_serverUrl/storage/devices'));
      final devData = json.decode(devResponse.body);
      final device = (devData['devices'] as List).firstWhere(
        (d) => d['client_id'] == deviceId, orElse: () => null
      );

      if (device != null) {
        final ip = device['ip'];
        final port = device['file_server_port'];
        
        String url;
        if (path == null || path == "ROOT") {
           url = 'http://$ip:$port/files/paths'; // Root Drives
           currentPath = "Drives";
        } else {
           url = 'http://$ip:$port/files/list?path=${Uri.encodeComponent(path)}';
           currentPath = path;
        }

        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
        
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          
          if (path == null || path == "ROOT") {
            final paths = List<String>.from(data['paths']);
            files = paths.map((p) => VfsNode(
              name: p,
              path: p,
              deviceId: deviceId,
              deviceName: device['name'],
              isDirectory: true,
            )).toList();
          } else {
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
        }
      }
    } catch (e) {
      print("❌ Error loading remote: $e");
    } finally {
      _setLoading(false);
    }
  }

  // Zurück
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

  // Selection
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
// UI - The Sci-Fi File Explorer
// =============================================================================

class NetworkStorageScreen extends StatelessWidget {
  const NetworkStorageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => FileVaultController()..init(),
      child: const _FileVaultView(),
    );
  }
}

class _FileVaultView extends StatelessWidget {
  const _FileVaultView();

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<FileVaultController>(context);
    
    return Scaffold(
      backgroundColor: Colors.transparent, // Für SciFiBackground
      body: Stack(
        children: [
          Column(
            children: [
              // 1. Header / Breadcrumbs
              _buildHeader(context, controller),
              
              // 2. Loading Indicator
              if (controller.isLoading)
                const LinearProgressIndicator(
                  backgroundColor: AppColors.background,
                  color: AppColors.primary,
                  minHeight: 2,
                ),

              // 3. File List
              Expanded(
                child: controller.files.isEmpty && !controller.isLoading
                  ? Center(child: Text("NO DATA STREAM", style: TextStyle(color: AppColors.textDim, letterSpacing: 2)))
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 8, bottom: 100), // Platz für Action Bar
                      itemCount: controller.files.length,
                      itemBuilder: (context, index) {
                        return _buildFileItem(context, controller, controller.files[index]);
                      },
                    ),
              ),
            ],
          ),

          // 4. Floating Action Bar (Selection Mode)
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
    );
  }

  Widget _buildHeader(BuildContext context, FileVaultController controller) {
    // Breadcrumb Logik
    List<Widget> breadcrumbs = [];
    
    // Home Button
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

    // Device Button
    if (controller.currentPath != "ROOT") {
      breadcrumbs.add(
         Padding(
          padding: const EdgeInsets.only(right: 4),
          child: ParallelogramButton(
            text: controller.currentDeviceName.toUpperCase(),
            skew: 0.2,
            color: controller.currentPath == "Drives" ? AppColors.primary : AppColors.accent,
            onTap: () {
               // Zurück zum Device Root springen logic könnte hier hin
            },
          ),
        )
      );
    }
    
    // Path segments
    if (controller.currentPath != "ROOT" && controller.currentPath != "Drives") {
      final name = p.basename(controller.currentPath);
      breadcrumbs.add(
         Padding(
          padding: const EdgeInsets.only(right: 4),
          child: ParallelogramButton(
            text: name.length > 15 ? "...${name.substring(name.length - 12)}" : name,
            skew: 0.2,
            color: AppColors.primary,
            onTap: () {},
          ),
        )
      );
    }

    return Container(
      padding: const EdgeInsets.only(top: 50, bottom: 10, left: 10, right: 10),
      color: AppColors.card.withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Breadcrumbs Horizontal Scroll
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: breadcrumbs),
          ),
          const SizedBox(height: 10),
          // Info Zeile
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "${controller.files.length} NODES DETECTED",
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

  Widget _buildFileItem(BuildContext context, FileVaultController controller, VfsNode node) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TechCard(
        borderColor: node.isSelected 
            ? AppColors.primary 
            : node.type == VfsNodeType.folder 
                ? AppColors.accent.withValues(alpha: 0.3) 
                : Colors.white.withValues(alpha: 0.05),
        
        // ✅ 1. Tap Logic direkt in der TechCard
        onTap: () {
          if (controller.isSelectionMode) {
            controller.toggleSelection(node);
          } else {
            if (node.isDirectory) {
              controller.open(node);
            } else {
              // TODO: File Open Action
            }
          }
        },
        
        // ✅ 2. LongPress Logic direkt in der TechCard
        onLongPress: () => controller.toggleSelection(node),
        
        // ✅ 3. Kein InkWell mehr um die Row! Die Klicks gehen jetzt durch.
        child: Row(
          children: [
            // Icon Box
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: node.color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: node.color.withValues(alpha: 0.3)),
              ),
              child: Icon(node.icon, color: node.color, size: 20),
            ),
            const SizedBox(width: 16),
            
            // Text Info
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
                  if (node.type != VfsNodeType.folder && node.type != VfsNodeType.drive)
                    Text(
                      "${_formatBytes(node.size)} • ${_formatDate(node.modified)}",
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                ],
              ),
            ),
            
            // Selection Indicator
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
          _buildActionButton(Icons.copy, "COPY", () {
            // TODO: Copy Logic
          }),
          _buildActionButton(Icons.drive_file_move, "MOVE", () {
            // TODO: Move Logic
          }),
          _buildActionButton(Icons.download, "GET", () {
             // TODO: Download Logic
          }),
          _buildActionButton(Icons.delete, "DEL", () {
             // TODO: Delete Logic
          }, isDanger: true),
        ],
      ),
    );
  }

  Widget _buildActionButton(IconData icon, String label, VoidCallback onTap, {bool isDanger = false}) {
    return InkWell(
      onTap: onTap,
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
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / 1024 / 1024).toStringAsFixed(1)} MB";
    return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }

  String _formatDate(int ms) {
    if (ms == 0) return "";
    return DateFormat('dd.MM.yy HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ms));
  }
}