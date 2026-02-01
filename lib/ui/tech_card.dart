import 'package:flutter/material.dart';
import 'theme_constants.dart';

class TechCard extends StatelessWidget {
  final Widget child;
  final Color? borderColor;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double cornerSize;

  const TechCard({
    super.key, 
    required this.child, 
    this.borderColor, 
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.cornerSize = 10.0,
  });

  @override
  Widget build(BuildContext context) {
    final color = borderColor ?? Colors.white.withValues(alpha: 0.1);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          splashColor: (borderColor ?? AppColors.primary).withValues(alpha: 0.1),
          // Custom Clipper für abgeschnittene Ecken
          customBorder: CutCornerBorder(cutSize: cornerSize), 
          child: CustomPaint(
            painter: TechBorderPainter(color: color, cutSize: cornerSize),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                color: AppColors.card.withValues(alpha: 0.6), // Leicht transparent
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

// Malt den Rahmen mit abgeschnittenen Ecken
class TechBorderPainter extends CustomPainter {
  final Color color;
  final double cutSize;

  TechBorderPainter({required this.color, required this.cutSize});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final path = Path();
    
    // Start oben links (nach Cut)
    path.moveTo(cutSize, 0);
    // Linie nach oben rechts (vor Cut)
    path.lineTo(size.width - cutSize, 0);
    // Cut oben rechts
    path.lineTo(size.width, cutSize);
    // Linie nach unten rechts (vor Cut)
    path.lineTo(size.width, size.height - cutSize);
    // Cut unten rechts
    path.lineTo(size.width - cutSize, size.height);
    // Linie nach unten links (vor Cut)
    path.lineTo(cutSize, size.height);
    // Cut unten links
    path.lineTo(0, size.height - cutSize);
    // Linie nach oben links (vor Cut)
    path.lineTo(0, cutSize);
    path.close();

    canvas.drawPath(path, paint);
    
    // Optional: Kleine "Tech-Marker" in den Ecken
    final accentPaint = Paint()..color = color..strokeWidth = 3.0;
    canvas.drawLine(Offset(0, cutSize), Offset(0, cutSize + 10), accentPaint);
    canvas.drawLine(Offset(size.width, size.height - cutSize), Offset(size.width, size.height - cutSize - 10), accentPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Definiert die Shape für den InkWell (Klick-Effekt)
class CutCornerBorder extends OutlinedBorder {
  final double cutSize;
  const CutCornerBorder({this.cutSize = 10.0, super.side});

  @override
  CutCornerBorder copyWith({BorderSide? side, double? cutSize}) {
    return CutCornerBorder(
      side: side ?? this.side,
      cutSize: cutSize ?? this.cutSize,
    );
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return _getPath(rect);
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    // Einfache Annäherung für Inner Path (oft reicht Outer Path)
    return _getPath(rect.deflate(side.width));
  }

  Path _getPath(Rect rect) {
    return Path()
      ..moveTo(rect.left + cutSize, rect.top)
      ..lineTo(rect.right - cutSize, rect.top)
      ..lineTo(rect.right, rect.top + cutSize)
      ..lineTo(rect.right, rect.bottom - cutSize)
      ..lineTo(rect.right - cutSize, rect.bottom)
      ..lineTo(rect.left + cutSize, rect.bottom)
      ..lineTo(rect.left, rect.bottom - cutSize)
      ..lineTo(rect.left, rect.top + cutSize)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    
    // Wir malen den Rand nur, wenn er sichtbar sein soll.
    // TechCard nutzt aber meistens den CustomPainter (TechBorderPainter) für den Glow-Effekt.
    // Wenn du HoloButton nutzt, wird dieser Paint hier verwendet.
    
    final paint = side.toPaint();
    final path = _getPath(rect);
    canvas.drawPath(path, paint);
  }

  @override
  ShapeBorder scale(double t) {
    return CutCornerBorder(
      side: side.scale(t),
      cutSize: cutSize * t,
    );
  }
}