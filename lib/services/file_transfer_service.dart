import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/device_info.dart';
import '../models/file_source.dart';
import '../models/incoming_request.dart';
import '../models/transfer_item.dart';
import 'discovery_service.dart';
import 'settings_service.dart';
import 'tcp_service.dart';

const _kHistoryKey = 'transfer_history';
const _kMaxHistory = 100;

/// A per-send cancellation token that avoids the race condition where a
/// boolean flag is reset in `finally` before the last `isCancelled` check.
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class FileTransferService extends ChangeNotifier {
  final DiscoveryService discoveryService;
  final SettingsService settingsService;
  final TcpServerService _server = TcpServerService();
  final _uuid = const Uuid();

  DeviceInfo? _selfDevice;
  bool _initialized = false;
  bool get isInitialized => _initialized;

  final List<TransferItem> _transfers = [];
  List<TransferItem> get transfers => List.unmodifiable(_transfers);

  final _requestController = StreamController<IncomingRequest>.broadcast();
  Stream<IncomingRequest> get incomingRequests => _requestController.stream;

  /// Active cancel token for the current send session.
  /// Each `sendFiles` call creates a fresh token; `cancelCurrentSend` signals it.
  CancelToken? _activeSendToken;

  /// The live socket for the current send — destroyed immediately on cancel.
  Socket? _activeSocket;

  /// Active cancel token for the current receive session.
  CancelToken? _activeReceiveToken;

  /// The live socket for the current receive — destroyed immediately on cancel.
  Socket? _activeReceiveSocket;

  /// Whether a file send is currently in progress.
  bool get isSending =>
      _activeSendToken != null &&
      !_activeSendToken!.isCancelled &&
      _transfers.any(
        (t) =>
            t.direction == TransferDirection.sending &&
            (t.status == TransferStatus.inProgress ||
                t.status == TransferStatus.pending),
      );

  /// Whether a file receive is currently in progress.
  bool get isReceiving => _transfers.any(
        (t) =>
            t.direction == TransferDirection.receiving &&
            (t.status == TransferStatus.inProgress ||
                t.status == TransferStatus.pending),
      );

  /// Rate-limiter for [notifyListeners] inside hot chunk-processing loops.
  /// Caps UI rebuilds to ~10/sec, preventing frame drops on fast links.
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  void _notifyRateLimited() {
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds >= 100) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  FileTransferService({
    required this.discoveryService,
    required this.settingsService,
  });

  Future<void> initialize(DeviceInfo self) async {
    if (_initialized) return;
    _initialized = true;
    _selfDevice = self;
    await _loadHistory();
    await discoveryService.start(self);
    await _server.start(_handleIncomingConnection);
    settingsService.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    final cur = _selfDevice;
    if (cur == null) return;
    final newName = settingsService.deviceName;
    if (newName == cur.name) return;
    _selfDevice = cur.copyWith(name: newName);
    discoveryService.updateSelf(_selfDevice!);
  }

  // ─── History persistence ──────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kHistoryKey) ?? [];
      for (final s in list) {
        try {
          _transfers.add(
              TransferItem.fromJson(jsonDecode(s) as Map<String, dynamic>));
        } catch (e, st) {
          debugPrint('[History] error decoding item $s \n $e \n $st');
        }
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[History] load error: $e');
    }
  }

  Future<void> _persistHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final done = _transfers
          .where((t) =>
              t.status == TransferStatus.completed ||
              t.status == TransferStatus.failed ||
              t.status == TransferStatus.cancelled)
          .take(_kMaxHistory)
          .map((t) => jsonEncode(t.toJson()))
          .toList();
      await prefs.setStringList(_kHistoryKey, done);
    } catch (e) {
      debugPrint('[History] persist error: $e');
    }
  }

  // ─── Receive ──────────────────────────────────────────────────────────────

  Future<void> _handleIncomingConnection(Socket socket, String peerIp) async {
    // Per-receive cancel token — set by cancelCurrentReceive() to distinguish
    // receiver-initiated cancel from sender disconnect / network errors.
    final token = CancelToken();
    _activeReceiveToken = token;
    _activeReceiveSocket = socket;
    final sinks = <IOSink>[];
    final items = <TransferItem>[];
    final lastProgressSentBytes = <int>[];
    final lastProgressSentAt = <DateTime>[];
    try {
      final header = await readTransferHeader(socket);

      final request = IncomingRequest(
        socket: socket,
        senderName: header.senderName,
        files: header.files,
      );
      _requestController.add(request);

      final accepted = await request.completer.future;
      if (!accepted) {
        // Tell the sender we rejected
        socket.add([kNack]);
        await socket.flush();
        await header.subscription.cancel();
        socket.destroy();
        return;
      }

      // Tell the sender we accepted — they will now start streaming bytes
      socket.add([kAck]);
      await socket.flush();

      // Build TransferItems for each file
      final saveDir = await _getSaveDirectory();
      for (int i = 0; i < header.files.length; i++) {
        final f = header.files[i];
        final savePath = _resolveConflict(saveDir.path, f.name);
        final item = TransferItem(
          id: _uuid.v4(),
          fileName: f.name,
          fileSize: f.size,
          direction: TransferDirection.receiving,
          peerName: header.senderName,
          peerIp: peerIp,
          savePath: savePath,
          // Only the first file is actively receiving; the rest are pending
          status: i == 0 ? TransferStatus.inProgress : TransferStatus.pending,
        );
        if (i == 0) item.resetSpeedTracker();
        items.add(item);
        sinks.add(File(savePath).openWrite());
        lastProgressSentBytes.add(0);
        lastProgressSentAt.add(DateTime.fromMillisecondsSinceEpoch(0));
        _transfers.insert(0, item);
      }
      notifyListeners();

      // Report the transfer IDs back so the UI can navigate to ReceiveScreen
      request.reportTransferIds(items.map((i) => i.id).toList());

      // Resume socket and distribute bytes across files
      header.subscription.resume();
      int fileIdx = 0;
      int fileReceived = 0;

      await for (final chunk in header.bytes) {
        // Receiver pressed cancel — break immediately; finally will clean up.
        if (token.isCancelled) break;
        int offset = 0;
        int left = chunk.length;
        while (left > 0 && fileIdx < items.length) {
          final need = header.files[fileIdx].size - fileReceived;
          final take = left < need ? left : need;
          sinks[fileIdx].add(chunk.sublist(offset, offset + take));
          items[fileIdx].bytesTransferred += take;
          final now = DateTime.now();
          final bytesDelta =
              items[fileIdx].bytesTransferred - lastProgressSentBytes[fileIdx];
          final elapsedMs =
              now.difference(lastProgressSentAt[fileIdx]).inMilliseconds;
          final shouldPushProgress =
              bytesDelta >= 64 * 1024 || elapsedMs >= 120;
          if (shouldPushProgress) {
            // Fire-and-forget — do NOT await flush() here. Awaiting flush
            // inside the chunk loop suspends receive processing until the
            // sender's TCP ACK catches up, starving throughput on slow WiFi
            // and cascading into the doneCompleter timeout on large files.
            socket.add(
              buildTransferProgressPacket(
                fileIndex: fileIdx,
                bytesTransferred: items[fileIdx].bytesTransferred,
                state: kProgressStateInProgress,
              ),
            );
            lastProgressSentBytes[fileIdx] = items[fileIdx].bytesTransferred;
            lastProgressSentAt[fileIdx] = now;
          }
          _notifyRateLimited();
          offset += take;
          left -= take;
          fileReceived += take;
          if (fileReceived >= header.files[fileIdx].size) {
            await sinks[fileIdx].flush();
            await sinks[fileIdx].close();
            items[fileIdx].status = TransferStatus.completed;
            items[fileIdx].endTime = DateTime.now();
            items[fileIdx].bytesTransferred = header.files[fileIdx].size;
            socket.add(
              buildTransferProgressPacket(
                fileIndex: fileIdx,
                bytesTransferred: items[fileIdx].bytesTransferred,
                state: kProgressStateCompleted,
              ),
            );
            await socket.flush();
            // Save to gallery if the setting is enabled (Android only)
            if (settingsService.saveToGallery && Platform.isAndroid) {
              final completedPath = items[fileIdx].savePath;
              if (completedPath != null) {
                _saveFileToMediaStore(completedPath).ignore();
              }
            }
            fileIdx++;
            fileReceived = 0;
            // Mark next file as in-progress and reset its speed tracker
            if (fileIdx < items.length) {
              items[fileIdx].status = TransferStatus.inProgress;
              items[fileIdx].resetSpeedTracker();
            }
            notifyListeners();
          }
        }
        if (fileIdx >= items.length) break;
      }

      // ── Post-loop: mark files that didn’t complete ───────────────────────────
      // Happens when the stream ends before all bytes arrive:
      //   • token.isCancelled  → receiver pressed Cancel
      //   • !token.isCancelled → sender disconnected / cancelled on their side
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (item.status == TransferStatus.inProgress ||
            item.status == TransferStatus.pending) {
          item.status = token.isCancelled
              ? TransferStatus.cancelled
              : TransferStatus.failed;
          item.errorMessage = token.isCancelled
              ? 'Transfer cancelled.'
              : 'Sender disconnected or cancelled.';
          if (item.savePath != null) {
            try {
              final f = File(item.savePath!);
              if (f.existsSync()) await f.delete();
            } catch (_) {}
          }
          try { await sinks[i].close(); } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[FileTransfer] Receive error: $e');
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (item.status != TransferStatus.completed) {
          // Receiver-initiated cancel: token is set; socket error is expected.
          item.status = token.isCancelled
              ? TransferStatus.cancelled
              : TransferStatus.failed;
          item.errorMessage = token.isCancelled
              ? 'Transfer cancelled.'
              : 'Sender disconnected or cancelled.';
          // Delete the partial file so no corrupt file remains on disk.
          if (item.savePath != null) {
            try {
              final partialFile = File(item.savePath!);
              if (partialFile.existsSync()) {
                await partialFile.delete();
                debugPrint('[FileTransfer] Deleted partial file: ${item.savePath}');
              }
            } catch (deleteErr) {
              debugPrint('[FileTransfer] Could not delete partial file: $deleteErr');
            }
          }
          // Only attempt to notify sender if receiver didn’t initiate the close.
          if (!token.isCancelled) {
            try {
              socket.add(
                buildTransferProgressPacket(
                  fileIndex: i,
                  bytesTransferred: item.bytesTransferred,
                  state: kProgressStateFailed,
                ),
              );
              await socket.flush();
            } catch (_) {}
          }
        }
      }
      // Close any still-open sinks.
      for (int i = 0; i < sinks.length; i++) {
        try {
          await sinks[i].close();
        } catch (_) {}
      }
    } finally {
      _activeReceiveToken = null;
      _activeReceiveSocket = null;
      socket.destroy();
      notifyListeners();
      _persistHistory();
      discoveryService.announceSelf();
    }
  }

  // ─── Send ─────────────────────────────────────────────────────────────────

  /// Cancels the currently in-progress send (if any).
  ///
  /// Sets the cancellation flag AND immediately destroys the socket so that
  /// any in-flight `socket.add(chunk)` throws right away, rather than waiting
  /// for the file-read loop to notice the flag between chunks.
  void cancelCurrentSend() {
    _activeSendToken?.cancel();
    // Destroy the socket immediately — this causes socket.add() to throw,
    // aborting the send loop without waiting for the next isCancelled check.
    _activeSocket?.destroy();
    _activeSocket = null;
    notifyListeners();
  }

  /// Cancels the currently in-progress receive (if any).
  ///
  /// Sets the cancel flag AND immediately destroys the socket, causing the
  /// [_handleIncomingConnection] loop to break and mark items as cancelled.
  void cancelCurrentReceive() {
    _activeReceiveToken?.cancel();
    _activeReceiveSocket?.destroy();
    _activeReceiveSocket = null;
    notifyListeners();
  }

  /// Sends multiple files to [target] over a single connection.
  /// [onItemsReady] is called synchronously with all [TransferItem]s before
  /// the transfer starts, so callers can show progress immediately.
  ///
  /// [fileSources] carries either a stream factory (preferred on Android to
  /// avoid cache copies) or a filesystem path for each file.
  Future<void> sendFiles({
    required List<FileSource> fileSources,
    required DeviceInfo target,
    void Function(List<TransferItem>)? onItemsReady,
  }) async {
    final token = CancelToken();
    _activeSendToken = token;

    // Create TransferItems upfront
    final items = fileSources
        .map((f) => TransferItem(
              id: _uuid.v4(),
              fileName: f.name,
              fileSize: f.size,
              direction: TransferDirection.sending,
              peerName: target.name,
              peerIp: target.ip,
              status: TransferStatus.pending,
            ))
        .toList();

    for (final item in items.reversed) {
      _transfers.insert(0, item);
    }
    notifyListeners();
    onItemsReady?.call(items); // notify UI before awaiting socket

    Socket? socket;
    try {
      // Check for pre-flight cancel (e.g. user tapped Cancel before connect).
      if (token.isCancelled) throw const CancelledException();

      socket = await Socket.connect(target.ip, target.port,
          timeout: const Duration(seconds: 10));

      // Store socket so cancelCurrentSend() can destroy it immediately.
      _activeSocket = socket;

      // Items stay 'pending' while we wait for the receiver to accept.
      // Per-file status is managed via callbacks below.

      await writeTransferHeader(
        socket: socket,
        senderName: _selfDevice?.name ?? 'Unknown',
        files: fileSources,
        isCancelled: () => token.isCancelled,
        onAckReceived: () {
          // Transfer accepted — first file will start momentarily
        },
        onFileStarted: (idx) {
          if (idx >= 0 &&
              idx < items.length &&
              items[idx].status == TransferStatus.pending) {
            items[idx].status = TransferStatus.inProgress;
            items[idx].resetSpeedTracker();
          }
          notifyListeners();
        },
        onReceiverProgress: (idx, bytesTransferred, isCompleted) {
          if (idx < 0 || idx >= items.length) return;
          final item = items[idx];
          final safe = bytesTransferred.clamp(0, item.fileSize);
          if (item.status == TransferStatus.pending) {
            item.status = TransferStatus.inProgress;
            item.resetSpeedTracker();
          }
          item.bytesTransferred = safe;
          if (isCompleted) {
            item.status = TransferStatus.completed;
            item.endTime = DateTime.now();
            item.bytesTransferred = item.fileSize;
          }
          notifyListeners();
        },
      );

      for (final item in items) {
        if (item.status == TransferStatus.pending ||
            item.status == TransferStatus.inProgress) {
          item.status = TransferStatus.completed;
          item.endTime = DateTime.now();
          item.bytesTransferred = item.fileSize;
        }
      }
    } on CancelledException {
      // Explicit cancellation — mark remaining items as cancelled.
      for (final item in items) {
        if (item.status != TransferStatus.completed) {
          item.status = TransferStatus.cancelled;
        }
      }
    } catch (e) {
      // If the cancel flag is set, a SocketException from socket.destroy()
      // should be treated as a user cancellation, not a failure.
      if (token.isCancelled) {
        for (final item in items) {
          if (item.status != TransferStatus.completed) {
            item.status = TransferStatus.cancelled;
          }
        }
      } else {
        final msg = _friendlyError(e);
        for (final item in items) {
          if (item.status != TransferStatus.completed) {
            item.status = TransferStatus.failed;
            item.errorMessage = msg;
          }
        }
        debugPrint('[FileTransfer] Send error: $e');
      }
    } finally {
      _activeSendToken = null;
      _activeSocket = null;
      // Use destroy() instead of close() — close() sends a TCP FIN and waits
      // for the peer to ACK, which can hang for 75–120 s if the peer is dead.
      // destroy() is immediate.
      socket?.destroy();
      // Clean up file_picker's temporary cache directory (Android copies).
      try {
        await FilePicker.platform.clearTemporaryFiles();
      } catch (_) {}
      notifyListeners();
      _persistHistory();
      discoveryService.announceSelf();
    }
  }

  static String _friendlyError(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('declined')) {
      return 'Receiver declined the request.';
    }
    if (msg.contains('connection reset') ||
        msg.contains('errno = 104') ||
        msg.contains('connection refused') ||
        msg.contains('broken pipe')) {
      return 'Receiver is not available.';
    }
    if (msg.contains('timed out') || msg.contains('timeout')) {
      return 'Connection timed out. Is the receiver online?';
    }
    return 'Transfer failed. Please try again.';
  }

  /// Returns a conflict-free save path for [fileName] inside [dirPath].
  ///
  /// If "photo.jpg" already exists, tries "photo(1).jpg", "photo(2).jpg", …
  /// until a free slot is found.
  static String _resolveConflict(String dirPath, String fileName) {
    final sep = Platform.pathSeparator;
    final candidate = '$dirPath$sep$fileName';
    if (!File(candidate).existsSync()) return candidate;

    // Split name into stem + extension, e.g. "photo.jpg" → ("photo", ".jpg")
    final dot = fileName.lastIndexOf('.');
    final String stem;
    final String ext;
    if (dot > 0) {
      stem = fileName.substring(0, dot);
      ext  = fileName.substring(dot);   // includes the dot, e.g. ".jpg"
    } else {
      stem = fileName;
      ext  = '';
    }

    int counter = 1;
    while (true) {
      final next = '$dirPath$sep$stem($counter)$ext';
      if (!File(next).existsSync()) return next;
      counter++;
    }
  }

  void removeTransfer(String id) {
    _transfers.removeWhere((t) => t.id == id);
    notifyListeners();
    _persistHistory();
  }

  void clearCompleted() {
    _transfers.removeWhere((t) =>
        t.status == TransferStatus.completed ||
        t.status == TransferStatus.failed);
    notifyListeners();
    _persistHistory();
  }

  void clearAll() {
    _transfers.clear();
    notifyListeners();
    _persistHistory();
  }

  Future<Directory> _getSaveDirectory() =>
      settingsService.effectiveSaveDirectory();

  /// Saves a file at [filePath] into the Android MediaStore so gallery apps
  /// and file managers can see it without a reboot or media scan.
  static Future<void> _saveFileToMediaStore(String filePath) async {
    try {
      final fileName = filePath.split(Platform.pathSeparator).last;
      final ext = fileName.split('.').last.toLowerCase();
      final String androidRelativePath;
      if (_imageExts.contains(ext)) {
        androidRelativePath = 'Pictures/LocalShare';
      } else if (_videoExts.contains(ext)) {
        androidRelativePath = 'Movies/LocalShare';
      } else if (_audioExts.contains(ext)) {
        androidRelativePath = 'Music/LocalShare';
      } else {
        // Non-media file — MediaStore gallery is not applicable.
        return;
      }
      final result = await SaverGallery.saveFile(
        filePath: filePath,
        fileName: fileName,
        androidRelativePath: androidRelativePath,
        skipIfExists: false,
      );
      debugPrint('[Gallery] Saved $fileName → $androidRelativePath | $result');
    } catch (e) {
      debugPrint('[Gallery] Gallery save failed for $filePath: $e');
    }
  }

  static const _imageExts = {
    'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif', 'tiff', 'tif'
  };
  static const _videoExts = {
    'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', '3gp', 'm4v'
  };
  static const _audioExts = {
    'mp3', 'aac', 'flac', 'wav', 'ogg', 'm4a', 'wma', 'opus'
  };

  @override
  void dispose() {
    settingsService.removeListener(_onSettingsChanged);
    _requestController.close();
    _server.stop();
    discoveryService.dispose();
    super.dispose();
  }
}
