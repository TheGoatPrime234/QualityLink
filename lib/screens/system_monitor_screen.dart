import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import '../config/server_config.dart';

// =============================================================================
// SYSTEM MONITOR SCREEN - MODULE 2
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
  bool _autoScroll = true;

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
      final response = await http.get(
          Uri.parse('$serverBaseUrl/logs?lines=100'));
      if (response.statusCode == 200 && mounted) {
        setState(() {
          _logLines = LineSplitter.split(response.body)
              .where((l) => l.trim().isNotEmpty)
              .toList();
        });

        if (_autoScroll && _scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _logLines = [
              "CONNECTION LOST: $e",
              "Retrying in 2 seconds..."
            ]);
      }
    }
  }

  Color _getLogColor(String line) {
    // Error Logs
    if (line.contains("[ERROR]") ||
        line.contains("fail") ||
        line.contains("verloren") ||
        line.contains("failed")) {
      return const Color(0xFFFF0055); // Red
    }
    
    // P2P / Hybrid Logs
    if (line.contains("[HYBRID]") ||
        line.contains("Magic") ||
        line.contains("P2P") ||
        line.contains("Direct")) {
      return const Color(0xFF00E5FF); // Cyan
    }
    
    // Transfer Logs
    if (line.contains("[UPLOAD]") || line.contains("[DOWNLOAD]")) {
      return Colors.white;
    }
    
    // Relay Logs
    if (line.contains("[RELAY]") || line.contains("Cloud")) {
      return Colors.orange;
    }
    
    // System Logs
    if (line.contains("[SYSTEM]") || line.contains("starting")) {
      return const Color(0xFFFFD700); // Gold
    }
    
    // Cleanup Logs
    if (line.contains("[CLEANUP]") || line.contains("expired")) {
      return Colors.grey;
    }
    
    // Default: Matrix Green
    return const Color(0xFF00FF41);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("SYSTEM MONITOR // LOGS"),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.lock_clock : Icons.history,
              color: _autoScroll ? const Color(0xFF00FF41) : Colors.grey,
            ),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
            tooltip: _autoScroll ? "Auto-scroll ON" : "Auto-scroll OFF",
          )
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          border: Border(
              top: BorderSide(
                  color: const Color(0xFF00FF41).withValues(alpha: 0.3))),
          color: const Color(0xFF050505),
        ),
        child: ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(8),
          itemCount: _logLines.length,
          itemBuilder: (context, index) {
            final line = _logLines[index];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                line,
                style: GoogleFonts.shareTechMono(
                  color: _getLogColor(line),
                  fontSize: 11,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}