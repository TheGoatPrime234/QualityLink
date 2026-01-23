import 'dart:io';

/// Network Debugging Utility
class NetworkDebug {
  /// Test ob ein Port auf einer IP erreichbar ist
  static Future<bool> canReachHost(String ip, int port, {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final socket = await Socket.connect(ip, port, timeout: timeout);
      socket.destroy();
      print("✅ Can reach $ip:$port");
      return true;
    } catch (e) {
      print("❌ Cannot reach $ip:$port - Error: $e");
      return false;
    }
  }

  /// Teste alle verfügbaren Network Interfaces
  static Future<void> printAllInterfaces() async {
    print("📡 === NETWORK INTERFACES ===");
    for (var interface in await NetworkInterface.list()) {
      print("Interface: ${interface.name}");
      for (var addr in interface.addresses) {
        print("  - ${addr.type.name}: ${addr.address}");
      }
    }
    print("============================");
  }

  /// Teste ob wir von außen erreichbar sind
  static Future<bool> testOwnServer(String myIp, int myPort) async {
    print("🧪 Testing own P2P server at $myIp:$myPort...");
    return await canReachHost(myIp, myPort, timeout: const Duration(seconds: 5));
  }
}