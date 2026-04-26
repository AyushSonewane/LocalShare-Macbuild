import 'dart:async';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

typedef SharedFilesCallback = void Function(List<String> paths);

StreamSubscription<List<SharedMediaFile>>? _sub;

void initializeShareIntent({required SharedFilesCallback onFiles}) {
  // Handle cold-start intent
  ReceiveSharingIntent.instance
      .getInitialMedia()
      .then((files) => _handleFiles(files, onFiles))
      .catchError((_) {});

  // Handle warm-start intents
  _sub = ReceiveSharingIntent.instance
      .getMediaStream()
      .listen((files) => _handleFiles(files, onFiles), onError: (_) {});
}

void _handleFiles(List<SharedMediaFile> files, SharedFilesCallback onFiles) {
  if (files.isEmpty) return;
  final paths = files
      .map((f) => f.path)
      .where((p) => p.isNotEmpty)
      .toList();
  onFiles(paths);
}

void disposeShareIntent() {
  _sub?.cancel();
  _sub = null;
}
