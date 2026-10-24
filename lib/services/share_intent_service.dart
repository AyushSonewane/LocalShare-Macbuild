import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/file_source.dart';

import 'share_intent_impl_mobile.dart'
    if (dart.library.html) 'share_intent_impl_stub.dart'
    as share_impl;

/// Manages incoming share intents from the OS (e.g. Android share sheet).
/// On non-Android platforms this is a no-op.
class ShareIntentService extends ChangeNotifier {
  /// Pending files as [FileSource]s — ready for transfer, zero cache copy.
  List<FileSource> _pendingFileSources = [];

  bool get hasPendingFiles => _pendingFileSources.isNotEmpty;

  List<FileSource> get pendingFileSources =>
      List.unmodifiable(_pendingFileSources);

  void initialize() {
    if (!Platform.isAndroid) return;
    share_impl.initializeShareIntent(
      // The mobile impl already builds FileSources with the correct name,
      // size, and a content URI stream factory — no conversion needed here.
      onFiles: (sources) {
        if (sources.isEmpty) return;
        _pendingFileSources = sources;
        notifyListeners();
      },
    );
  }

  List<FileSource> consumePendingFileSources() {
    final sources = List<FileSource>.from(_pendingFileSources);
    _pendingFileSources = [];
    return sources;
  }

  @override
  void dispose() {
    share_impl.disposeShareIntent();
    super.dispose();
  }
}
