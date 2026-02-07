import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

import 'screens/data_link_screen.dart';
import 'screens/system_pulse.dart';
import 'screens/sync_paste.dart';
import 'screens/file_vault.dart';
import 'widgets/dynamic_island_widget.dart';
import 'services/notification_helper.dart';
import 'services/file_server_service.dart';
import 'services/heartbeat_service.dart';
import 'config/server_config.dart';

import 'ui/theme_constants.dart';
import 'ui/scifi_background.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationHelper.initialize();
  runApp(const QualityLinkApp());
}

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

class QualityLinkApp extends StatelessWidget {
  const QualityLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QualityLink Hybrid',
      debugShowCheckedModeBanner: false,
      theme: buildSciFiTheme(), // ✅ Unser neues Theme nutzen
      home: const SciFiBackground( // ✅ Den Hintergrund global setzen
        child: MainSystemShell(),
      ),
    );
  }
}

class MainSystemShell extends StatefulWidget {
  const MainSystemShell({super.key});
  @override
  State<MainSystemShell> createState() => _MainSystemShellState();
}

class _MainSystemShellState extends State<MainSystemShell> with WidgetsBindingObserver {
  int _currentIndex = 0;
  late String _myClientId;
  String _myDeviceName = "Init...";
  bool _isInitializing = true;
  
  final HeartbeatService _heartbeatService = HeartbeatService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initId();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeatService.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _heartbeatService.pause();
    } else if (state == AppLifecycleState.resumed) {
      _heartbeatService.resume();
    }
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
    } catch (e) {}
    
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
    
    if (Platform.isAndroid) {
      await _requestStoragePermissions();
    }
    
    final port = await FileServerService.start();
    if (port != null) {
      await prefs.setInt('file_server_port', port);
    }
    
    await _heartbeatService.start(
      clientId: _myClientId,
      deviceName: _myDeviceName,
      fileServerPort: port,
    );
    
    setState(() {
      _isInitializing = false;
    });
    Future.delayed(const Duration(seconds: 2), () {
        FileServerService.syncLocalIndex(
            serverBaseUrl, 
            _myClientId
        );
    });
    
  }

  Future<void> _requestStoragePermissions() async {
    if (Platform.isAndroid) {
      await Permission.storage.request();
      if (await Permission.manageExternalStorage.isDenied) {
        await Permission.manageExternalStorage.request();
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return const Scaffold(
        backgroundColor: Color(0xFF050505),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Color(0xFF00FF41)),
              SizedBox(height: 20),
              Text(
                "Initializing QualityLink...",
                style: TextStyle(color: Color(0xFF00FF41), fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }
    
    final List<Widget> screens = [
      DataLinkScreen(clientId: _myClientId, deviceName: _myDeviceName),
      SharedClipboardScreen(clientId: _myClientId, deviceName: _myDeviceName),
      // UPDATE: Wir geben die ID und den Namen weiter!
      NetworkStorageScreen(myClientId: _myClientId, myDeviceName: _myDeviceName),
      const SystemMonitorScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: screens),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.import_export), label: "DATALINK"),
          BottomNavigationBarItem(icon: Icon(Icons.content_paste), label: "SYNCPASTE"),
          BottomNavigationBarItem(icon: Icon(Icons.storage), label: "FILEVAULT"),
          BottomNavigationBarItem(icon: Icon(Icons.terminal), label: "SYSTEMPULSE"),
        ],
      ),
    );
  }
}