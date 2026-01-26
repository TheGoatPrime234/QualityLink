import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

// =============================================================================
// FILE SERVER SERVICE - Läuft im Hintergrund und exponiert Dateien
// =============================================================================

class FileServerService {
  static HttpServer? _server;
  static int? _port;
  static bool _isRunning = false;
  
  static List<String> _availablePaths = [];

  /// Startet den File Server auf einem dynamischen Port
  static Future<int?> start() async {
    if (_isRunning) {
      print("⚠️ File Server already running on port $_port");
      return _port;
    }

    try {
      // Permissions prüfen
      if (Platform.isAndroid) {
        final status = await Permission.storage.request();
        if (!status.isGranted) {
          print("❌ Storage permission not granted");
          return null;
        }
      }

      // Verfügbare Pfade ermitteln
      _availablePaths = await _getAvailablePaths();
      
      // Server auf Port 0 starten (automatische Port-Zuweisung)
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = _server!.port;
      _isRunning = true;

      print("✅ File Server started on port $_port");
      print("📁 Available paths: $_availablePaths");

      // Request Handler
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

  /// Stoppt den File Server
  static Future<void> stop() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _port = null;
      _isRunning = false;
      print("🛑 File Server stopped");
    }
  }

  /// Gibt den aktuellen Port zurück
  static int? get port => _port;
  
  /// Gibt verfügbare Pfade zurück
  static List<String> get availablePaths => _availablePaths;

  /// Ermittelt verfügbare Pfade basierend auf dem OS
  static Future<List<String>> _getAvailablePaths() async {
    List<String> paths = [];

    if (Platform.isAndroid) {
      // Android Standard-Ordner
      const basePath = "/storage/emulated/0";
      paths = [
        "$basePath/Download",
        "$basePath/Documents",
        "$basePath/Pictures",
        "$basePath/DCIM",
        "$basePath/Music",
        "$basePath/Movies",
      ];
      
      // Prüfe welche existieren
      paths = paths.where((path) => Directory(path).existsSync()).toList();
      
    } else if (Platform.isWindows) {
      // Windows User-Ordner
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

    return paths;
  }

  /// Request Handler
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
    } else {
      request.response.statusCode = 404;
      request.response.write(json.encode({"error": "Endpoint not found"}));
      await request.response.close();
    }
  }

  /// Ping - Server Health Check
  static Future<void> _handlePing(HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.write(json.encode({
      "status": "ok",
      "port": _port,
      "available_paths": _availablePaths
    }));
    await request.response.close();
  }

  /// Liste verfügbare Pfade
  static Future<void> _handleGetPaths(HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.write(json.encode({
      "paths": _availablePaths
    }));
    await request.response.close();
  }

  /// Liste Dateien in einem Pfad
  static Future<void> _handleListFiles(HttpRequest request) async {
    final pathParam = request.uri.queryParameters['path'];
    
    if (pathParam == null || pathParam.isEmpty) {
      request.response.statusCode = 400;
      request.response.write(json.encode({"error": "Missing path parameter"}));
      await request.response.close();
      return;
    }

    // Security Check: Pfad muss in available_paths sein oder Unterpfad davon
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
          // Skip Dateien mit Access-Problemen
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

  /// Download Datei
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
      request.response.headers.add(
        "Content-Disposition",
        'attachment; filename="${p.basename(file.path)}"'
      );

      await file.openRead().pipe(request.response);
    } catch (e) {
      print("❌ Download error: $e");
      request.response.statusCode = 500;
      await request.response.close();
    }
  }

  /// File Info
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

  /// Security: Prüft ob Pfad erlaubt ist
  static bool _isPathAllowed(String path) {
    // Normalisiere Pfade für Vergleich
    final normalizedPath = p.normalize(path);
    
    for (var allowedPath in _availablePaths) {
      final normalizedAllowed = p.normalize(allowedPath);
      
      // Pfad muss exakt sein oder Unterpfad
      if (normalizedPath == normalizedAllowed || 
          normalizedPath.startsWith(normalizedAllowed + Platform.pathSeparator)) {
        return true;
      }
    }
    
    return false;
  }

  /// Ermittelt File-Type anhand Extension
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