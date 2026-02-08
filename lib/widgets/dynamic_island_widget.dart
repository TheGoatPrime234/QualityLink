import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:google_fonts/google_fonts.dart';

import '../ui/theme_constants.dart';

class DynamicIslandWidget extends StatefulWidget {
  const DynamicIslandWidget({super.key});

  @override
  State<DynamicIslandWidget> createState() => _DynamicIslandWidgetState();
}

class _DynamicIslandWidgetState extends State<DynamicIslandWidget> with SingleTickerProviderStateMixin {
  String _status = "Initializing...";
  double _progress = 0.0;
  Color _color = AppColors.accent;
  
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    print("🏝️ Dynamic Island Widget initialized");
    
    // Pulsing Animation für den Glow-Effekt
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    FlutterOverlayWindow.overlayListener.listen((event) {
      print("📥 Overlay received data: $event");
      
      try {
        Map<String, dynamic> data;
        
        if (event is Map) {
          data = Map<String, dynamic>.from(event);
        } else {
          return;
        }
        
        if (mounted) {
          setState(() {
            if (data.containsKey('status')) {
              _status = data['status'].toString();
            }
            
            if (data.containsKey('progress')) {
              final progressValue = data['progress'];
              if (progressValue is double) {
                _progress = progressValue;
              } else if (progressValue is int) {
                _progress = progressValue.toDouble();
              } else if (progressValue is String) {
                _progress = double.tryParse(progressValue) ?? 0.0;
              }
            }
            
            if (data.containsKey('mode')) {
              final mode = data['mode'].toString();
              switch (mode) {
                case 'zipping':
                  _color = const Color(0xFFAA00FF); // Lila
                  break;
                case 'uploading':
                  _color = const Color(0xFF00FF41); // Grün
                  break;
                case 'p2p':
                  _color = const Color(0xFF00E5FF); // Cyan
                  break;
                case 'relay':
                  _color = const Color(0xFFFF8800); // Orange
                  break;
                default:
                  _color = const Color(0xFF00FF41);
              }
            }
          });
        }
      } catch (e) {
        print("❌ Error processing overlay data: $e");
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.only(top: 35, left: 16, right: 16),
        child: AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            return Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(40),
                boxShadow: [
                  // Äußerer Glow (pulsierend)
                  BoxShadow(
                    color: _color.withValues(alpha: 0.4 * _pulseAnimation.value),
                    blurRadius: 24,
                    spreadRadius: 4,
                  ),
                  // Innerer Glow
                  BoxShadow(
                    color: _color.withValues(alpha: 0.2),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(40),
                child: Stack(
                  children: [
                    // Hintergrund
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A0A0A),
                        borderRadius: BorderRadius.circular(40),
                        border: Border.all(
                          color: _color.withValues(alpha: 0.3),
                          width: 1.5,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      child: Row(
                        mainAxisSize: MainAxisSize.max,
                        children: [
                          // Icon/Spinner links
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _color.withValues(alpha: 0.15),
                              border: Border.all(
                                color: _color.withValues(alpha: 0.5),
                                width: 2,
                              ),
                            ),
                            child: Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  valueColor: AlwaysStoppedAnimation<Color>(_color),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          // Text Info
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  "QualityLink",
                                  style: GoogleFonts.rajdhani(
                                    color: _color,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                    height: 1.0,
                                    decoration: TextDecoration.none,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _status,
                                  style: GoogleFonts.rajdhani(
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    height: 1.0,
                                    decoration: TextDecoration.none,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Prozent rechts
                          Text(
                            "${(_progress * 100).toStringAsFixed(0)}%",
                            style: GoogleFonts.rajdhani(
                              color: _color,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    // PROGRESSBAR (am unteren Rand)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: const BorderRadius.only(
                            bottomLeft: Radius.circular(40),
                            bottomRight: Radius.circular(40),
                          ),
                        ),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: _progress,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  _color,
                                  _color.withValues(alpha: 0.7),
                                ],
                              ),
                              borderRadius: const BorderRadius.only(
                                bottomLeft: Radius.circular(40),
                                bottomRight: Radius.circular(40),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _color.withValues(alpha: 0.6),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}