import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import '../config/server_config.dart';

// =============================================================================
// SYSTEM MONITOR SCREEN - MODULE 2 (Enhanced with Dev/Normal Modes)
// =============================================================================
class SystemMonitorScreen extends StatefulWidget {
  const SystemMonitorScreen({super.key});

  @override
  State<SystemMonitorScreen> createState() => _SystemMonitorScreenState();
}

class _SystemMonitorScreenState extends State<SystemMonitorScreen> {
  List<String> _logLines = ["Initializing Uplink..."];
  Timer? _logTimer;
  final ScrollController _scrollController = ScrollController();
  
  // Settings
  bool _autoScroll = true;
  bool _devMode = false; // Toggle zwischen "Normal" und "Dev"

  @override
  void initState() {
    super.initState();
    _startLogStream();
  }

  @override
  void dispose() {
    _logTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _startLogStream() {
    _fetchLogs();
    _logTimer = Timer.periodic(const Duration(seconds: 2), (t) => _fetchLogs());
  }

  Future<void> _fetchLogs() async {
    try {
      // Wir laden immer die rohen Logs, filtern tun wir in der UI
      final response = await http.get(
          Uri.parse('$serverBaseUrl/logs?lines=100'));
      if (response.statusCode == 200 && mounted) {
        final newLines = LineSplitter.split(response.body)
              .where((l) => l.trim().isNotEmpty)
              .toList();

        // Nur setState machen, wenn sich was geändert hat (Performance)
        if (newLines.length != _logLines.length || 
            (newLines.isNotEmpty && newLines.last != _logLines.last)) {
          
          setState(() {
            _logLines = newLines;
          });

          if (_autoScroll && _scrollController.hasClients) {
            // Kleiner Delay, damit die Liste Zeit hat zu rendern
            Future.delayed(const Duration(milliseconds: 100), () {
              if (_scrollController.hasClients) {
                _scrollController.animateTo(
                  _scrollController.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              }
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        // Fehler nur einmal anhängen, nicht spammen
        if (!_logLines.last.contains("CONNECTION LOST")) {
           setState(() => _logLines.add("CONNECTION LOST: $e"));
        }
      }
    }
  }

  // --- LOGIC: NORMAL MODE FILTERING ---
  
  // Entscheidet, ob eine Zeile im Normal-Modus überhaupt gezeigt wird
  bool _shouldShowInNormalMode(String line) {
    if (line.contains("[CLEANUP]")) return false; // Interne Aufräumarbeiten ausblenden
    if (line.contains("uvicorn")) return false;   // Server-Technik ausblenden
    if (line.contains("Get all clipboard")) return false; // Pull Spam ausblenden
    return true;
  }

  // Hübscht die Zeile für den Normal-Modus auf
  String _formatForNormalMode(String line) {
    // Entferne den Zeitstempel am Anfang (z.B. "2023-10-25 12:00:00,000 [INFO] ")
    // Wir suchen nach dem ersten "]" und schneiden alles davor weg.
    int infoIndex = line.indexOf("] ");
    String content = line;
    
    if (infoIndex != -1 && infoIndex + 2 < line.length) {
      content = line.substring(infoIndex + 2);
    }

    // Entferne weitere technische Tags
    content = content.replaceAll("[SYSTEM]", "").trim();
    content = content.replaceAll("[HYBRID]", "").trim();
    content = content.replaceAll("[CLIPBOARD]", "").trim();
    content = content.replaceAll("[RELAY]", "").trim();
    content = content.replaceAll("[UPLOAD]", "").trim();

    return content;
  }

  IconData _getIconForLine(String line) {
    if (line.contains("ERROR") || line.contains("failed") || line.contains("verloren")) return Icons.error_outline;
    if (line.contains("CLIPBOARD") || line.contains("New entry")) return Icons.content_paste;
    if (line.contains("Upload") || line.contains("Offer")) return Icons.cloud_upload;
    if (line.contains("Download")) return Icons.cloud_download;
    if (line.contains("SYSTEM")) return Icons.system_security_update_good;
    if (line.contains("P2P") || line.contains("Direct")) return Icons.wifi_tethering;
    return Icons.info_outline;
  }

  // --- LOGIC: COLORS (Shared) ---
  Color _getLogColor(String line) {
    if (line.contains("[ERROR]") || line.contains("fail") || line.contains("verloren")) {
      return const Color(0xFFFF0055); // Red
    }
    if (line.contains("[HYBRID]") || line.contains("P2P")) {
      return const Color(0xFF00E5FF); // Cyan
    }
    if (line.contains("UPLOAD") || line.contains("DOWNLOAD")) {
      return Colors.white;
    }
    if (line.contains("RELAY") || line.contains("Cloud")) {
      return Colors.orange;
    }
    if (line.contains("SYSTEM")) {
      return const Color(0xFFFFD700); // Gold
    }
    return const Color(0xFF00FF41); // Matrix Green
  }

  @override
  Widget build(BuildContext context) {
    // Filtere die Liste für die Anzeige
    final displayList = _devMode 
        ? _logLines 
        : _logLines.where((l) => _shouldShowInNormalMode(l)).toList();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_devMode ? "SYS // KERNEL_LOG" : "SYSTEM ACTIVITY"),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          // MODE TOGGLE BUTTON
          TextButton.icon(
            onPressed: () => setState(() => _devMode = !_devMode),
            icon: Icon(
              _devMode ? Icons.terminal : Icons.remove_red_eye,
              color: _devMode ? const Color(0xFF00FF41) : Colors.white,
              size: 18,
            ),
            label: Text(
              _devMode ? "DEV MODE" : "NORMAL",
              style: TextStyle(
                color: _devMode ? const Color(0xFF00FF41) : Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            style: TextButton.styleFrom(
              backgroundColor: _devMode ? const Color(0xFF00FF41).withOpacity(0.1) : Colors.grey.withOpacity(0.2),
            ),
          ),
          const SizedBox(width: 8),
          // AUTO SCROLL BUTTON
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.arrow_circle_down : Icons.pause_circle_outline,
              color: _autoScroll ? const Color(0xFF00FF41) : Colors.grey,
            ),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
            tooltip: "Auto-scroll",
          )
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          border: Border(
              top: BorderSide(
                  color: (_devMode ? const Color(0xFF00FF41) : Colors.white).withOpacity(0.3))),
          color: const Color(0xFF050505),
        ),
        child: displayList.isEmpty 
          ? const Center(child: Text("No relevant logs found.", style: TextStyle(color: Colors.grey))) 
          : ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(8),
          itemCount: displayList.length,
          itemBuilder: (context, index) {
            final rawLine = displayList[index];
            
            if (_devMode) {
              // --- DEV MODE VIEW (Raw Terminal Style) ---
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  rawLine,
                  style: GoogleFonts.shareTechMono(
                    color: _getLogColor(rawLine),
                    fontSize: 11,
                  ),
                ),
              );
            } else {
              // --- NORMAL MODE VIEW (User Friendly) ---
              final cleanText = _formatForNormalMode(rawLine);
              final color = _getLogColor(rawLine);
              final icon = _getIconForLine(rawLine);
              
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF111111),
                  border: Border(left: BorderSide(color: color, width: 3)),
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(4),
                    bottomRight: Radius.circular(4)
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 16, color: color.withOpacity(0.8)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        cleanText,
                        style: GoogleFonts.rajdhani(
                          color: Colors.white.withOpacity(0.9),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
          },
        ),
      ),
    );
  }
}