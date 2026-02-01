import 'package:flutter/material.dart';
import 'theme_constants.dart';

class SciFiBackground extends StatelessWidget {
  final Widget child;

  const SciFiBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 1. Solid Black Base
        Container(color: AppColors.background),
        
        // 2. Grid Pattern (Custom Painter)
        Positioned.fill(
          child: Opacity(
            opacity: 0.05, // Sehr subtil
            child: CustomPaint(
              painter: GridPainter(color: AppColors.accent),
            ),
          ),
        ),
        
        // 3. Radial Vignette (macht die Ecken dunkler -> Fokus auf Mitte)
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.5,
                colors: [
                  Colors.transparent,
                  AppColors.background.withValues(alpha: 0.8),
                ],
              ),
            ),
          ),
        ),
        
        // 4. Content
        child,
      ],
    );
  }
}

class GridPainter extends CustomPainter {
  final Color color;
  GridPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    const double step = 40.0; // Gittergröße

    // Vertikale Linien
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // Horizontale Linien
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}