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
  
  final String? senderName; // 🔥 NEU
  final String? targetName; // 🔥 NEU

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
    this.senderName, // 🔥 NEU
    this.targetName, // 🔥 NEU
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
    String? senderName,
    String? targetName,
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
      senderName: senderName ?? this.senderName,
      targetName: targetName ?? this.targetName,
    );
  }

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

    String? destPath = meta['destination_path'] as String?;
    if (destPath == null && meta['direct_link'] != null) {
      try {
        final uri = Uri.parse(meta['direct_link']);
        destPath = uri.queryParameters['save_path'];
      } catch (e) {}
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
      destinationPath: destPath,
      senderName: meta['sender_name'] as String?, // 🔥 NEU
      targetName: meta['target_name'] as String?, // 🔥 NEU
    );
  }

  String get sizeFormatted {
    if (fileSize < 1024) return "$fileSize B";
    if (fileSize < 1024 * 1024) return "${(fileSize / 1024).toStringAsFixed(1)} KB";
    if (fileSize < 1024 * 1024 * 1024) return "${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB";
    return "${(fileSize / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }
  String get progressFormatted => "${(progress * 100).toStringAsFixed(0)}%";
  bool get isCompleted => status == TransferStatus.completed;
  bool get isFailed => status == TransferStatus.failed;
  bool get isActive => !isCompleted && !isFailed && status != TransferStatus.cancelled;
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