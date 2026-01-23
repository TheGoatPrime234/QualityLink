import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- HIER WAREN DIE FEHLER ---
// Stelle sicher, dass diese Dateien existieren!
import 'screens/datalink_screen.dart';
import 'screens/system_monitor_screen.dart';
import 'screens/shared_clipboard_screen.dart';
import 'widgets/dynamic_island_widget.dart'; // <--- Das muss jetzt da sein
import 'services/notification_helper.dart';

void main() async{
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationHelper.initialize();
  runApp(const QualityLinkApp());
}

// --- WICHTIG: ENTRY POINT FÜR DIE ISLAND (MUSS HIER SEIN) ---
// WICHTIG: Das muss EXAKT so aussehen und IMPORTIERBAR sein
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const Material(
        color: Colors.transparent,
        child: DynamicIslandWidget(),
      ),
    ),
  );
}
// -----------------------------------------------------------

class QualityLinkApp extends StatelessWidget {
  const QualityLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QualityLink Hybrid',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const MainSystemShell(),
    );
  }

  ThemeData _buildTheme() {
    final base = ThemeData.dark();
    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFF050505),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFFF0055),
        secondary: Color(0xFF00FF41),
        surface: Color(0xFF101010),
      ),
      textTheme: GoogleFonts.rajdhaniTextTheme(base.textTheme).apply(
        bodyColor: const Color(0xFFEEEEEE),
        displayColor: const Color(0xFF00FF41),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
            side: BorderSide(color: Colors.white.withOpacity(0.05), width: 1),
            borderRadius: BorderRadius.circular(4)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF080808),
        selectedItemColor: Color(0xFFFF0055),
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}

class MainSystemShell extends StatefulWidget {
  const MainSystemShell({super.key});
  @override
  State<MainSystemShell> createState() => _MainSystemShellState();
}

class _MainSystemShellState extends State<MainSystemShell> {
  int _currentIndex = 0;
  late String _myClientId;
  String _myDeviceName = "Init...";

  @override
  void initState() {
    super.initState();
    _initId();
  }

  Future<void> _initId() async {
    final dev = DeviceInfoPlugin();
    String name = "Client";
    try {
      if (Platform.isWindows) name = (await dev.windowsInfo).computerName;
      if (Platform.isAndroid) {
        final i = await dev.androidInfo;
        name = "${i.brand} ${i.model}";
      }
    } catch (e) { /* ignore */ }
    
    final prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString('pid');
    if (id == null) {
      id = "${name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}_${Random().nextInt(9999)}";
      await prefs.setString('pid', id);
    }
    setState(() {
      _myDeviceName = name;
      _myClientId = id!;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> screens = [
      DataLinkScreen(clientId: _myClientId, deviceName: _myDeviceName),
      SharedClipboardScreen(clientId: _myClientId, deviceName: _myDeviceName),
      const SystemMonitorScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: screens),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.import_export), label: "DATALINK"),
          BottomNavigationBarItem(icon: Icon(Icons.content_paste), label: "CLIPBOARD"),
          BottomNavigationBarItem(icon: Icon(Icons.terminal), label: "SYSTEM LOG"),
        ],
      ),
    );
  }
}