// Stub for platforms that don't support share intents (Windows, macOS, Linux).
import '../models/file_source.dart';

typedef SharedFilesCallback = void Function(List<FileSource> sources);

void initializeShareIntent({required SharedFilesCallback onFiles}) {
  // No-op on non-mobile platforms.
}

void disposeShareIntent() {
  // No-op on non-mobile platforms.
}
