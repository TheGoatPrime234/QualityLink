import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart'; // ✅ WICHTIG für Android 11+

import 'data_link_service.dart';

class FileServerService {
  static HttpServer? _server;
  static int? _port;
  static bool _isRunning = false;
  
  static List<String> _availablePaths = [];

  static Future<int?> start() async {
    if (_isRunning) {
      print("⚠️ File Server already running on port $_port");
      return _port;
    }

    try {
      // Permissions prüfen
      if (Platform.isAndroid) {
        print("📱 Android detected - checking permissions...");
        
        // Android 13+
        if (await Permission.photos.isDenied) {
          await Permission.photos.request();
        }
        if (await Permission.videos.isDenied) {
          await Permission.videos.request();
        }
        
        // Android 11+
        if (await Permission.manageExternalStorage.isDenied) {
          print("🔐 Requesting MANAGE_EXTERNAL_STORAGE...");
          final status = await Permission.manageExternalStorage.request();
          if (!status.isGranted) {
            print("❌ MANAGE_EXTERNAL_STORAGE not granted");
          }
        }
        
        // Legacy Storage
        final storageStatus = await Permission.storage.request();
        if (!storageStatus.isGranted) {
          print("❌ Storage permission not granted");
        }
      }

      // Verfügbare Pfade ermitteln
      _availablePaths = await _getAvailablePaths();
      
      if (_availablePaths.isEmpty) {
        print("⚠️ No available storage paths found!");
        // Trotzdem Server starten, aber ohne Pfade
      } else {
        print("📁 Available paths: $_availablePaths");
      }
      
      // Server starten
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 8001);
      } catch (e) {
        print("⚠️ Port 8001 belegt, weiche auf zufälligen Port aus...");
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      }
      
      _port = _server!.port;
      _isRunning = true;

      print("✅ File Server started on port $_port");

      _server!.listen((HttpRequest request) async {
        try {
          await _handleRequest(request);
        } catch (e) {
          print("❌ Request error: $e");
          request.response.statusCode = 500;
          request.response.write(json.encode({"error": e.toString()}));
          await request.response.close();
        }
      });

      return _port;
    } catch (e) {
      print("❌ Failed to start file server: $e");
      return null;
    }
  }

  static Future<void> stop() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _port = null;
      _isRunning = false;
      print("🛑 File Server stopped");
    }
  }

  static int? get port => _port;
  static List<String> get availablePaths => _availablePaths;

  /// ✅ VERBESSERT: Android 11+ kompatibel
  static Future<List<String>> _getAvailablePaths() async {
    List<String> paths = [];

    if (Platform.isAndroid) {
      print("🔍 Detecting Android storage paths...");
      
      try {
        // Methode 1: Versuche Standard-Pfade (Android 10 und älter)
        const basePath = "/storage/emulated/0";
        final standardPaths = [
          "$basePath/Download",
          "$basePath/Documents",
          "$basePath/Pictures",
          "$basePath/DCIM",
          "$basePath/Music",
          "$basePath/Movies",
        ];
        
        for (var path in standardPaths) {
          try {
            final dir = Directory(path);
            if (await dir.exists()) {
              // Teste ob wir Zugriff haben
              await dir.list(recursive: false).first;
              paths.add(path);
              print("  ✅ $path accessible");
            }
          } catch (e) {
            print("  ❌ $path not accessible: $e");
          }
        }
        
        // Methode 2: Falls keine Standard-Pfade funktionieren (Android 11+)
        if (paths.isEmpty) {
          print("⚠️ Standard paths not accessible, using app directories...");
          
          // App-eigene Verzeichnisse (immer verfügbar)
          final externalDir = await getExternalStorageDirectory();
          if (externalDir != null) {
            paths.add(externalDir.path);
            print("  ✅ App external dir: ${externalDir.path}");
          }
          
          final downloadDir = await getDownloadsDirectory();
          if (downloadDir != null) {
            paths.add(downloadDir.path);
            print("  ✅ App downloads dir: ${downloadDir.path}");
          }
        }
        
      } catch (e) {
        print("❌ Error detecting Android paths: $e");
      }
      
    } else if (Platform.isWindows) {
      final username = Platform.environment['USERNAME'] ?? 'User';
      final userPath = 'C:\\Users\\$username';
      
      paths = [
        '$userPath\\Downloads',
        '$userPath\\Documents',
        '$userPath\\Pictures',
        '$userPath\\Videos',
        '$userPath\\Music',
        '$userPath\\Desktop',
      ];
      
      paths = paths.where((path) => Directory(path).existsSync()).toList();
    }

    print("📊 Final available paths: ${paths.length}");
    return paths;
  }

  static Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    print("📥 Request: ${request.method} $path");

    if (path == "/files/list") {
      await _handleListFiles(request);
    } else if (path == "/files/download") {
      await _handleDownload(request);
    } else if (path == "/files/info") {
      await _handleFileInfo(request);
    } else if (path == "/files/paths") {
      await _handleGetPaths(request);
    } else if (path == "/ping") {
      await _handlePing(request);
    } else if (path == "/files/search") { // ✅ NEU: Search Endpoint
      await _handleSearchFiles(request);
    } else if (path == "/files/delete") { // ✅ NEU: Delete Route
      await _handleDeleteFile(request);
    } else if (path == "/files/share") { // ✅ NEU: Share Route
      await _handleShareFile(request);
    } else {
      request.response.statusCode = 404;
      request.response.write(json.encode({"error": "Endpoint not found"}));
      await request.response.close();
    }
  }

  static Future<void> _handlePing(HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.write(json.encode({
      "status": "ok",
      "port": _port,
      "available_paths": _availablePaths
    }));
    await request.response.close();
  }

  static Future<void> _handleGetPaths(HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.write(json.encode({
      "paths": _availablePaths
    }));
    await request.response.close();
  }

  static Future<void> _handleListFiles(HttpRequest request) async {
    final pathParam = request.uri.queryParameters['path'];
    
    if (pathParam == null || pathParam.isEmpty) {
      request.response.statusCode = 400;
      request.response.write(json.encode({"error": "Missing path parameter"}));
      await request.response.close();
      return;
    }

    if (!_isPathAllowed(pathParam)) {
      request.response.statusCode = 403;
      request.response.write(json.encode({"error": "Access denied"}));
      await request.response.close();
      return;
    }

    final dir = Directory(pathParam);
    
    if (!dir.existsSync()) {
      request.response.statusCode = 404;
      request.response.write(json.encode({"error": "Directory not found"}));
      await request.response.close();
      return;
    }

    try {
      final entities = dir.listSync();
      final fileList = [];

      for (var entity in entities) {
        try {
          final stat = entity.statSync();
          final isDirectory = entity is Directory;
          
          fileList.add({
            "name": p.basename(entity.path),
            "path": entity.path,
            "is_directory": isDirectory,
            "size": isDirectory ? 0 : stat.size,
            "modified": stat.modified.millisecondsSinceEpoch,
            "type": isDirectory ? "folder" : _getFileType(entity.path),
          });
        } catch (e) {
          print("⚠️ Skipping ${entity.path}: $e");
        }
      }

      request.response.statusCode = 200;
      request.response.write(json.encode({
        "path": pathParam,
        "files": fileList,
        "count": fileList.length
      }));
      await request.response.close();
    } catch (e) {
      request.response.statusCode = 500;
      request.response.write(json.encode({"error": e.toString()}));
      await request.response.close();
    }
  }

  // ✅ NEU: Rekursive Suchfunktion
  static Future<void> _handleSearchFiles(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final rootPath = params['path'];
    final query = params['query']?.toLowerCase();
    
    if (rootPath == null || query == null || query.isEmpty) {
      request.response.statusCode = 400;
      request.response.write(json.encode({"error": "Missing path or query"}));
      await request.response.close();
      return;
    }

    if (!_isPathAllowed(rootPath)) {
      request.response.statusCode = 403;
      request.response.write(json.encode({"error": "Access denied"}));
      await request.response.close();
      return;
    }

    final dir = Directory(rootPath);
    if (!dir.existsSync()) {
      request.response.statusCode = 404;
      request.response.write(json.encode({"error": "Directory not found"}));
      await request.response.close();
      return;
    }

    final results = <Map<String, dynamic>>[];
    
    // Starte Suche (mit Limit um Crashs bei "a" zu vermeiden)
    await _recursiveSearch(dir, query, results, limit: 100);

    request.response.statusCode = 200;
    request.response.write(json.encode({
      "query": query,
      "files": results,
      "count": results.length
    }));
    await request.response.close();
  }

  static Future<void> _recursiveSearch(
    Directory dir, 
    String query, 
    List<Map<String, dynamic>> results, 
    {int limit = 100}
  ) async {
    if (results.length >= limit) return;

    try {
      final entities = dir.listSync(recursive: false); // Nicht direkt rekursiv, um Kontrolle zu behalten
      
      for (var entity in entities) {
        if (results.length >= limit) break;
        
        // Prüfen ob Name passt
        final name = p.basename(entity.path);
        if (name.toLowerCase().contains(query)) {
          final isDirectory = entity is Directory;
          int size = 0;
          int modified = 0;
          
          try {
            final stat = entity.statSync();
            size = stat.size;
            modified = stat.modified.millisecondsSinceEpoch;
          } catch (e) {}

          results.add({
            "name": name,
            "path": entity.path,
            "is_directory": isDirectory,
            "size": isDirectory ? 0 : size,
            "modified": modified,
            "type": isDirectory ? "folder" : _getFileType(entity.path),
          });
        }

        // Rekursion: Wenn es ein Ordner ist, tauche tiefer ein
        if (entity is Directory) {
           // Skip System Folder / Hidden Folders
           if (!name.startsWith('.') && !name.startsWith(r'$')) {
             await _recursiveSearch(entity, query, results, limit: limit);
           }
        }
      }
    } catch (e) {
      // Zugriff verweigert ignorieren
    }
  }

  // ✅ NEU: Datei oder Ordner löschen
  static Future<void> _handleDeleteFile(HttpRequest request) async {
    // Nur DELETE oder POST erlauben
    if (request.method != 'DELETE' && request.method != 'POST') {
       request.response.statusCode = 405; // Method Not Allowed
       await request.response.close();
       return;
    }

    final pathParam = request.uri.queryParameters['path'];
    
    if (pathParam == null || pathParam.isEmpty) {
      request.response.statusCode = 400;
      request.response.write(json.encode({"error": "Missing path parameter"}));
      await request.response.close();
      return;
    }

    // Sicherheitscheck: Darf dieser Pfad bearbeitet werden?
    if (!_isPathAllowed(pathParam)) {
      request.response.statusCode = 403;
      request.response.write(json.encode({"error": "Access denied"}));
      await request.response.close();
      return;
    }

    final entity = FileSystemEntity.typeSync(pathParam);
    
    if (entity == FileSystemEntityType.notFound) {
      request.response.statusCode = 404;
      request.response.write(json.encode({"error": "Item not found"}));
      await request.response.close();
      return;
    }

    try {
      if (entity == FileSystemEntityType.file) {
        await File(pathParam).delete();
        print("🗑️ Deleted file: $pathParam");
      } else if (entity == FileSystemEntityType.directory) {
        // Löscht Ordner rekursiv (Vorsicht!)
        await Directory(pathParam).delete(recursive: true);
        print("🗑️ Deleted folder: $pathParam");
      }

      request.response.statusCode = 200;
      request.response.write(json.encode({"status": "deleted", "path": pathParam}));
    } catch (e) {
      print("❌ Delete error: $e");
      request.response.statusCode = 500;
      request.response.write(json.encode({"error": "Failed to delete: $e"}));
    }
    await request.response.close();
  }

  // ✅ NEU: Triggered einen DataLink Transfer vom Server aus
  static Future<void> _handleShareFile(HttpRequest request) async {
    if (request.method != 'POST') {
       request.response.statusCode = 405;
       await request.response.close();
       return;
    }

    try {
      final content = await utf8.decoder.bind(request).join();
      final data = json.decode(content);
      
      final String? path = data['path'];
      final List<dynamic>? targetIds = data['targets']; // Liste von IDs
      final String? destinationPath = data['destination_path'];

      if (path == null || targetIds == null || targetIds.isEmpty) {
        request.response.statusCode = 400;
        request.response.write(json.encode({"error": "Missing path or targets"}));
        await request.response.close();
        return;
      }

      if (!_isPathAllowed(path)) {
        request.response.statusCode = 403;
        request.response.write(json.encode({"error": "Access denied"}));
        await request.response.close();
        return;
      }

      final file = File(path);
      if (!file.existsSync()) {
        request.response.statusCode = 404;
        request.response.write(json.encode({"error": "File not found"}));
        await request.response.close();
        return;
      }

      // 🔥 Hier rufen wir den DataLink Service auf DIESEM (Remote) Gerät auf
      // 🔥 Hier rufen wir den DataLink Service auf DIESEM (Remote) Gerät auf
      final ids = targetIds.map((e) => e.toString()).toList();
      
      DataLinkService().sendFile(
        file, 
        ids, 
        destinationPath: destinationPath // ✅ WICHTIG: Pfad weitergeben!
      ).then((_) {
        print("✅ Remote share started for $path to $destinationPath");
      }).catchError((e) {
        print("❌ Remote share failed: $e");
      });

      request.response.statusCode = 200;
      request.response.write(json.encode({"status": "transfer_started", "targets": ids.length}));

    } catch (e) {
      print("❌ Share error: $e");
      request.response.statusCode = 500;
      request.response.write(json.encode({"error": "Internal error: $e"}));
    }
    await request.response.close();
  }

  static Future<void> _handleDownload(HttpRequest request) async {
    final pathParam = request.uri.queryParameters['path'];
    
    if (pathParam == null || pathParam.isEmpty) {
      request.response.statusCode = 400;
      request.response.write(json.encode({"error": "Missing path parameter"}));
      await request.response.close();
      return;
    }

    if (!_isPathAllowed(pathParam)) {
      request.response.statusCode = 403;
      request.response.write(json.encode({"error": "Access denied"}));
      await request.response.close();
      return;
    }

    final file = File(pathParam);
    
    if (!file.existsSync()) {
      request.response.statusCode = 404;
      request.response.write(json.encode({"error": "File not found"}));
      await request.response.close();
      return;
    }

    try {
      request.response.headers.add("Content-Type", "application/octet-stream");
      request.response.headers.add("Content-Length", file.lengthSync());
      
      // 🔥 FIX: Dateinamen URL-encodieren, damit Umlaute (ä, ö, ü, ß) 
      // und Leerzeichen den HTTP-Header nicht zum Absturz bringen!
      final safeName = Uri.encodeComponent(p.basename(file.path));
      
      request.response.headers.add(
        "Content-Disposition",
        'attachment; filename="$safeName"'
      );

      await file.openRead().pipe(request.response);
    } catch (e) {
      print("❌ Download error: $e");
      request.response.statusCode = 500;
      await request.response.close();
    }
  }

  static Future<void> _handleFileInfo(HttpRequest request) async {
    final pathParam = request.uri.queryParameters['path'];
    
    if (pathParam == null || pathParam.isEmpty) {
      request.response.statusCode = 400;
      request.response.write(json.encode({"error": "Missing path parameter"}));
      await request.response.close();
      return;
    }

    if (!_isPathAllowed(pathParam)) {
      request.response.statusCode = 403;
      request.response.write(json.encode({"error": "Access denied"}));
      await request.response.close();
      return;
    }

    final entity = FileSystemEntity.typeSync(pathParam);
    
    if (entity == FileSystemEntityType.notFound) {
      request.response.statusCode = 404;
      request.response.write(json.encode({"error": "Not found"}));
      await request.response.close();
      return;
    }

    try {
      final stat = FileStat.statSync(pathParam);
      final isDirectory = entity == FileSystemEntityType.directory;
      
      request.response.statusCode = 200;
      request.response.write(json.encode({
        "name": p.basename(pathParam),
        "path": pathParam,
        "is_directory": isDirectory,
        "size": stat.size,
        "modified": stat.modified.millisecondsSinceEpoch,
        "accessed": stat.accessed.millisecondsSinceEpoch,
        "type": isDirectory ? "folder" : _getFileType(pathParam),
      }));
      await request.response.close();
    } catch (e) {
      request.response.statusCode = 500;
      request.response.write(json.encode({"error": e.toString()}));
      await request.response.close();
    }
  }

  static bool _isPathAllowed(String path) {
    final normalizedPath = p.normalize(path);
    
    for (var allowedPath in _availablePaths) {
      final normalizedAllowed = p.normalize(allowedPath);
      
      if (normalizedPath == normalizedAllowed || 
          normalizedPath.startsWith(normalizedAllowed + Platform.pathSeparator)) {
        return true;
      }
    }
    
    return false;
  }

  static Future<void> syncLocalIndex(String serverUrl, String myClientId) async {
    if (_availablePaths.isEmpty) await start(); 

    print("🔄 Scanning local files for index sync...");
    List<Map<String, dynamic>> fullIndex = [];

    for (var path in _availablePaths) {
      final dir = Directory(path);
      if (await dir.exists()) {
        await _scanDirectoryRecursive(dir, fullIndex, maxDepth: 4); 
      }
    }

    print("📤 Pushing index (${fullIndex.length} items) to server...");
    
    try {
      // 1. JSON-String erstellen
      final jsonString = json.encode({
        "client_id": myClientId,
        "files": fullIndex
      });

      // 🔥 FIX: JSON-String komprimieren (GZip)
      final compressedBody = gzip.encode(utf8.encode(jsonString));

      // 3. Komprimierte Bytes senden und dem Server per Header Bescheid sagen
      final response = await http.post(
        Uri.parse('$serverUrl/index/push'),
        headers: {
          "Content-Type": "application/json",
          "Content-Encoding": "gzip", // <--- WICHTIG! Sagt dem Server, dass es gepackt ist
        },
        body: compressedBody, // Wir senden jetzt die rohen, komprimierten Bytes
      ).timeout(const Duration(seconds: 30)); // Timeout zur Sicherheit etwas erhöhen
      
      if (response.statusCode == 200) {
        print("✅ Index sync successful!");
      } else {
        print("⚠️ Index sync failed: ${response.statusCode}");
      }
    } catch (e) {
      print("❌ Index sync error: $e");
    }
  }

  static Future<void> _scanDirectoryRecursive(
    Directory dir, 
    List<Map<String, dynamic>> indexList, 
    {int currentDepth = 0, int maxDepth = 4}
  ) async {
    if (currentDepth > maxDepth) return;
    if (indexList.length > 5000) return; // Limit, damit JSON nicht explodiert

    try {
      final entities = dir.listSync(recursive: false);
      for (var entity in entities) {
        if (p.basename(entity.path).startsWith('.')) continue; // Versteckte ignorieren

        final isDir = entity is Directory;
        int size = 0;
        int modified = 0;

        if (!isDir && entity is File) {
          try { size = entity.lengthSync(); } catch (_) {}
        }
        try { modified = entity.statSync().modified.millisecondsSinceEpoch; } catch (_) {}

        indexList.add({
          "name": p.basename(entity.path),
          "path": entity.path, // Absoluter Pfad (wichtig für den Zugriff später)
          "is_directory": isDir,
          "size": size,
          "modified": modified
        });

        if (isDir) {
          await _scanDirectoryRecursive(entity as Directory, indexList, 
              currentDepth: currentDepth + 1, maxDepth: maxDepth);
        }
      }
    } catch (e) {
      // Zugriff verweigert etc. ignorieren
    }
  }

  static String _getFileType(String path) {
    final ext = p.extension(path).toLowerCase();
    
    if (['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'].contains(ext)) {
      return 'image';
    } else if (['.mp4', '.mkv', '.avi', '.mov', '.webm'].contains(ext)) {
      return 'video';
    } else if (['.mp3', '.wav', '.flac', '.m4a', '.ogg'].contains(ext)) {
      return 'audio';
    } else if (['.pdf'].contains(ext)) {
      return 'pdf';
    } else if (['.doc', '.docx', '.txt', '.rtf'].contains(ext)) {
      return 'document';
    } else if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) {
      return 'archive';
    } else if (['.apk'].contains(ext)) {
      return 'apk';
    } else if (['.exe', '.msi'].contains(ext)) {
      return 'executable';
    } else {
      return 'file';
    }
  }
}