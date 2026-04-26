import 'dart:async';
import 'dart:io';
import '../services/tcp_service.dart';

/// Pending incoming transfer that the user must accept or reject.
class IncomingRequest {
  final Socket socket;
  final String senderName;
  final List<FileEntry> files;
  final Completer<bool> completer;

  /// Completer that resolves with the list of TransferItem IDs once the
  /// receiver starts writing data (i.e. after accept + items created).
  final Completer<List<String>> transferIdsCompleter;

  IncomingRequest({
    required this.socket,
    required this.senderName,
    required this.files,
  })  : completer = Completer<bool>(),
        transferIdsCompleter = Completer<List<String>>();

  int get totalSize => files.fold(0, (s, f) => s + f.size);

  void accept() => completer.complete(true);
  void reject() => completer.complete(false);

  /// Called by the transfer service once TransferItems are created.
  void reportTransferIds(List<String> ids) {
    if (!transferIdsCompleter.isCompleted) {
      transferIdsCompleter.complete(ids);
    }
  }

  /// Future that resolves with the transfer IDs for this session.
  Future<List<String>> get transferIds => transferIdsCompleter.future;
}
