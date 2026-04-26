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

  /// Flag set by [cancelCurrentSend] while a send is in progress.
  bool _cancelRequested = false;

  /// Whether a file send is currently in progress.
  bool get isSending =>
      _cancelRequested == false &&
      _transfers.any(
        (t) =>
            t.direction == TransferDirection.sending &&
            (t.status == TransferStatus.inProgress ||
                t.status == TransferStatus.pending),
      );

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
        final savePath = '${saveDir.path}${Platform.pathSeparator}${f.name}';
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
            socket.add(
              buildTransferProgressPacket(
                fileIndex: fileIdx,
                bytesTransferred: items[fileIdx].bytesTransferred,
                state: kProgressStateInProgress,
              ),
            );
            await socket.flush();
            lastProgressSentBytes[fileIdx] = items[fileIdx].bytesTransferred;
            lastProgressSentAt[fileIdx] = now;
          }
          notifyListeners();
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
    } catch (e) {
      debugPrint('[FileTransfer] Receive error: $e');
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (item.status != TransferStatus.completed) {
          item.status = TransferStatus.failed;
          item.errorMessage = 'Transfer interrupted.';
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
      // close any still-open sinks
      for (int i = 0; i < sinks.length; i++) {
        try {
          await sinks[i].close();
        } catch (_) {}
      }
    } finally {
      socket.destroy();
      notifyListeners();
      _persistHistory();
      discoveryService.announceSelf();
    }
  }

  // ─── Send ─────────────────────────────────────────────────────────────────

  /// Cancels the currently in-progress send (if any).
  void cancelCurrentSend() {
    _cancelRequested = true;
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
    _cancelRequested = false;

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
      socket = await Socket.connect(target.ip, target.port,
          timeout: const Duration(seconds: 10));

      // Items stay 'pending' while we wait for the receiver to accept.
      // Per-file status is managed via callbacks below.

      await writeTransferHeader(
        socket: socket,
        senderName: _selfDevice?.name ?? 'Unknown',
        files: fileSources,
        isCancelled: () => _cancelRequested,
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
      // User cancelled — mark remaining items as cancelled
      for (final item in items) {
        if (item.status != TransferStatus.completed) {
          item.status = TransferStatus.cancelled;
        }
      }
    } catch (e) {
      final msg = _friendlyError(e);
      for (final item in items) {
        if (item.status != TransferStatus.completed) {
          item.status = TransferStatus.failed;
          item.errorMessage = msg;
        }
      }
      debugPrint('[FileTransfer] Send error: $e');
    } finally {
      _cancelRequested = false;
      await socket?.close();
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
