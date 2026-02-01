const String serverIp = '100.109.221.18';
const String serverPort = '8000';

String get serverBaseUrl => 'http://$serverIp:$serverPort';
String get serverWsUrl => 'ws://$serverIp:$serverPort/ws';