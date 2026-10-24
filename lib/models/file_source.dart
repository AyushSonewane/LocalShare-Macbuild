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
  ///
  /// **Performance note:** We avoid `Uint8List.fromList()` copies in the hot
  /// path. Both `File.openRead()` and `UriContent.getContentStream()` already
  /// emit `Uint8List` chunks, so a cast is sufficient in the common case.
  Stream<Uint8List> openRead() {
    if (streamFactory != null) {
      return streamFactory!().map((chunk) =>
          chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    }
    if (path != null) {
      // File.openRead() returns Stream<List<int>> but the runtime type is
      // always Uint8List — use cast() to avoid per-chunk allocation.
      return File(path!).openRead().cast<Uint8List>();
    }
    throw StateError('FileSource has neither streamFactory nor path');
  }
}
