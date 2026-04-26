// Stub implementation for platforms that don't support receive_sharing_intent
// (Windows, macOS, Linux, Web).
typedef SharedFilesCallback = void Function(List<String> paths);

void initializeShareIntent({required SharedFilesCallback onFiles}) {
  // No-op on non-mobile platforms
}

void disposeShareIntent() {
  // No-op on non-mobile platforms
}
