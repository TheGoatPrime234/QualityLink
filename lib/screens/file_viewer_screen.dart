import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:google_fonts/google_fonts.dart';

import '../ui/theme_constants.dart';
import '../ui/global_topbar.dart';
import 'file_vault.dart'; // Für VfsNode und VfsNodeType

class FileViewerScreen extends StatefulWidget {
  final VfsNode node;

  const FileViewerScreen({super.key, required this.node});

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  
  // Für PDF & Text
  String? _localTempPath;
  String? _textContent;

  // Für Video
  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;

  @override
  void initState() {
    super.initState();
    _initViewer();
  }

  Future<void> _initViewer() async {
    final url = widget.node.downloadUrl;
    if (url == null) {
      setState(() => _errorMessage = "NO STREAM URL AVAILABLE");
      return;
    }

    try {
      if (widget.node.type == VfsNodeType.video) {
        _videoPlayerController = VideoPlayerController.networkUrl(Uri.parse(url));
        await _videoPlayerController!.initialize();
        _chewieController = ChewieController(
          videoPlayerController: _videoPlayerController!,
          autoPlay: true,
          looping: false,
          allowFullScreen: true,
          materialProgressColors: ChewieProgressColors(
            playedColor: AppColors.primary,
            handleColor: AppColors.primary,
            backgroundColor: Colors.grey.withValues(alpha: 0.3),
            bufferedColor: AppColors.accent.withValues(alpha: 0.5),
          ),
        );
        setState(() => _isLoading = false);
      } 
      else if (widget.node.type == VfsNodeType.pdf) {
        // PDFs müssen lokal liegen für den PDFViewer, also laden wir sie in den Cache
        final response = await http.get(Uri.parse(url));
        final tempDir = await getTemporaryDirectory();
        final file = File('${tempDir.path}/${widget.node.name}');
        await file.writeAsBytes(response.bodyBytes);
        setState(() {
          _localTempPath = file.path;
          _isLoading = false;
        });
      }
      else if (widget.node.type == VfsNodeType.document || widget.node.type == VfsNodeType.code) {
        // Textbasierte Dateien einfach herunterladen und als String lesen
        final response = await http.get(Uri.parse(url));
        setState(() {
          _textContent = response.body;
          _isLoading = false;
        });
      }
      else {
        // Bilder (und alles andere) laden wir direkt on-the-fly im build()
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() {
        _errorMessage = "FAILED TO DECODE STREAM: $e";
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _videoPlayerController?.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Topbar für Navigation
            GlobalTopbar(
              title: widget.node.name.toUpperCase(),
              statusColor: _errorMessage == null ? AppColors.primary : AppColors.warning,
              subtitle1: "DATA STREAM ANALYZER",
              subtitle2: "${(widget.node.size / 1024 / 1024).toStringAsFixed(2)} MB • ${widget.node.deviceName}",
              onSettingsTap: () => Navigator.pop(context), // Als Back-Button nutzen
            ),
            
            // Lade-Indikator
            if (_isLoading)
              const Expanded(child: Center(child: CircularProgressIndicator(color: AppColors.primary))),
            
            // Fehler-Anzeige
            if (_errorMessage != null)
              Expanded(
                child: Center(
                  child: Text(_errorMessage!, style: const TextStyle(color: AppColors.warning, fontWeight: FontWeight.bold)),
                ),
              ),

            // VIEWER BEREICH
            if (!_isLoading && _errorMessage == null)
              Expanded(
                child: _buildContentViewer(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildContentViewer() {
    switch (widget.node.type) {
      
      // 1. IMAGE VIEWER (mit Zoom!)
      case VfsNodeType.image:
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 5.0,
          child: Center(
            child: Image.network(
              widget.node.downloadUrl!,
              fit: BoxFit.contain,
              loadingBuilder: (ctx, child, progress) {
                if (progress == null) return child;
                return const Center(child: CircularProgressIndicator(color: AppColors.primary));
              },
            ),
          ),
        );

      // 2. VIDEO VIEWER
      case VfsNodeType.video:
        if (_chewieController != null && _chewieController!.videoPlayerController.value.isInitialized) {
          return Chewie(controller: _chewieController!);
        }
        return const Center(child: Text("VIDEO STREAM ERROR", style: TextStyle(color: AppColors.warning)));

      // 3. PDF VIEWER
      case VfsNodeType.pdf:
        if (_localTempPath != null) {
          return PDFView(
            filePath: _localTempPath,
            enableSwipe: true,
            swipeHorizontal: false,
            autoSpacing: true,
            pageFling: true,
            pageSnap: true,
            fitPolicy: FitPolicy.WIDTH,
          );
        }
        return const Center(child: Text("PDF STREAM ERROR", style: TextStyle(color: AppColors.warning)));

      // 4. TEXT / CODE VIEWER
      case VfsNodeType.code:
      case VfsNodeType.document:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          color: AppColors.surface,
          child: SingleChildScrollView(
            child: SelectableText(
              _textContent ?? "NO DATA",
              style: GoogleFonts.shareTechMono(color: AppColors.textMain, fontSize: 13),
            ),
          ),
        );

      // 5. UNBEKANNTES FORMAT
      default:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.node.icon, size: 80, color: Colors.grey),
              const SizedBox(height: 20),
              const Text("FORMAT NOT SUPPORTED FOR STREAMING", style: TextStyle(color: Colors.grey, letterSpacing: 2)),
            ],
          ),
        );
    }
  }
}