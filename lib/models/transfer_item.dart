enum TransferStatus { pending, inProgress, completed, failed, cancelled }

enum TransferDirection { sending, receiving }

class TransferItem {
  final String id;
  final String fileName;
  final int fileSize;
  final TransferDirection direction;
  final String peerName;
  final String peerIp;
  String? savePath;

  TransferStatus status;
  int bytesTransferred;
  String? errorMessage;
  DateTime startTime;
  DateTime? endTime;
  double _lastSpeedBytes = 0;
  DateTime _lastSpeedCheck = DateTime.now();
  int _lastBytesForSpeed = 0;

  /// Reset the speed tracker so the first measurement starts fresh.
  /// Call this when data actually begins flowing (not at construction).
  void resetSpeedTracker() {
    _lastSpeedBytes = 0;
    _lastSpeedCheck = DateTime.now();
    _lastBytesForSpeed = bytesTransferred;
  }

  TransferItem({
    required this.id,
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.peerName,
    required this.peerIp,
    this.savePath,
    this.status = TransferStatus.pending,
    this.bytesTransferred = 0,
    this.errorMessage,
    DateTime? startTime,
  }) : startTime = startTime ?? DateTime.now();

  factory TransferItem.fromJson(Map<String, dynamic> j) {
    final item = TransferItem(
      id: j['id'] as String,
      fileName: j['fileName'] as String,
      fileSize: (j['fileSize'] as num).toInt(),
      direction: TransferDirection.values.byName(j['direction'] as String),
      peerName: j['peerName'] as String,
      peerIp: j['peerIp'] as String,
      savePath: j['savePath'] as String?,
      status: TransferStatus.values.byName(j['status'] as String),
      bytesTransferred: (j['bytesTransferred'] as num?)?.toInt() ?? 0,
      errorMessage: j['error'] as String?,
      startTime:
          DateTime.fromMillisecondsSinceEpoch((j['startTime'] as num).toInt()),
    );
    if (j['endTime'] != null) {
      item.endTime =
          DateTime.fromMillisecondsSinceEpoch((j['endTime'] as num).toInt());
    }
    return item;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'fileSize': fileSize,
        'direction': direction.name,
        'peerName': peerName,
        'peerIp': peerIp,
        if (savePath != null) 'savePath': savePath,
        'status': status.name,
        'bytesTransferred': bytesTransferred,
        'startTime': startTime.millisecondsSinceEpoch,
        if (endTime != null) 'endTime': endTime!.millisecondsSinceEpoch,
        if (errorMessage != null) 'error': errorMessage,
      };

  double get progress =>
      fileSize > 0 ? (bytesTransferred / fileSize).clamp(0.0, 1.0) : 0.0;

  double get speedBytesPerSec {
    if (status != TransferStatus.inProgress) return 0;
    final now = DateTime.now();
    final elapsed = now.difference(_lastSpeedCheck).inMilliseconds;
    if (elapsed >= 500) {
      final bytesDelta = bytesTransferred - _lastBytesForSpeed;
      // Guard against negative delta (e.g. after a speed tracker reset)
      _lastSpeedBytes = bytesDelta > 0 ? bytesDelta / (elapsed / 1000.0) : 0;
      _lastSpeedCheck = now;
      _lastBytesForSpeed = bytesTransferred;
    }
    return _lastSpeedBytes;
  }

  String get speedLabel {
    final s = speedBytesPerSec;
    if (s <= 0) return '—';
    if (s < 1024) return '${s.toStringAsFixed(0)} B/s';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)} KB/s';
    return '${(s / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String get etaLabel {
    if (status != TransferStatus.inProgress) return '—';
    final s = speedBytesPerSec;
    if (s <= 0) return '—';
    final remaining = fileSize - bytesTransferred;
    if (remaining <= 0) return '0s';
    final secs = (remaining / s).round();
    if (secs < 0) return '—';
    if (secs < 60) return '${secs}s';
    if (secs < 3600) return '${secs ~/ 60}m ${secs % 60}s';
    return '${secs ~/ 3600}h ${(secs % 3600) ~/ 60}m';
  }

  String get fileSizeLabel => _formatBytes(fileSize);
  String get transferredLabel => _formatBytes(bytesTransferred);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Duration get elapsed => (endTime ?? DateTime.now()).difference(startTime);
}
