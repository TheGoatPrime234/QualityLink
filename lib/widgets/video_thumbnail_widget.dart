import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class VideoThumbnailWidget extends StatefulWidget {
  final String videoUrl;
  final IconData fallbackIcon;
  final Color color;

  const VideoThumbnailWidget({
    super.key,
    required this.videoUrl,
    required this.fallbackIcon,
    required this.color,
  });

  @override
  State<VideoThumbnailWidget> createState() => _VideoThumbnailWidgetState();
}

class _VideoThumbnailWidgetState extends State<VideoThumbnailWidget> {
  Uint8List? _thumbnailData;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    // 🔥 ECO- & PLATFORM-CHECK: Nur auf Handys extrahieren wir den Frame. 
    // Desktop-Systeme (Windows) nutzen das schicke statische Icon als Fallback.
    if (Platform.isAndroid || Platform.isIOS) {
      _generateThumbnail();
    } else {
      _hasError = true;
    }
  }

  Future<void> _generateThumbnail() async {
    try {
      final uint8list = await VideoThumbnail.thumbnailData(
        video: widget.videoUrl,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 120, // Spart extrem RAM und rechenleistung!
        quality: 25,   // Reicht für ein winziges Vorschaubild völlig
      );
      
      if (mounted) {
        setState(() {
          if (uint8list != null) {
            _thumbnailData = uint8list;
          } else {
            _hasError = true;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _hasError = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Wenn es lädt, zeigen wir einen winzigen Ladekreis. 
    // Wenn es fehlschlägt, das normale Icon.
    if (_hasError) {
      return Icon(widget.fallbackIcon, color: widget.color, size: 20);
    }
    if (_thumbnailData == null) {
      return Center(
        child: SizedBox(
          width: 14, height: 14, 
          child: CircularProgressIndicator(color: widget.color, strokeWidth: 2)
        )
      );
    }
    
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Das Video-Bild
          Image.memory(
            _thumbnailData!,
            fit: BoxFit.cover,
            cacheWidth: 120,
          ),
          // Ein leichter Schatten darüber, damit man das Play-Icon gut sieht
          Container(color: Colors.black.withValues(alpha: 0.4)),
          // Das Play-Icon
          const Center(
            child: Icon(Icons.play_circle_outline, color: Colors.white, size: 20),
          ),
        ],
      ),
    );
  }
}