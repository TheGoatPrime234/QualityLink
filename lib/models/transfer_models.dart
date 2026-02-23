// =============================================================================
// TRANSFER MODEL
// =============================================================================

enum TransferStatus {
  offered,
  zipping,
  uploading,
  downloading,
  relayRequested,
  relayReady,
  completed,
  failed,
  cancelled,
}

enum TransferMode {
  p2p,
  relay,
}

class Transfer {
  final String id;
  final String fileName;
  final int fileSize;
  final String senderId;
  final List<String> targetIds;
  final String? directLink;
  final TransferStatus status;
  final TransferMode? mode;
  final double progress;
  final String? statusMessage;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? errorMessage;
  final String? destinationPath;

  Transfer({
    required this.id,
    required this.fileName,
    required this.fileSize,
    required this.senderId,
    required this.targetIds,
    this.directLink,
    this.status = TransferStatus.offered,
    this.mode,
    this.progress = 0.0,
    this.statusMessage,
    DateTime? createdAt,
    this.completedAt,
    this.errorMessage,
    this.destinationPath,
  }) : createdAt = createdAt ?? DateTime.now();

  Transfer copyWith({
    String? id,
    String? fileName,
    int? fileSize,
    String? senderId,
    List<String>? targetIds,
    String? directLink,
    TransferStatus? status,
    TransferMode? mode,
    double? progress,
    String? statusMessage,
    DateTime? createdAt,
    DateTime? completedAt,
    String? errorMessage,
    String? destinationPath,
  }) {
    return Transfer(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      senderId: senderId ?? this.senderId,
      targetIds: targetIds ?? this.targetIds,
      directLink: directLink ?? this.directLink,
      status: status ?? this.status,
      mode: mode ?? this.mode,
      progress: progress ?? this.progress,
      statusMessage: statusMessage ?? this.statusMessage,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      errorMessage: errorMessage ?? this.errorMessage,
      destinationPath: destinationPath ?? this.destinationPath,
    );
  }

  // Server response zu Transfer
  factory Transfer.fromServerResponse(Map<String, dynamic> json) {
    final meta = json['meta'] as Map<String, dynamic>;
    final statusStr = json['status'] as String;
    
    TransferStatus status;
    switch (statusStr) {
      case 'OFFERED': status = TransferStatus.offered; break;
      case 'RELAY_REQUESTED': status = TransferStatus.relayRequested; break;
      case 'RELAY_READY': status = TransferStatus.relayReady; break;
      case 'COMPLETED': status = TransferStatus.completed; break;
      default: status = TransferStatus.offered;
    }

    // ✅ LOGIK: Pfad wiederherstellen
    String? destPath = meta['destination_path'] as String?;
    
    // Wenn der Server das Feld gelöscht hat, holen wir es aus dem Link zurück
    if (destPath == null && meta['direct_link'] != null) {
      try {
        final uri = Uri.parse(meta['direct_link']);
        destPath = uri.queryParameters['save_path']; // Hier lesen wir es aus!
      } catch (e) {
        // Ignorieren bei Parse-Fehlern
      }
    }

    return Transfer(
      id: meta['transfer_id'] as String,
      fileName: meta['file_name'] as String,
      fileSize: meta['file_size'] as int,
      senderId: meta['sender_id'] as String,
      targetIds: [meta['target_id'] as String],
      directLink: meta['direct_link'] as String?,
      status: status,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['timestamp'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      ),
      destinationPath: destPath, // ✅ Der wiederhergestellte Pfad
    );
  }

  String get sizeFormatted {
    if (fileSize < 1024) return "$fileSize B";
    if (fileSize < 1024 * 1024) return "${(fileSize / 1024).toStringAsFixed(1)} KB";
    if (fileSize < 1024 * 1024 * 1024) {
      return "${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB";
    }
    return "${(fileSize / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }

  String get progressFormatted {
    return "${(progress * 100).toStringAsFixed(0)}%";
  }

  bool get isCompleted => status == TransferStatus.completed;
  bool get isFailed => status == TransferStatus.failed;
  bool get isActive => !isCompleted && !isFailed && status != TransferStatus.cancelled;
}

// =============================================================================
// PEER MODEL
// =============================================================================

class Peer {
  final String id;
  final String name;
  final String type;
  final String ip;
  final bool isSameLan;
  final DateTime lastSeen;

  Peer({
    required this.id,
    required this.name,
    required this.type,
    required this.ip,
    this.isSameLan = false,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  factory Peer.fromJson(Map<String, dynamic> json, String myIp) {
    final peerIp = json['ip'] as String;
    final isSameLan = _isSameSubnet(myIp, peerIp);
    
    return Peer(
      id: json['id'] as String,
      name: json['name'] as String,
      type: json['type'] as String,
      ip: peerIp,
      isSameLan: isSameLan,
    );
  }

  static bool _isSameSubnet(String ip1, String ip2) {
    try {
      // 🔥 FIX: Wenn beide Geräte im Tailscale/VPN-Netz (100.x.x.x) sind,
      // können sie direkt kommunizieren. Sie gelten also als "Same LAN"!
      if (ip1.startsWith('100.') && ip2.startsWith('100.')) {
        return true;
      }

      final parts1 = ip1.split('.');
      final parts2 = ip2.split('.');
      if (parts1.length != 4 || parts2.length != 4) return false;
      
      // Vergleiche erste 3 Oktette (normales /24 Heim-WLAN)
      return parts1[0] == parts2[0] && 
             parts1[1] == parts2[1] && 
             parts1[2] == parts2[2];
    } catch (e) {
      return false;
    }
  }
}

// =============================================================================
// ZIP PROGRESS (für Isolate Communication)
// =============================================================================

class ZipProgress {
  final double progress;
  final String message;
  final String? resultPath;
  final String? error;

  ZipProgress({
    this.progress = 0.0,
    this.message = "",
    this.resultPath,
    this.error,
  });
}