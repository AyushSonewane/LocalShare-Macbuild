import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

// receive_sharing_intent is only supported on Android and iOS.
// We use a conditional import: the Android/iOS file imports the real package,
// the stub file is used for all other platforms (Windows, macOS, Linux).
import 'share_intent_impl_mobile.dart'
    if (dart.library.html) 'share_intent_impl_stub.dart'
    as share_impl;

/// Manages incoming share intents from the OS (e.g. Android share sheet).
///
/// On non-Android/iOS platforms (Windows, macOS, Linux) this is a no-op.
class ShareIntentService extends ChangeNotifier {
  List<String> _pendingFiles = [];

  /// Files shared via the OS share sheet, waiting to be consumed by the UI.
  List<String> get pendingFiles => List.unmodifiable(_pendingFiles);

  /// Whether there are shared files waiting to be sent.
  bool get hasPendingFiles => _pendingFiles.isNotEmpty;

  /// Initialize listeners for share intents.
  /// Must be called once after the widget tree is ready.
  void initialize() {
    if (!Platform.isAndroid) return;
    share_impl.initializeShareIntent(
      onFiles: (paths) {
        if (paths.isEmpty) return;
        _pendingFiles = paths;
        notifyListeners();
      },
    );
  }

  /// Consume the pending files (called by the UI once it has picked them up).
  List<String> consumePendingFiles() {
    final files = List<String>.from(_pendingFiles);
    _pendingFiles = [];
    return files;
  }

  @override
  void dispose() {
    share_impl.disposeShareIntent();
    super.dispose();
  }
}
