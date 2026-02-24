import 'package:flutter/material.dart';
import 'dart:math' as math;

// =============================================================================
// FUTURISTIC PROGRESS BAR
// =============================================================================
enum ProgressBarMode {
  zipping,    // 🟣 Lila
  uploading,  // 🟢 Grün
  p2p,        // 🔵 Cyan
  relay,      // 🟠 Orange
}

class FuturisticProgressBar extends StatefulWidget {
  final double progress; 
  final String label;
  final ProgressBarMode mode;
  final String? subtitle; 
  final VoidCallback? onCancel; // 🔥 NEU: Cancel Callback

  const FuturisticProgressBar({
    super.key,
    required this.progress,
    required this.label,
    required this.mode,
    this.subtitle,
    this.onCancel, // 🔥 NEU
  });

  @override
  State<FuturisticProgressBar> createState() => _FuturisticProgressBarState();
}

class _FuturisticProgressBarState extends State<FuturisticProgressBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _getColor() {
    switch (widget.mode) {
      case ProgressBarMode.zipping:
        return const Color(0xFFAA00FF); // Lila
      case ProgressBarMode.uploading:
        return const Color.fromARGB(255, 0, 255, 98);
      case ProgressBarMode.p2p:
        return const Color(0xFF00E5FF); // Cyan
      case ProgressBarMode.relay:
        return const Color(0xFF40E0D0); // Türkis
    }
  }

  String _getIcon() {
    switch (widget.mode) {
      case ProgressBarMode.zipping:
        return "📦";
      case ProgressBarMode.uploading:
        return "⬆️";
      case ProgressBarMode.p2p:
        return "⚡";
      case ProgressBarMode.relay:
        return "☁️";
    }
  }

@override
  Widget build(BuildContext context) {
    final color = _getColor();
    final icon = _getIcon();

    // 🔥 FIX: Mit GestureDetector umschließen, um Klicks abzufangen
    return GestureDetector(
      onTap: widget.onCancel,
      child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.2),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Text(
                  icon,
                  style: const TextStyle(fontSize: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
                Text(
                  "${(widget.progress * 100).toStringAsFixed(0)}%",
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                // 🔥 NEU: Das X-Icon wird direkt neben der %-Anzeige in die Row eingefügt
                if (widget.onCancel != null) ...[
                  const SizedBox(width: 12),
                  Icon(Icons.cancel_outlined, color: color, size: 20),
                ]
              ],
            ),

            if (widget.subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                widget.subtitle!,
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 10,
                ),
              ),
            ],

            const SizedBox(height: 12),
            
            // ... (Hier geht es ganz normal mit Stack und Progress Bar weiter) ...

          // Progress Bar
          Stack(
            children: [
              // Background Track
              Container(
                height: 8,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  border: Border.all(color: color.withOpacity(0.3), width: 1),
                ),
              ),

              // Animated Scanning Line (moves across)
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Positioned(
                    left: _controller.value * MediaQuery.of(context).size.width,
                    child: Container(
                      width: 2,
                      height: 8,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            color.withOpacity(0.0),
                            color,
                            color.withOpacity(0.0),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: color,
                            blurRadius: 10,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),

              // Progress Fill
              FractionallySizedBox(
                widthFactor: widget.progress,
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        color,
                        color.withOpacity(0.6),
                      ],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                  ),
                ),
              ),

              // Glowing Edge at Progress
              if (widget.progress > 0)
                Positioned(
                  left: (MediaQuery.of(context).size.width - 32) * widget.progress,
                  child: Container(
                    width: 3,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      boxShadow: [
                        BoxShadow(
                          color: color,
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),

              // Hexagon Pattern Overlay
              ClipRect(
                child: FractionallySizedBox(
                  widthFactor: widget.progress,
                  child: CustomPaint(
                    size: const Size(double.infinity, 8),
                    painter: HexagonPatternPainter(color: color),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }
}

// =============================================================================
// HEXAGON PATTERN PAINTER (Cyberpunk Style)
// =============================================================================
class HexagonPatternPainter extends CustomPainter {
  final Color color;

  HexagonPatternPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(0.1)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    const hexSize = 4.0;
    for (double x = 0; x < size.width; x += hexSize * 1.5) {
      for (double y = 0; y < size.height; y += hexSize) {
        _drawHexagon(canvas, Offset(x, y), hexSize, paint);
      }
    }
  }

  void _drawHexagon(Canvas canvas, Offset center, double radius, Paint paint) {
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = (math.pi / 3) * i;
      final x = center.dx + radius * math.cos(angle);
      final y = center.dy + radius * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// =============================================================================
// COMPACT PROGRESS INDICATOR (für Minimize)
// =============================================================================
class CompactProgressIndicator extends StatelessWidget {
  final double progress;
  final ProgressBarMode mode;

  const CompactProgressIndicator({
    super.key,
    required this.progress,
    required this.mode,
  });

  Color _getColor() {
    switch (mode) {
      case ProgressBarMode.zipping:
        return const Color(0xFFAA00FF);
      case ProgressBarMode.uploading:
        return const Color(0xFF00FF41);
      case ProgressBarMode.p2p:
        return const Color(0xFF00E5FF);
      case ProgressBarMode.relay:
        return const Color(0xFFFF8800);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _getColor();

    return SizedBox(
      width: 60,
      height: 60,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Circular Progress
          SizedBox(
            width: 50,
            height: 50,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 3,
              backgroundColor: const Color(0xFF1A1A1A),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          // Percentage
          Text(
            "${(progress * 100).toInt()}%",
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}