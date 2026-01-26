// --- GLOBAL CONFIG ---
const String serverIp = '100.109.221.18'; // TAILSCALE IP
const String serverPort = '8000';

String get serverBaseUrl => 'http://$serverIp:$serverPort';