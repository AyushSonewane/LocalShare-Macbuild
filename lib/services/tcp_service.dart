import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/file_source.dart';

const int kTransferPort = 45679;

/// Handshake bytes sent by the receiver after the accept/reject dialog.
const int kAck = 0x01;
const int kNack = 0x00;

/// Receiver -> sender progress packets so sender UI mirrors receiver writes.
const int kProgressUpdate = 0x10;
const int kProgressStateInProgress = 0x00;
const int kProgressStateCompleted = 0x01;
const int kProgressStateFailed = 0x02;
const int _kProgressPacketLength = 14; // 1B type + 4B idx + 8B bytes + 1B state

typedef OnIncomingTransfer = Future<void> Function(
    Socket socket, String peerIp);

/// A single file entry in a multi-file transfer.
class FileEntry {
  final String name;
  final int size;
  const FileEntry({required this.name, required this.size});
}

/// Result of [readTransferHeader]. Subscription is **paused** after parse.
typedef TransferHeader = ({
  String senderName,
  List<FileEntry> files,
  Stream<Uint8List> bytes,
  StreamSubscription<Uint8List> subscription,
});

class TcpServerService {
  ServerSocket? _server;
  bool get isRunning => _server != null;
  int get port => kTransferPort;

  Future<void> start(OnIncomingTransfer onIncoming) async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, kTransferPort,
        shared: true);
    _server!.listen((s) {
      // Disable Nagle's algorithm so small ACK/progress packets are sent
      // immediately instead of being buffered for up to 200ms.
      try {
        s.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      onIncoming(s, s.remoteAddress.address);
    });
    debugPrint('[TcpServer] Listening on port $kTransferPort');
  }

  void stop() {
    _server?.close();
    _server = null;
  }
}

Uint8List buildTransferProgressPacket({
  required int fileIndex,
  required int bytesTransferred,
  required int state,
}) {
  final b = ByteData(_kProgressPacketLength);
  b.setUint8(0, kProgressUpdate);
  b.setUint32(1, fileIndex);
  b.setInt64(5, bytesTransferred);
  b.setUint8(13, state);
  return b.buffer.asUint8List();
}

// ── Wire format ─────────────────────────────────────────────────────────────────
// [4B senderNameLen][senderName UTF-8]
// [4B fileCount]
//   for each file: [4B fileNameLen][fileName UTF-8][8B fileSize]
// [bytes of file 0][bytes of file 1] ...
// ──────────────────────────────────────────────────────────────────────────────

typedef _ParseResult = ({
  String senderName,
  List<FileEntry> files,
  int consumed
});

_ParseResult? _tryParseHeader(Uint8List bytes) {
  int pos = 0;
  if (bytes.length < pos + 4) return null;
  final senderNameLen = ByteData.sublistView(bytes, pos, pos + 4).getUint32(0);
  pos += 4;
  if (bytes.length < pos + senderNameLen + 4) return null;
  // Use UTF-8 decoding for proper cross-platform name support
  final senderName = utf8.decode(bytes.sublist(pos, pos + senderNameLen));
  pos += senderNameLen;
  final fileCount = ByteData.sublistView(bytes, pos, pos + 4).getUint32(0);
  pos += 4;
  final files = <FileEntry>[];
  for (int i = 0; i < fileCount; i++) {
    if (bytes.length < pos + 4) return null;
    final nameLen = ByteData.sublistView(bytes, pos, pos + 4).getUint32(0);
    pos += 4;
    if (bytes.length < pos + nameLen + 8) return null;
    // Use UTF-8 decoding for proper cross-platform name support
    final name = utf8.decode(bytes.sublist(pos, pos + nameLen));
    pos += nameLen;
    final size = ByteData.sublistView(bytes, pos, pos + 8).getInt64(0);
    pos += 8;
    files.add(FileEntry(name: name, size: size));
  }
  return (senderName: senderName, files: files, consumed: pos);
}

Future<TransferHeader> readTransferHeader(Socket socket) async {
  final completer = Completer<TransferHeader>();
  final streamCtrl = StreamController<Uint8List>();
  final buffer = BytesBuilder(copy: false);
  bool headerDone = false;
  StreamSubscription<Uint8List>? sub;

  sub = socket.listen(
    (data) {
      if (!headerDone) {
        buffer.add(data);
        final r = _tryParseHeader(buffer.toBytes());
        if (r == null) return;
        headerDone = true;
        final remaining = buffer.toBytes().sublist(r.consumed);
        if (remaining.isNotEmpty) streamCtrl.add(Uint8List.fromList(remaining));
        sub?.pause();
        completer.complete((
          senderName: r.senderName,
          files: r.files,
          bytes: streamCtrl.stream,
          subscription: sub!,
        ));
      } else {
        streamCtrl.add(data);
      }
    },
    onDone: () => streamCtrl.close(),
    onError: (e) => streamCtrl.addError(e),
    cancelOnError: false,
  );

  return completer.future.timeout(const Duration(seconds: 15));
}

/// Sends the multi-file header then all file bytes sequentially.
///
/// **IMPORTANT — single subscription model:**
/// We keep a single stream subscription active throughout. After sending the
/// header we listen for the ACK byte *and* subsequent progress packets all on
/// the same subscription. This avoids the bug where calling `socket.first`
/// consumes the stream and a second `socket.listen()` never receives data on
/// some platforms (notably Windows).
Future<void> writeTransferHeader({
  required Socket socket,
  required String senderName,
  required List<FileSource> files,
  void Function(int fileIndex, int bytesTransferred, bool isCompleted)?
      onReceiverProgress,
  void Function()? onAckReceived,
  void Function(int fileIndex)? onFileStarted,
  bool Function()? isCancelled,
}) async {
  // Enable tcpNoDelay so the ACK and progress packets are not buffered.
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}

  // Build and send the header.
  final hdr = BytesBuilder();
  // Use proper UTF-8 encoding for cross-platform name support.
  final snb = utf8.encode(senderName);
  hdr.add((ByteData(4)..setUint32(0, snb.length)).buffer.asUint8List());
  hdr.add(snb);
  hdr.add((ByteData(4)..setUint32(0, files.length)).buffer.asUint8List());
  for (final f in files) {
    final nb = utf8.encode(f.name);
    hdr.add((ByteData(4)..setUint32(0, nb.length)).buffer.asUint8List());
    hdr.add(nb);
    hdr.add((ByteData(8)..setInt64(0, f.size)).buffer.asUint8List());
  }
  socket.add(hdr.toBytes());
  await socket.flush();

  // ── Single unified subscription ─────────────────────────────────────────
  // We set up ONE listener that handles:
  //   1. The ACK/NACK byte from the receiver
  //   2. All subsequent progress update packets
  // This avoids the double-subscription bug on Windows.

  final ackCompleter = Completer<bool>();
  final doneCompleter = Completer<void>();
  final completedFiles = <int>{};
  final controlBuffer = <int>[];
  bool ackReceived = false;

  final sub = socket.listen(
    (data) {
      if (!ackReceived) {
        // First byte(s) must contain the ACK/NACK response.
        // Buffer any extra bytes as the start of progress data.
        if (data.isEmpty) return;
        final firstByte = data[0];
        if (!ackCompleter.isCompleted) {
          ackCompleter.complete(firstByte == kAck);
        }
        if (firstByte == kAck) {
          ackReceived = true;
          // Any remaining bytes after the ACK byte are progress packets.
          if (data.length > 1) {
            controlBuffer.addAll(data.sublist(1));
            _processProgressBuffer(
              controlBuffer: controlBuffer,
              files: files,
              completedFiles: completedFiles,
              doneCompleter: doneCompleter,
              onReceiverProgress: onReceiverProgress,
            );
          }
        }
        return;
      }
      // ACK already received — all data is progress packets.
      controlBuffer.addAll(data);
      _processProgressBuffer(
        controlBuffer: controlBuffer,
        files: files,
        completedFiles: completedFiles,
        doneCompleter: doneCompleter,
        onReceiverProgress: onReceiverProgress,
      );
    },
    onDone: () {
      if (!ackCompleter.isCompleted) {
        ackCompleter.complete(false);
      }
      if (!doneCompleter.isCompleted) {
        if (completedFiles.length >= files.length) {
          doneCompleter.complete();
        } else {
          doneCompleter.completeError(
            Exception('Receiver disconnected before confirming completion.'),
          );
        }
      }
    },
    onError: (e) {
      if (!ackCompleter.isCompleted) ackCompleter.complete(false);
      if (!doneCompleter.isCompleted) doneCompleter.completeError(e);
    },
    cancelOnError: false,
  );

  try {
    // Wait for ACK (up to 60s, allowing human to accept/reject dialog).
    final accepted =
        await ackCompleter.future.timeout(const Duration(seconds: 60));
    if (!accepted) {
      throw Exception('Transfer declined by receiver');
    }

    onAckReceived?.call();

    // Stream all files.
    for (int i = 0; i < files.length; i++) {
      if (isCancelled?.call() == true) throw CancelledException();
      onFileStarted?.call(i);
      final stream = files[i].openRead();
      await for (final chunk in stream) {
        if (isCancelled?.call() == true) throw CancelledException();
        socket.add(chunk);
      }
    }
    await socket.flush();

    // Wait for the receiver to confirm all files written.
    // Timeout is adaptive: min 90s, +1s per MB, capped at 30 min.
    // This prevents false failures on large files over slow WiFi.
    final totalBytes = files.fold<int>(0, (s, f) => s + f.size);
    final totalMb = totalBytes ~/ (1024 * 1024);
    final timeoutSecs = (90 + totalMb).clamp(90, 1800);
    await doneCompleter.future.timeout(Duration(seconds: timeoutSecs));
  } finally {
    await sub.cancel();
  }
}

/// Drains and processes all complete progress packets from [controlBuffer].
void _processProgressBuffer({
  required List<int> controlBuffer,
  required List<FileSource> files,
  required Set<int> completedFiles,
  required Completer<void> doneCompleter,
  void Function(int fileIndex, int bytesTransferred, bool isCompleted)?
      onReceiverProgress,
}) {
  while (controlBuffer.length >= _kProgressPacketLength) {
    if (controlBuffer.first != kProgressUpdate) {
      // Best-effort re-sync if the stream is misaligned.
      controlBuffer.removeAt(0);
      continue;
    }
    final packet =
        Uint8List.fromList(controlBuffer.sublist(0, _kProgressPacketLength));
    final bd = ByteData.sublistView(packet);
    final idx = bd.getUint32(1);
    final bytes = bd.getInt64(5);
    final state = bd.getUint8(13);
    final safeBytes = bytes < 0 ? 0 : bytes;

    final isCompleted = state == kProgressStateCompleted;
    onReceiverProgress?.call(idx, safeBytes, isCompleted);

    if (isCompleted) {
      completedFiles.add(idx);
      if (!doneCompleter.isCompleted &&
          completedFiles.length >= files.length) {
        doneCompleter.complete();
      }
    } else if (state == kProgressStateFailed) {
      if (!doneCompleter.isCompleted) {
        doneCompleter.completeError(
          Exception('Receiver failed while writing file data.'),
        );
      }
    }

    controlBuffer.removeRange(0, _kProgressPacketLength);
  }
}

/// Thrown when the sender cancels an in-progress transfer.
class CancelledException implements Exception {
  const CancelledException();
  @override
  String toString() => 'Transfer cancelled by user.';
}
