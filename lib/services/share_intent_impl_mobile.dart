import 'dart:async';
import 'package:flutter/services.dart';
import 'package:uri_content/uri_content.dart';
import '../models/file_source.dart';

// Native channels registered in MainActivity.kt.
// Kotlin already queries ContentResolver for proper display name and file size
// — we just need to carry that data all the way into FileSource.

typedef SharedFilesCallback = void Function(List<FileSource> sources);

const _shareIntentChannel =
    MethodChannel('com.example.tcp_file_share/share_intent');

const _shareEventsChannel =
    EventChannel('com.example.tcp_file_share/share_events');

StreamSubscription<dynamic>? _sub;

void initializeShareIntent({required SharedFilesCallback onFiles}) {
  // Cold-start: app was launched by the share sheet.
  _shareIntentChannel
      .invokeMethod<List<dynamic>>('getInitialShareFiles')
      .then((files) {
    if (files == null || files.isEmpty) return;
    final sources = _mapsToSources(files);
    if (sources.isNotEmpty) onFiles(sources);
  }).catchError((_) {});

  // Warm-start: app already running when share intent arrives.
  _sub = _shareEventsChannel.receiveBroadcastStream().listen((data) {
    if (data is! List || data.isEmpty) return;
    final sources = _mapsToSources(data);
    if (sources.isNotEmpty) onFiles(sources);
  }, onError: (_) {});
}

/// Converts the [{uri, name, size}] maps returned by Kotlin into FileSources.
/// Name and size come directly from ContentResolver — no guessing needed.
List<FileSource> _mapsToSources(List<dynamic> files) {
  final sources = <FileSource>[];
  for (final raw in files) {
    if (raw is! Map) continue;
    final uriStr = raw['uri'] as String?;
    if (uriStr == null || uriStr.isEmpty) continue;
    final uri = Uri.parse(uriStr);
    final name = (raw['name'] as String?)?.trim();
    final size = (raw['size'] as num?)?.toInt() ?? 0;
    sources.add(FileSource(
      name: (name != null && name.isNotEmpty) ? name : 'shared_file',
      size: size,
      // Re-opens a fresh ContentResolver stream each time — no file copy.
      streamFactory: () => UriContent().getContentStream(uri),
    ));
  }
  return sources;
}

void disposeShareIntent() {
  _sub?.cancel();
  _sub = null;
}
