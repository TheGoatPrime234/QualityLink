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
import 'package:file_picker/file_picker.dart';
import '../services/data_link_service.dart';

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
  VfsNodeType? activeFilter;
  
  // Suche
  String searchQuery = "";
  bool isSearching = false;
  bool isDeepSearchActive = false;
  String myClientId = "";
  String myDeviceName = "";
  List<VfsNode> _clipboardNodes = [];
  bool _isMoveOperation = false;

  SortOption currentSort = SortOption.name; // ✅ Hier gehören sie hin!
  bool sortAscending = true;
  
  List<VfsNode> files = [];
  List<Map<String, String>> history = [];

  final String _serverUrl = serverBaseUrl;

  List<VfsNode> get displayFiles {
    List<VfsNode> results = files;

    // A. Filter (Suche & Typ)
    if (!isDeepSearchActive && searchQuery.isNotEmpty) {
      results = files.where((node) => 
        node.name.toLowerCase().contains(searchQuery.toLowerCase())
      ).toList();
    }
    if (activeFilter != null) {
      results = results.where((node) => node.type == activeFilter).toList();
    }

    // B. Sortierung (NEU!)
    // Wir kopieren die Liste, damit wir nicht die Original-Reihenfolge zerstören
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
      // Drehrichtung beachten
      return sortAscending ? cmp : -cmp;
    });

    return results;
  }

  void init(String id, String name) {
    myClientId = id;
    myDeviceName = name;
    loadRoot();
  }

  void changeSort(SortOption option) {
    if (currentSort == option) {
      // Gleiche Option geklickt -> Richtung umkehren
      sortAscending = !sortAscending;
    } else {
      // Neue Option -> Standardrichtung setzen
      currentSort = option;
      // Bei Datum und Größe will man meistens "Größte/Neueste zuerst" (also Absteigend)
      if (option == SortOption.date || option == SortOption.size) {
        sortAscending = false; 
      } else {
        sortAscending = true; // Bei Name A-Z
      }
    }
    notifyListeners();
  }

  void copySelection() {
    _clipboardNodes = List.from(selectedNodes);
    _isMoveOperation = false;
    clearSelection();
    notifyListeners(); // UI Update (vielleicht "Paste" Button anzeigen?)
  }

  void cutSelection() {
    _clipboardNodes = List.from(selectedNodes);
    _isMoveOperation = true;
    clearSelection();
    notifyListeners();
  }

  bool get canPaste => _clipboardNodes.isNotEmpty;

  Future<void> pasteFiles() async {
    if (_clipboardNodes.isEmpty) return;

    // 1. Wohin soll es gehen? (Ziel)
    // Wenn wir im Root sind, ist das Ziel leer (Standard-Download-Ordner des Geräts)
    // Sonst ist es der aktuelle Pfad.
    String destination = (currentPath == "ROOT" || currentPath == "Drives") 
        ? "" 
        : currentPath;

    _setLoading(true);
    errorMessage = null;

    int successCount = 0;
    int failCount = 0;

    // Wir erstellen eine Kopie der Liste, damit wir sie während des Iterierens modifizieren können
    final nodesToPaste = List<VfsNode>.from(_clipboardNodes);

    for (var node in nodesToPaste) {
      try {
        print("📋 Processing Paste: ${node.name} (${node.deviceId}) -> $currentDeviceId");

        // --- SZENARIO 1: LOKAL (PC zu PC / Handy zu Handy) ---
        // Quelle == Ich  UND  Ziel == Ich
        if (node.deviceId == myClientId && currentDeviceId == myClientId) {
          await _handleLocalPaste(node, destination);
          successCount++;
        }

        // --- SZENARIO 2: UPLOAD (PUSH) ---
        // Quelle == Ich  UND  Ziel == Anderes Gerät
        // Ich schiebe meine Datei auf das andere Gerät
        else if (node.deviceId == myClientId && currentDeviceId != myClientId) {
          print("🚀 PUSHING file to remote: $currentDeviceId");
          
          if (node.isDirectory) {
             // Ordner senden (als ZIP)
             await DataLinkService().sendFolder(
               Directory(node.path), 
               [currentDeviceId],
               // Callback ist hier schwer, wir feuern und vergessen
             );
          } else {
             // Datei senden (mit Zielpfad!)
             await DataLinkService().sendFile(
               File(node.path), 
               [currentDeviceId], 
               destinationPath: destination
             );
          }
          successCount++;
        }

        // --- SZENARIO 3: DOWNLOAD (PULL) ---
        // Quelle == Anderes Gerät  UND  Ziel == Ich
        // Ich hole mir eine Datei von woanders her
        else if (node.deviceId != myClientId && currentDeviceId == myClientId) {
           print("⬇️ PULLING file from remote: ${node.deviceId}");
           
           // Wir bitten das andere Gerät: "Schick mir das!"
           await _sendCommandToRelay("request_transfer", {
             "path": node.path,
             "requester_id": myClientId,
             "destination_path": destination // Wohin soll es bei mir?
           });
           successCount++;
        }

        // --- SZENARIO 4: REMOTE ZU REMOTE ---
        // PC A -> PC B (gesteuert vom Handy)
        // Das ist sehr komplex (Server müsste Proxy spielen). Blockieren wir erstmal.
        else {
           print("⚠️ Remote-to-Remote copy not supported yet.");
           failCount++;
        }

      } catch (e) {
        print("❌ Paste Error for ${node.name}: $e");
        failCount++;
      }
    }

    // Aufräumen
    if (_isMoveOperation) {
      // Bei "Ausschneiden" leeren wir das Clipboard
      _clipboardNodes.clear();
    } else {
      // Bei "Kopieren" behalten wir es (User könnte es nochmal woanders einfügen wollen)
    }

    // Feedback
    if (failCount > 0) {
      errorMessage = "Success: $successCount, Failed: $failCount";
    } else {
      errorMessage = "Transfer started for $successCount items";
      Future.delayed(const Duration(seconds: 2), () => errorMessage = null);
    }

    _setLoading(false);
    
    // Ansicht aktualisieren (kurz warten, damit Server reagieren kann)
    await Future.delayed(const Duration(seconds: 1));
    _loadRemotePath(currentDeviceId, currentPath);
  }

  Future<void> _handleLocalPaste(VfsNode node, String destination) async {
    final sourceFile = File(node.path);
    final sourceDir = Directory(node.path);
    final fileName = p.basename(node.path);
    String destPath = p.join(destination.isEmpty ? Directory.current.path : destination, fileName);

    // Namenskollision verhindern (file.txt -> file_copy.txt)
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
       else if (await sourceDir.exists()) {
         // Ordner lokal kopieren ist in Dart nervig, wir überspringen das für V1
         // oder nutzen einen rekursiven Helper. Für jetzt:
         print("Local folder copy not fully implemented, use Move instead.");
       }
    }
  }

  Future<void> downloadSelection() async {
    if (selectedNodes.isEmpty) return;
    _setLoading(true);

    int count = 0;
    for (var node in selectedNodes) {
      // WICHTIG: "if (node.isDirectory) continue;" ENTFERNEN wir jetzt!
      // Der DataLinkService kann jetzt Ordner zippen!
      
      try {
        if (node.deviceId == myClientId) {
           print("File is already local.");
        } else {
           await _sendCommandToRelay("request_transfer", {
             "path": node.path,
             "requester_id": myClientId 
           });
           count++;
        }
      } catch (e) {
        errorMessage = "Download Request Failed: $e";
      }
    }
    
    clearSelection();
    _setLoading(false);
    
    if (count > 0) {
      errorMessage = "REQUESTED $count ITEMS via DATALINK";
      Future.delayed(const Duration(seconds: 2), () => errorMessage = null);
    }
    
    clearSelection();
    _setLoading(false);
    
    if (count > 0) {
      // Kleiner Hack: Wir zeigen kurz eine Meldung via ErrorMessage (oder Snackbar im View)
      errorMessage = "REQUESTED $count DOWNLOADS via DATALINK";
      Future.delayed(const Duration(seconds: 2), () => errorMessage = null);
    }
  }

  // ✅ 2. UPLOAD (PUT)
  Future<void> uploadFile() async {
    // Check: Wohin soll es gehen?
    if (currentDeviceId.isEmpty || currentDeviceId == myClientId) {
      errorMessage = "SELECT A REMOTE FOLDER FIRST";
      return;
    }

    try {
      // Datei auswählen
      FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);

      if (result != null) {
        _setLoading(true);
        List<File> files = result.paths.map((path) => File(path!)).toList();
        
        // Zielpfad bestimmen (wo wir gerade im Vault sind)
        String destination = (currentPath == "ROOT" || currentPath == "Drives") 
            ? "" // Root ist ungültig, DataLink nimmt dann Default Download Folder
            : currentPath;

        print("🚀 Uploading ${files.length} files to $currentDeviceId at $destination");

        // Via DataLink senden (mit Zielpfad!)
        await DataLinkService().sendFiles(
          files, 
          [currentDeviceId], 
          destinationPath: destination // Das haben wir im DataLinkService schon vorbereitet!
        );
        
        _setLoading(false);
        // Refresh, damit wir die neuen Dateien sehen (nach kurzer Zeit)
        Future.delayed(const Duration(seconds: 2), () => _loadRemotePath(currentDeviceId, currentPath));
      }
    } catch (e) {
      _setLoading(false);
      errorMessage = "Upload Failed: $e";
    }
  }

  // NEU: Filter setzen oder löschen (Toggle)
  void setFilter(VfsNodeType type) {
    if (activeFilter == type) {
      activeFilter = null; // Filter deaktivieren, wenn man nochmal draufklickt
    } else {
      activeFilter = type; // Filter aktivieren
    }
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
    if (query.isEmpty) return;
    
    _setLoading(true);
    isDeepSearchActive = true; 
    searchQuery = query; 
    files.clear(); 
    errorMessage = null;

    try {
      String searchUrl;

      // FALL A: GLOBALE SUCHE (Wir sind im Root / "Drives")
      // Wir fragen den Raspberry Pi (Zentrale), da er alle Indizes kennt.
      if (currentDeviceId.isEmpty || currentPath == "ROOT" || currentPath == "Drives") {
         print("🌍 GLOBAL SEARCH via $_serverUrl");
         // Wir nutzen _serverUrl (die Adresse vom Pi aus der Config)
         searchUrl = '$_serverUrl/files/search?query=${Uri.encodeComponent(query)}';
      } 
      // FALL B: LOKALE SUCHE (Wir sind in einem Ordner auf einem Gerät)
      // Wir fragen das Gerät direkt für maximale Geschwindigkeit.
      else {
        final devResponse = await http.get(Uri.parse('$_serverUrl/storage/devices'));
        final devData = json.decode(devResponse.body);
        final device = (devData['devices'] as List).firstWhere(
          (d) => d['client_id'] == currentDeviceId, orElse: () => null
        );

        if (device == null) throw Exception("Device not found");
        
        final ip = device['ip'];
        final port = device['file_server_port'];
        
        // Suchpfad einschränken (optional, falls das Gerät das unterstützt)
        String searchRoot = currentPath;
        
        searchUrl = 'http://$ip:$port/files/search?query=${Uri.encodeComponent(query)}&path=${Uri.encodeComponent(searchRoot)}';
      }

      print("🔎 SEARCH CALL: $searchUrl");
      
      final response = await http.get(Uri.parse(searchUrl)).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final rawFiles = List<dynamic>.from(data['files']);
          
          files = rawFiles.map((f) {
            // WICHTIG: Bei globaler Suche sagt der Server uns, wo die Datei liegt
            // Wenn device_id fehlt (lokale Suche), nehmen wir das aktuelle Gerät.
            final sourceDevice = f['device_id'] ?? currentDeviceId;
            
            return VfsNode(
              name: f['name'],
              path: f['path'],
              deviceId: sourceDevice, 
              // Schöner Name für die Anzeige ("Remote" oder echter Name)
              deviceName: sourceDevice == currentDeviceId ? currentDeviceName : (sourceDevice == "SERVER" ? "QualityLink Core" : sourceDevice),
              isDirectory: f['is_directory'],
              size: f['size'] ?? 0,
              modified: f['modified'] ?? 0,
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
      activeFilter = null; // Filter resetten
      isDeepSearchActive = false;
      
      if (currentPath == "ROOT") {
          // Wir sind ganz oben bei der Geräte-Auswahl
          loadRoot();
      } else if (currentPath == "Drives") {
          // FIX: Wenn wir im Start-Ordner eines Geräts sind, laden wir die Pfade neu!
          // Wir übergeben 'null', damit _loadRemotePath den Endpunkt /files/paths aufruft.
          _loadRemotePath(currentDeviceId, null); 
      } else {
          // Wir sind in einem Unterordner -> Ordner neu laden
          _loadRemotePath(currentDeviceId, currentPath);
      }
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
  final String myClientId;
  final String myDeviceName;
  
  const NetworkStorageScreen({
    super.key, 
    required this.myClientId, 
    required this.myDeviceName
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        final controller = FileVaultController();
        controller.init(myClientId, myDeviceName); 
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
        body: SafeArea( // ✅ WICHTIG für Mobile Layout
          child: Stack(
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
                       color: AppColors.warning.withValues(alpha: 0.2), 
                       width: double.infinity,
                       child: Text(
                         controller.errorMessage!, 
                         style: const TextStyle(color: AppColors.warning),
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
              
              // Action Bar (unten, einfahrbar)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutExpo,
                bottom: (controller.isSelectionMode || controller.canPaste) ? 20 : -100,
                left: 20,
                right: 20,
                child: _buildActionBar(context, controller),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- HEADER BEREICH (Toolbar & Suche) ---

  Widget _buildHeader(BuildContext context, FileVaultController controller) {
    // Wenn Suche aktiv ist, zeigen wir die SearchBar
    if (controller.isSearching) {
      return _buildSearchBar(context, controller);
    }

    // Breadcrumbs bauen
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
      padding: const EdgeInsets.only(bottom: 10),
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. TITEL ZEILE
          Container(
            padding: const EdgeInsets.all(12),
            child: const Row(
              children: [
                Text("FILEVAULT", style: TextStyle(color: AppColors.primary, fontSize: 18, fontWeight: FontWeight.bold)),
                SizedBox(width: 12),
                Icon(Icons.circle, size: 8, color: AppColors.primary), 
              ],
            ),
          ),

          // 2. TOOLBAR (Breadcrumbs & Actions)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
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
                    
                    // Action Buttons
                    IconButton(
                      icon: const Icon(Icons.upload_file, color: AppColors.primary),
                      onPressed: () => controller.uploadFile(),
                      tooltip: "UPLOAD HERE",
                    ),
                    IconButton(
                      icon: const Icon(Icons.sort, color: AppColors.accent),
                      onPressed: () => _showSortMenu(context, controller),
                    ),
                    IconButton(
                      icon: const Icon(Icons.search, color: AppColors.primary),
                      onPressed: () => controller.toggleSearch(),
                    ),

                    // ✅ WICHTIG: Platzhalter für App Icon (60px)
                    const SizedBox(width: 60),
                  ],
                ),
                
                const SizedBox(height: 10),
                
                // Info Zeile (Anzahl Dateien / Selektion)
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
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, FileVaultController controller) {
    // Filter Icons Liste
    final filters = [
      {'type': VfsNodeType.image, 'label': 'IMG', 'icon': Icons.image},
      {'type': VfsNodeType.video, 'label': 'MOV', 'icon': Icons.movie},
      {'type': VfsNodeType.audio, 'label': 'AUD', 'icon': Icons.graphic_eq},
      {'type': VfsNodeType.document, 'label': 'DOC', 'icon': Icons.description},
      {'type': VfsNodeType.code, 'label': 'DEV', 'icon': Icons.code},
      {'type': VfsNodeType.archive, 'label': 'ZIP', 'icon': Icons.inventory_2},
    ];

    return Container(
      // Padding oben angepasst für SafeArea
      padding: const EdgeInsets.only(top: 10, bottom: 10, left: 16, right: 16),
      color: AppColors.card.withValues(alpha: 0.9),
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
                  icon: const Icon(Icons.sort, color: AppColors.accent),
                  onPressed: () => _showSortMenu(context, controller),
                ),

                IconButton(
                  icon: const Icon(Icons.close, color: AppColors.warning),
                  onPressed: () => controller.toggleSearch(),
                ),

                // ✅ WICHTIG: Auch hier Platzhalter für App Icon (60px)
                const SizedBox(width: 60),
              ],
            ),
          ),
          
          const SizedBox(height: 10),
          
          // Filter Leiste
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final f = filters[index];
                final type = f['type'] as VfsNodeType;
                final isActive = controller.activeFilter == type;
                final color = isActive ? AppColors.accent : Colors.grey;

                return GestureDetector(
                  onTap: () => controller.setFilter(type),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    decoration: BoxDecoration(
                      color: isActive ? AppColors.accent.withValues(alpha: 0.2) : Colors.transparent,
                      border: Border.all(
                        color: isActive ? AppColors.accent : Colors.grey.withValues(alpha: 0.3)
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Icon(f['icon'] as IconData, size: 14, color: color),
                        const SizedBox(width: 6),
                        Text(
                          f['label'] as String,
                          style: TextStyle(
                            color: color, 
                            fontWeight: FontWeight.bold, 
                            fontSize: 12
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 8),
          
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              "${controller.displayFiles.length} NODES FOUND",
              style: TextStyle(
                color: controller.activeFilter != null ? AppColors.accent : AppColors.primary, 
                fontSize: 10, 
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- LISTEN ELEMENTE & POPUPS ---

  Widget _buildFileItem(BuildContext context, FileVaultController controller, VfsNode node) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TechCard(
        borderColor: node.isSelected 
            ? AppColors.primary 
            : node.type == VfsNodeType.folder 
                ? AppColors.accent.withValues(alpha: 0.3) 
                : Colors.white.withValues(alpha: 0.05),
        
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
                color: node.color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: node.color.withValues(alpha: 0.3)),
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
    // Paste Mode (Clipboard nicht leer)
    if (controller.canPaste && !controller.isSelectionMode) {
       return TechCard(
        borderColor: AppColors.accent,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildActionButton(Icons.close, "CLEAR CLIPBOARD", () {
               controller._clipboardNodes.clear(); 
               controller.notifyListeners();
            }, isDanger: true),
            
            _buildActionButton(Icons.content_paste, "PASTE HERE", () => controller.pasteFiles()),
          ],
        ),
      );
    }

    // Normaler Selection Mode
    return TechCard(
      borderColor: AppColors.primary,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildActionButton(Icons.close, "CANCEL", () => controller.clearSelection()),
          _buildActionButton(Icons.copy, "COPY", () => controller.copySelection()),
          _buildActionButton(Icons.drive_file_move, "MOVE", () => controller.cutSelection()),
          _buildActionButton(Icons.download, "GET", () => controller.downloadSelection()),
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

  void _showSortMenu(BuildContext context, FileVaultController controller) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.card.withValues(alpha: 0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: AppColors.primary.withValues(alpha: 0.5))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "SORT SYSTEM NODES", 
              style: TextStyle(
                color: AppColors.primary, 
                fontWeight: FontWeight.bold, 
                letterSpacing: 2
              )
            ),
            const SizedBox(height: 20),
            _buildSortOption(ctx, controller, "NAME (A-Z)", SortOption.name, Icons.sort_by_alpha),
            _buildSortOption(ctx, controller, "DATE (TIME)", SortOption.date, Icons.calendar_today),
            _buildSortOption(ctx, controller, "SIZE (BYTES)", SortOption.size, Icons.data_usage),
            _buildSortOption(ctx, controller, "TYPE (FORMAT)", SortOption.type, Icons.category),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSortOption(BuildContext ctx, FileVaultController ctrl, String label, SortOption opt, IconData icon) {
    final isSelected = ctrl.currentSort == opt;
    return ListTile(
      leading: Icon(icon, color: isSelected ? AppColors.accent : Colors.grey),
      title: Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.grey, fontFamily: 'Rajdhani', fontWeight: FontWeight.bold)),
      trailing: isSelected 
        ? Icon(ctrl.sortAscending ? Icons.arrow_upward : Icons.arrow_downward, color: AppColors.accent)
        : null,
      onTap: () {
        ctrl.changeSort(opt);
        Navigator.pop(ctx);
      },
    );
  }
}