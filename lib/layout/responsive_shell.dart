import 'package:flutter/material.dart';
import '../ui/theme_constants.dart';
import '../ui/scifi_background.dart';

// Deine Screens importieren (damit wir sie unten in die Liste packen können)
import '../screens/data_link_screen.dart';
import '../screens/sync_paste.dart';
import '../screens/file_vault.dart';
import '../screens/system_pulse.dart';

class ResponsiveShell extends StatefulWidget {
  // Wir übergeben die ID/Namen, da deine Screens diese brauchen
  final String clientId;
  final String deviceName;

  const ResponsiveShell({
    super.key, 
    required this.clientId, 
    required this.deviceName
  });

  @override
  State<ResponsiveShell> createState() => _ResponsiveShellState();
}

class _ResponsiveShellState extends State<ResponsiveShell> {
  int _currentIndex = 0;
  bool _isRailExtended = false; // Zustand für die "einfahrbare" Leiste

  // Hier definieren wir die Screens EINMAL zentral.
  // Das löst dein Problem mit dem "Code einfügen". Du musst an deinen 
  // alten Dateien fast nichts ändern.
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      DataLinkScreen(clientId: widget.clientId, deviceName: widget.deviceName),
      SharedClipboardScreen(clientId: widget.clientId, deviceName: widget.deviceName),
      NetworkStorageScreen(myClientId: widget.clientId, myDeviceName: widget.deviceName),
      const SystemMonitorScreen(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // SciFiBackground als Basis für alles
    return SciFiBackground(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Breakpoint: Ab 800px Breite nehmen wir das Desktop-Layout
          if (constraints.maxWidth > 800) {
            return _buildDesktopLayout();
          } else {
            return _buildMobileLayout();
          }
        },
      ),
    );
  }

  // ===========================================================================
  // 🖥️ DESKTOP / TABLET LAYOUT (Links Sidebar, Rechts Inhalt + Icon)
  // ===========================================================================
  Widget _buildDesktopLayout() {
    return Scaffold(
      backgroundColor: Colors.transparent, // Hintergrund kommt vom SciFiBackground
      body: Row(
        children: [
          // 1. Die "Toolbar" (Seitenleiste)
          NavigationRail(
            backgroundColor: AppColors.card.withValues(alpha: 0.8),
            extended: _isRailExtended, // Hier steuern wir "einfahrbar"
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) => setState(() => _currentIndex = index),
            // Der Toggle-Button oben in der Leiste
            leading: IconButton(
              icon: Icon(
                _isRailExtended ? Icons.menu_open : Icons.menu, 
                color: AppColors.primary
              ),
              onPressed: () => setState(() => _isRailExtended = !_isRailExtended),
            ),
            // Die Navigations-Items
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.import_export),
                label: Text("DATALINK"),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.content_paste),
                label: Text("SYNCPASTE"),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.storage),
                label: Text("FILEVAULT"),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.terminal),
                label: Text("SYSTEMPULSE"),
              ),
            ],
            // Styling für Sci-Fi Look
            indicatorColor: AppColors.primary, 
            selectedIconTheme: const IconThemeData(color: Colors.black),
            unselectedIconTheme: const IconThemeData(color: Colors.grey),
            selectedLabelTextStyle: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold),
            unselectedLabelTextStyle: const TextStyle(color: Colors.grey),
          ),

          // Vertikale Linie für Tech-Look
          Container(width: 1, color: AppColors.primary.withValues(alpha: 0.2)),

          // 2. Der Inhalt + Das Icon oben rechts
          Expanded(
         child: _screens[_currentIndex],
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 📱 MOBILE LAYOUT (Unten Leiste, Oben Inhalt + Icon)
  // ===========================================================================
  Widget _buildMobileLayout() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      // 🔥 FIX: Stack und Positioned sind weg! Einfach nur noch die SafeArea.
      body: SafeArea(
        child: _screens[_currentIndex],
      ),

      // 2. Die "Toolbar" (Unten)
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.primary.withValues(alpha: 0.2))),
        ),
        child: BottomNavigationBar(
          backgroundColor: AppColors.card.withValues(alpha: 0.9),
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          type: BottomNavigationBarType.fixed,
          selectedItemColor: AppColors.primary,
          unselectedItemColor: Colors.grey,
          showUnselectedLabels: false,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.import_export), label: "LINK"),
            BottomNavigationBarItem(icon: Icon(Icons.content_paste), label: "PASTE"),
            BottomNavigationBarItem(icon: Icon(Icons.storage), label: "VAULT"),
            BottomNavigationBarItem(icon: Icon(Icons.terminal), label: "SYS"),
          ],
        ),
      ),
    );
  }
}
