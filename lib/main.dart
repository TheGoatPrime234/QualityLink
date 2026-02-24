import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'dart:async'; 
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'screens/data_link_screen.dart';
import 'screens/system_pulse.dart';
import 'screens/sync_paste.dart';
import 'screens/file_vault.dart';
import 'widgets/dynamic_island_widget.dart';
import 'services/notification_helper.dart';
import 'services/file_server_service.dart';
import 'services/data_link_service.dart';
import 'services/heartbeat_service.dart';
import 'config/server_config.dart';

import 'ui/theme_constants.dart';
import 'layout/responsive_shell.dart';
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
  late String _myClientId;
  String _myDeviceName = "Init...";
  bool _isInitializing = true;
  
  final HeartbeatService _heartbeatService = HeartbeatService();
  late StreamSubscription _intentDataStreamSubscription;
  List<SharedMediaFile>? _sharedFiles;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initId();
    _initShareIntent(); // 🔥 NEU
  }
  Future<void> _initShareIntent() async {
    _intentDataStreamSubscription = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> value) {
      _handleSharedData(value);
    }, onError: (err) {
      print("Intent Stream Error: $err");
    });

    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> value) {
      if (value.isNotEmpty) {
        // Kurzes Delay, damit die App-UI Zeit zum Laden hat
        Future.delayed(const Duration(seconds: 2), () => _handleSharedData(value));
      }
    });
  }

  void _handleSharedData(List<SharedMediaFile> sharedData) async {
    if (sharedData.isEmpty) return;
    
    // Cache sofort leeren, damit es bei App-Resume nicht doppelt triggert
    ReceiveSharingIntent.instance.reset(); 

    final firstItem = sharedData.first;

    // --- SZENARIO A: Es ist ein TEXT ---
    if (firstItem.type == SharedMediaType.text) {
      final textContent = firstItem.path; // Bei Text steht der Inhalt im "path"
      print("📝 TEXT EMPFANGEN: $textContent");
      
      try {
        await http.post(
          Uri.parse('$serverBaseUrl/clipboard/push'),
          headers: {"Content-Type": "application/json"},
          body: json.encode({
            "client_id": _myClientId,
            "client_name": _myDeviceName,
            "content": textContent,
            "content_type": textContent.startsWith('http') ? 'url' : 'text',
          }),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ Text an SyncPaste gesendet!"), backgroundColor: Color(0xFF00FF41)),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("❌ Fehler beim Senden: $e"), backgroundColor: const Color(0xFFFF0055)),
        );
      }
      return;
    }

    // --- SZENARIO B: Es sind DATEIEN ---
    print("📁 ${sharedData.length} DATEIEN EMPFANGEN!");
    
    // Bottom Sheet öffnen, um das Ziel-Gerät zu wählen
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0A0A0A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return FutureBuilder<http.Response>(
          future: http.get(Uri.parse('$serverBaseUrl/admin/devices')),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator(color: Color(0xFF00FF41))));
            }
            
            final data = json.decode(snapshot.data!.body);
            final List<dynamic> devices = data['devices'] ?? [];
            final onlineDevices = devices.where((d) => d['online'] == true && d['client_id'] != _myClientId).toList();

            return Container(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("SEND ${sharedData.length} FILES TO...", style: const TextStyle(color: Color(0xFF00FF41), fontWeight: FontWeight.bold, fontSize: 18, letterSpacing: 1.5)),
                  const SizedBox(height: 16),
                  
                  if (onlineDevices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text("No other online devices found.", style: TextStyle(color: Colors.grey)),
                    )
                  else
                    ...onlineDevices.map((device) => ListTile(
                      leading: const Icon(Icons.computer, color: Color(0xFF00E5FF)),
                      title: Text(device['name'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      subtitle: const Text("Online", style: TextStyle(color: Color(0xFF00FF41), fontSize: 10)),
                      tileColor: const Color(0xFF1A1A1A),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      onTap: () async {
                        Navigator.pop(context); // Sheet schließen
                        
                        // Senden via DataLink auslösen
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text("🚀 Sende an ${device['name']}..."), backgroundColor: const Color(0xFF00FF41)),
                        );
                        
                        final filesToUpload = sharedData.map((e) => File(e.path)).toList();
                        
                        try {
                          await DataLinkService().sendFiles(filesToUpload, [device['client_id']]);
                        } catch (e) {
                          print("Transfer Error: $e");
                        }
                      },
                    )),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeatService.stop();
    _intentDataStreamSubscription.cancel();
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
          child: CircularProgressIndicator(color: Color(0xFF00FF41)),
        ),
      );
    }
    
    // 🔥 HIER IST DIE ÄNDERUNG:
    // Statt selbst ein Scaffold/IndexedStack zu bauen, rufst du nur noch die Shell auf.
    return ResponsiveShell(
      clientId: _myClientId,
      deviceName: _myDeviceName,
    );
  }
}

