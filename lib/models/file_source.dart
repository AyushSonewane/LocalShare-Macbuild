import 'dart:io';
import 'dart:typed_data';

/// A file to be sent over the network.
///
/// On desktop platforms [path] is a real filesystem path and [streamFactory]
/// is null — the transfer layer will use `File(path).openRead()`.
///
/// On Android, when the file comes from a content:// URI (via file_picker or
/// share intent), [streamFactory] provides a zero-copy stream directly from
/// the content resolver, avoiding a cache-directory copy.  [path] may still be
/// set (e.g. to extract the display name) but should NOT be used for I/O.
class FileSource {
  /// Display name of the file (e.g. "photo.jpg").
  final String name;

  /// Size in bytes.
  final int size;

  /// Filesystem path — always available on desktop, may be a cache path on
  /// Android (only used as a fallback if [streamFactory] is null).
  final String? path;

  /// A factory that opens a fresh byte stream each time it is called.
  /// Preferred over [path] when available (avoids cache copies on Android).
  final Stream<List<int>> Function()? streamFactory;

  const FileSource({
    required this.name,
    required this.size,
    this.path,
    this.streamFactory,
  });

  /// Opens a byte stream for this file.
  ///
  /// Uses [streamFactory] if available, otherwise falls back to
  /// `File(path).openRead()`.
  Stream<Uint8List> openRead() {
    if (streamFactory != null) {
      return streamFactory!().map((chunk) => Uint8List.fromList(chunk));
    }
    if (path != null) {
      return File(path!).openRead().map((chunk) => Uint8List.fromList(chunk));
    }
    throw StateError('FileSource has neither streamFactory nor path');
  }
}
