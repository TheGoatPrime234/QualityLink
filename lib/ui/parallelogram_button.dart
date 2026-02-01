import 'package:flutter/material.dart';
import 'theme_constants.dart';

class ParallelogramButton extends StatefulWidget {
  final String text;
  final IconData? icon;
  final VoidCallback onTap;
  final bool isLoading;
  final Color color;
  
  // Steuert die Neigung: 
  // 0.3 für Neigung nach Rechts (/)
  // -0.3 für Neigung nach Links (\)
  final double skew; 

  const ParallelogramButton({
    super.key,
    required this.text,
    required this.onTap,
    this.icon,
    this.isLoading = false,
    this.color = AppColors.accent, 
    this.skew = 0.0, // Standard: Keine Neigung
  });

  @override
  State<ParallelogramButton> createState() => _ParallelogramButtonState();
}

class _ParallelogramButtonState extends State<ParallelogramButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    // Textfarbe: Schwarz wenn gefüllt, sonst die gewählte Farbe (Cyan)
    final contentColor = _isPressed ? Colors.black : widget.color;

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        if (!widget.isLoading) widget.onTap();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      
      child: CustomPaint(
        painter: _ParallelogramPainter(
          color: widget.color,
          isPressed: _isPressed,
          skew: widget.skew, // ✅ WICHTIG: Hier muss widget.skew stehen!
        ),
        child: Container(
          // Padding sorgt dafür, dass Text nicht den schrägen Rand berührt
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min, // Nimmt nur so viel Platz wie nötig
            children: [
              if (widget.isLoading)
                SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: contentColor),
                )
              else if (widget.icon != null) ...[
                Icon(widget.icon, color: contentColor, size: 18),
                const SizedBox(width: 8),
              ],
              
              if (!widget.isLoading)
                Text(
                  widget.text.toUpperCase(),
                  style: TextStyle(
                    color: contentColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    letterSpacing: 1.2,
                    fontFamily: 'Rajdhani',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ParallelogramPainter extends CustomPainter {
  final Color color;
  final bool isPressed;
  final double skew;

  _ParallelogramPainter({
    required this.color,
    required this.isPressed,
    required this.skew,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = isPressed ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = 1.5;

    if (!isPressed) {
      // Leichter Neon-Glow
      paint.maskFilter = const MaskFilter.blur(BlurStyle.solid, 4);
    }

    final path = Path();
    
    // Berechne, wie weit sich die Kante verschiebt
    final double shift = size.height * skew.abs();
    
    if (skew > 0) {
      // Shape: /  (Rechts geneigt)
      // Wir starten oben rechts versetzt und ziehen nach unten links
      path.moveTo(shift, 0); 
      path.lineTo(size.width, 0);
      path.lineTo(size.width - shift, size.height);
      path.lineTo(0, size.height);
    } else {
      // Shape: \ (Links geneigt)
      // Wir starten oben links (0,0) und ziehen nach rechts versetzt
      path.moveTo(0, 0);
      path.lineTo(size.width - shift, 0);
      path.lineTo(size.width, size.height);
      path.lineTo(shift, size.height);
    }
    
    path.close();

    // Zeichne Schatten (optional, macht den Look "fetter")
    if (!isPressed) {
      canvas.drawPath(path, Paint()
        ..color = color.withValues(alpha: 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
      );
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ParallelogramPainter oldDelegate) {
    // ✅ WICHTIG: Das hier sorgt dafür, dass sich die Form ändert, 
    // wenn du den Code speicherst (Hot Reload)
    return oldDelegate.isPressed != isPressed || 
           oldDelegate.color != color ||
           oldDelegate.skew != skew;
  }
}