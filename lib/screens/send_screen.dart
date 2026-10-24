import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uri_content/uri_content.dart';
import '../models/device_info.dart';
import '../models/file_source.dart';
import '../models/transfer_item.dart';
import '../services/file_transfer_service.dart';
import '../theme/app_theme.dart';
import '../utils/device_code.dart';
import '../widgets/transfer_card.dart';

/// Returns the best platform icon for the given [platform] string.
IconData deviceIcon(String platform) {
  switch (platform.toLowerCase()) {
    case 'android':
      return Icons.phone_android_rounded;
    case 'ios':
      return Icons.phone_iphone_rounded;
    case 'windows':
      return Icons.desktop_windows_rounded;
    case 'macos':
      return Icons.laptop_mac_rounded;
    case 'linux':
      return Icons.computer_rounded;
    default:
      return Icons.devices_rounded;
  }
}

class SendScreen extends StatefulWidget {
  final DeviceInfo target;
  final FileTransferService transferService;

  /// Optional file paths pre-loaded via OS share intent.
  final List<String> initialFilePaths;

  /// Optional pre-built FileSources (e.g. from global drag-drop on HomeScreen).
  final List<FileSource> initialFileSources;

  const SendScreen({
    super.key,
    required this.target,
    required this.transferService,
    this.initialFilePaths = const [],
    this.initialFileSources = const [],
  });

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  /// FileSource list — built asynchronously on Android (zero-copy SAF),
  /// synchronously on desktop (filesystem path).
  List<FileSource> _selectedFiles = [];
  bool _isSending = false;

  /// True while the user is dragging files over the window (Windows only).
  bool _isDragHovering = false;

  // Live transfer items shown during an active send
  final List<TransferItem> _activeTransfers = [];

  /// True once a send finishes (success, fail, or cancel) — shows Done button.
  bool _sendFinished = false;

  @override
  void initState() {
    super.initState();
    // Pre-populate with files from the OS share intent (or legacy path).
    if (widget.initialFilePaths.isNotEmpty) {
      final fromPaths = widget.initialFilePaths.map((path) {
        // Our native share-intent handler passes raw content:// URI strings.
        // Stream directly via UriContent — no cache copy ever made.
        if (path.startsWith('content://')) {
          final uri = Uri.parse(path);
          // Name: best effort from the URI path segment; async resolution
          // not needed because MainActivity already resolved it — but since
          // we only carry the URI string here, derive a reasonable name.
          final name = _nameFromContentUri(uri);
          return FileSource(
            name: name,
            size: 0, // unknown without async ContentResolver; fine for UI
            streamFactory: () => UriContent().getContentStream(uri),
          );
        }
        // Desktop / legacy: real filesystem path.
        final file = File(path);
        return FileSource(
          name: file.uri.pathSegments.last,
          path: path,
          size: file.existsSync() ? file.lengthSync() : 0,
        );
      }).toList();
      _selectedFiles = [...fromPaths];
    }
    // Merge in any FileSources pre-built by the global drag-drop handler.
    if (widget.initialFileSources.isNotEmpty) {
      final existing = {for (final f in _selectedFiles) f.path};
      final deduped = widget.initialFileSources
          .where((s) => !existing.contains(s.path))
          .toList();
      _selectedFiles = [..._selectedFiles, ...deduped];
    }
  }

  /// Extracts a human-readable file name from a content URI.
  ///
  /// For MediaStore documents the last path segment looks like:
  ///   `document/image%3A123` → we skip those and fall back.
  /// For Downloads / Files provider it may contain the real filename.
  static String _nameFromContentUri(Uri uri) {
    try {
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      for (final seg in segments.reversed) {
        final decoded = Uri.decodeComponent(seg);
        // A real filename has an extension and no raw colons after decode.
        if (decoded.contains('.') && !decoded.contains(':')) return decoded;
      }
      // Fallback: decode last segment as best effort.
      return Uri.decodeComponent(segments.last);
    } catch (_) {
      return 'shared_file';
    }
  }

  // ── File picking ─────────────────────────────────────────────────────────────

  /// MethodChannel for the native Android file picker (MainActivity.kt).
  /// Uses ACTION_OPEN_DOCUMENT + startActivityForResult — zero copy, stable.
  static const _nativeFilePicker =
      MethodChannel('com.example.tcp_file_share/file_picker');

  /// [append] = true → merge with existing list. false → replace.
  ///
  /// On Android: calls our native MethodChannel which launches ACTION_OPEN_DOCUMENT
  /// via startActivityForResult. The OS hands us content:// URIs directly —
  /// zero cache copy, zero delay, works on all Android versions.
  /// On desktop: uses file_picker which reads real filesystem paths directly.
  Future<void> _pickFiles({bool append = false}) async {
    final List<FileSource> newSources;

    if (Platform.isAndroid) {
      // Native picker → content URI → zero cache copy, zero delay.
      final List<dynamic> picked =
          await _nativeFilePicker.invokeMethod('pickFiles') ?? [];
      if (picked.isEmpty) return;
      newSources = picked.map((raw) {
        final map = raw as Map;
        final uri = Uri.parse(map['uri'] as String);
        final name = (map['name'] as String?) ?? uri.pathSegments.last;
        final size = (map['size'] as num?)?.toInt() ?? 0;
        return FileSource(
          name: name,
          size: size,
          // Opens a fresh ContentResolver stream each call — no file copy.
          streamFactory: () => UriContent().getContentStream(uri),
        );
      }).toList();
    } else {
      // Desktop: file_picker reads real filesystem paths — no caching involved.
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      newSources = result.files
          .map((pf) => FileSource(name: pf.name, size: pf.size, path: pf.path))
          .toList();
    }

    if (!mounted) return;
    setState(() {
      if (append) {
        final existing = {for (final f in _selectedFiles) f.path};
        final deduped =
            newSources.where((s) => !existing.contains(s.path)).toList();
        _selectedFiles = [..._selectedFiles, ...deduped];
      } else {
        _selectedFiles = newSources;
      }
    });
  }

  /// Handles files dropped onto the window (Windows / desktop only).
  Future<void> _onDropDone(DropDoneDetails details) async {
    final newSources = <FileSource>[];
    for (final xf in details.files) {
      final f = File(xf.path);
      final stat = f.statSync();
      if (stat.type == FileSystemEntityType.directory) {
        // Recursively index dropped folders
        newSources.addAll(_scanDirectory(Directory(xf.path)));
      } else {
        newSources.add(FileSource(
          name: xf.name,
          size: stat.size,
          path: xf.path,
        ));
      }
    }
    if (!mounted || newSources.isEmpty) return;
    setState(() {
      final existing = {for (final f in _selectedFiles) f.path};
      final deduped =
          newSources.where((s) => !existing.contains(s.path)).toList();
      _selectedFiles = [..._selectedFiles, ...deduped];
    });
  }

  static List<FileSource> _scanDirectory(Directory dir) {
    final result = <FileSource>[];
    try {
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is File) {
          result.add(FileSource(
            name: e.path.split(Platform.pathSeparator).last,
            size: e.lengthSync(),
            path: e.path,
          ));
        }
      }
    } catch (_) {}
    return result;
  }


  // ── Send ─────────────────────────────────────────────────────────────────────

  Future<void> _send() async {
    if (_selectedFiles.isEmpty || _isSending) return;
    // Mark sending immediately so Cancel button appears before onItemsReady
    // fires. Previously there was a gap where neither Cancel nor Back worked.
    setState(() {
      _isSending = true;
      _sendFinished = false;
      _activeTransfers.clear();
    });

    await widget.transferService.sendFiles(
      fileSources: _selectedFiles,
      target: widget.target,
      onItemsReady: (items) {
        if (mounted) {
          setState(() => _activeTransfers.addAll(items));
        }
      },
    );

    if (mounted) {
      setState(() {
        _isSending = false;
        _sendFinished = true;
      });
    }
  }

  Future<void> _cancel() async {
    // Confirmation dialog — prevents accidental taps.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Transfer?'),
        content: const Text(
          'The transfer will be stopped immediately and any partial file on the receiver will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep Sending'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel Transfer'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      widget.transferService.cancelCurrentSend();
    }
  }

  bool get _allDone =>
      _activeTransfers.isNotEmpty &&
      _activeTransfers.every((t) =>
          t.status == TransferStatus.completed ||
          t.status == TransferStatus.failed ||
          t.status == TransferStatus.cancelled);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgOf(context),
      body: SafeArea(
        child: Column(
          children: [
            // ── Back button row ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed:
                        _isSending ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const Spacer(),
                ],
              ),
            ),

            // ── File picker zone OR active send progress ──────────────────
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _isSending || _sendFinished
                    ? _buildProgressView()
                    : _buildFilePickerView(),
              ),
            ),

            // ── Target info ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Icon(deviceIcon(widget.target.platform),
                      size: 14, color: AppTheme.mutedOf(context)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Sending to: ${widget.target.name}  ·  ${deviceCode(widget.target.ip)}',
                      style: TextStyle(
                          color: AppTheme.mutedOf(context), fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Action buttons ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
              child: _buildActionButton(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(BuildContext context) {
    // While sending — show Cancel immediately (no longer gated on
    // _activeTransfers.isNotEmpty, eliminating the dead-button gap).
    if (_isSending) {
      return _CancelButton(onCancel: _cancel);
    }
    // Send finished (success / fail / cancel) — show Done button
    if (_sendFinished) {
      return _DoneButton(onDone: () => Navigator.of(context).pop());
    }
    // Default — show Send button
    return _SendButton(
      enabled: _selectedFiles.isNotEmpty && !_isSending,
      isSending: _isSending,
      total: _selectedFiles.length,
      onSend: _send,
    );
  }

  // ── File picker view ─────────────────────────────────────────────────────────
  Widget _buildFilePickerView() {
    // On desktop platforms wrap the entire zone in a DropTarget so users can
    // drag files directly from Explorer / Finder onto the app.
    Widget zone = Padding(
      key: const ValueKey('picker'),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => _pickFiles(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: _isDragHovering
                      ? AppTheme.accentPrimary.withValues(alpha: 0.06)
                      : AppTheme.surfaceOf(context),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _isDragHovering
                        ? AppTheme.accentPrimary
                        : _selectedFiles.isNotEmpty
                            ? AppTheme.accentPrimary.withValues(alpha: 0.5)
                            : AppTheme.borderOf(context),
                    width: _isDragHovering || _selectedFiles.isNotEmpty
                        ? 1.5
                        : 1,
                  ),
                ),
                child: _selectedFiles.isEmpty
                    ? _EmptyFileZone(isDragHovering: _isDragHovering)
                    : _FileList(
                        files: _selectedFiles,
                        onAddMore: () => _pickFiles(append: true),
                        onRemove: (removed) => setState(() {
                          _selectedFiles = _selectedFiles
                              .where((f) => !removed.contains(f))
                              .toList();
                        }),
                      ),
              ),
            ),
          ),
        ],
      ),
    );

    // Wrap in DropTarget on desktop; no-op on Android/iOS
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return DropTarget(
        onDragDone: _onDropDone,
        onDragEntered: (_) => setState(() => _isDragHovering = true),
        onDragExited: (_) => setState(() => _isDragHovering = false),
        child: zone,
      );
    }
    return zone;
  }

  // ── Live send progress view ──────────────────────────────────────────────────
  Widget _buildProgressView() {
    return ListenableBuilder(
      listenable: widget.transferService,
      builder: (context, _) {
        final allDone = _allDone;
        return Column(
          key: const ValueKey('progress'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: Row(
                children: [
                  Text(
                    allDone ? 'Transfer Complete' : 'Sending Files',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (_isSending && !allDone)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (allDone)
                    const Icon(Icons.check_circle_rounded,
                        size: 18, color: AppTheme.success),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: _activeTransfers.length,
                itemBuilder: (ctx, i) => TransferCard(
                  key: ValueKey(_activeTransfers[i].id),
                  item: _activeTransfers[i],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Empty zone ────────────────────────────────────────────────────────────────
class _EmptyFileZone extends StatelessWidget {
  final bool isDragHovering;
  const _EmptyFileZone({this.isDragHovering = false});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isDragHovering ? Icons.file_download_rounded : Icons.add_rounded,
            size: 48,
            color: isDragHovering
                ? AppTheme.accentPrimary
                : AppTheme.mutedOf(context),
          ),
          const SizedBox(height: 12),
          Text(
            isDragHovering ? 'Drop files here' : 'Tap to select files',
            style: TextStyle(
                color: isDragHovering
                    ? AppTheme.accentPrimary
                    : AppTheme.secondaryOf(context),
                fontSize: 15,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(
            isDragHovering
                ? 'Release to add'
                : Platform.isWindows || Platform.isMacOS || Platform.isLinux
                    ? 'Tap or drag & drop files here'
                    : 'Any file type supported',
            style: TextStyle(color: AppTheme.mutedOf(context), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ── File list — selectable, with per-item and bulk delete ────────────────────
class _FileList extends StatefulWidget {
  final List<FileSource> files;
  final VoidCallback onAddMore;
  /// Called with the set of [FileSource] items the user wants removed.
  final void Function(Set<FileSource> removed) onRemove;

  const _FileList({
    required this.files,
    required this.onAddMore,
    required this.onRemove,
  });

  @override
  State<_FileList> createState() => _FileListState();
}

class _FileListState extends State<_FileList> {
  /// Currently selected file sources.
  final Set<FileSource> _selected = {};

  /// Index of the item the mouse is hovering over (-1 = none).
  int _hoveredIndex = -1;

  // ── Selection helpers ────────────────────────────────────────────────────
  void _onTap(FileSource f) {
    final ctrlHeld = HardwareKeyboard.instance.logicalKeysPressed.any((k) =>
        k == LogicalKeyboardKey.controlLeft ||
        k == LogicalKeyboardKey.controlRight ||
        k == LogicalKeyboardKey.metaLeft ||
        k == LogicalKeyboardKey.metaRight);

    setState(() {
      if (ctrlHeld) {
        // Ctrl+click → toggle individual item
        if (_selected.contains(f)) {
          _selected.remove(f);
        } else {
          _selected.add(f);
        }
      } else {
        // Plain click → exclusive select (or deselect if already sole selection)
        if (_selected.length == 1 && _selected.contains(f)) {
          _selected.clear();
        } else {
          _selected
            ..clear()
            ..add(f);
        }
      }
    });
  }

  void _deleteSelected() {
    if (_selected.isEmpty) return;
    final toRemove = Set<FileSource>.from(_selected);
    setState(() => _selected.clear());
    widget.onRemove(toRemove);

    // Undo snackbar
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${toRemove.length} file${toRemove.length > 1 ? 's' : ''} removed',
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _deleteSingle(FileSource f) {
    setState(() => _selected.remove(f));
    widget.onRemove({f});
  }

  // ── Formatting ───────────────────────────────────────────────────────────
  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = _selected.isNotEmpty;
    final accent = AppTheme.accentPrimary;

    return Column(
      children: [
        // ── Header row ──────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
          child: Row(
            children: [
              // File count
              Text(
                '${widget.files.length} file${widget.files.length > 1 ? 's' : ''}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (hasSelection) ...
              [
                const SizedBox(width: 6),
                Text(
                  '· ${_selected.length} selected',
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              const Spacer(),
              // + Add More
              TextButton.icon(
                onPressed: widget.onAddMore,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  visualDensity: VisualDensity.compact,
                ),
                icon: Icon(Icons.add_rounded, size: 14, color: accent),
                label: Text(
                  'Add More',
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // Bin icon — visible only when something is selected
              AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: hasSelection ? 1.0 : 0.0,
                child: IgnorePointer(
                  ignoring: !hasSelection,
                  child: IconButton(
                    onPressed: _deleteSelected,
                    icon: const Icon(Icons.delete_outline_rounded),
                    iconSize: 18,
                    color: AppTheme.error,
                    tooltip: 'Remove selected',
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(color: AppTheme.borderOf(context), height: 1),

        // ── File items ──────────────────────────────────────────────────
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(10),
            itemCount: widget.files.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (ctx, i) {
              final f = widget.files[i];
              final isSelected = _selected.contains(f);
              final isHovered = _hoveredIndex == i;

              return MouseRegion(
                onEnter: (_) => setState(() => _hoveredIndex = i),
                onExit: (_) => setState(() {
                  if (_hoveredIndex == i) _hoveredIndex = -1;
                }),
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => _onTap(f),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? accent.withValues(alpha: 0.10)
                          : isHovered
                              ? AppTheme.surfaceOf(context)
                              : AppTheme.bgOf(context),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? accent.withValues(alpha: 0.45)
                            : isHovered
                                ? AppTheme.borderOf(context)
                                : Colors.transparent,
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        // File icon
                        Icon(
                          Icons.insert_drive_file_outlined,
                          size: 18,
                          color: isSelected
                              ? accent
                              : AppTheme.secondaryOf(context),
                        ),
                        const SizedBox(width: 10),
                        // Name + size
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                f.name,
                                style: TextStyle(
                                  color: isSelected
                                      ? accent
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurface,
                                  fontSize: 12,
                                  fontWeight: isSelected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                _fmtBytes(f.size),
                                style: TextStyle(
                                  color: AppTheme.mutedOf(context),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Per-item delete (hover or selected)
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 120),
                          opacity: (isHovered || isSelected) ? 1.0 : 0.0,
                          child: IgnorePointer(
                            ignoring: !(isHovered || isSelected),
                            child: GestureDetector(
                              onTap: () => _deleteSingle(f),
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 14,
                                  color: AppTheme.mutedOf(context),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Send button ────────────────────────────────────────────────────────────────
class _SendButton extends StatelessWidget {
  final bool enabled;
  final bool isSending;
  final int total;
  final VoidCallback onSend;

  const _SendButton({
    required this.enabled,
    required this.isSending,
    required this.total,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final active = Theme.of(context).colorScheme.onSurface;
    final bg = enabled ? active : AppTheme.borderOf(context);

    return GestureDetector(
      onTap: enabled ? onSend : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 52,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isSending)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppTheme.bgOf(context)),
              )
            else
              Icon(Icons.send_rounded,
                  size: 18,
                  color: enabled
                      ? AppTheme.bgOf(context)
                      : AppTheme.mutedOf(context)),
            const SizedBox(width: 10),
            Text(
              isSending
                  ? 'Sending…'
                  : enabled
                      ? 'Send ${total > 1 ? "$total Files" : "File"}'
                      : 'Select files first',
              style: TextStyle(
                color: enabled
                    ? AppTheme.bgOf(context)
                    : AppTheme.mutedOf(context),
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Cancel button ─────────────────────────────────────────────────────────────
class _CancelButton extends StatefulWidget {
  final Future<void> Function() onCancel;
  const _CancelButton({required this.onCancel});

  @override
  State<_CancelButton> createState() => _CancelButtonState();
}

class _CancelButtonState extends State<_CancelButton> {
  /// True after the user confirms — prevents double-taps.
  bool _cancelling = false;

  Future<void> _handleTap() async {
    if (_cancelling) return;
    await widget.onCancel();
    // onCancel() shows the dialog; if the user confirmed, the service begins
    // stopping. Keep _cancelling = false so they can re-tap if needed.
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _cancelling ? null : _handleTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 52,
        decoration: BoxDecoration(
          color: _cancelling
              ? AppTheme.borderOf(context)
              : AppTheme.error.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: _cancelling
                ? AppTheme.borderOf(context)
                : AppTheme.error.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_cancelling)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.error,
                ),
              )
            else
              const Icon(Icons.cancel_rounded, size: 18, color: AppTheme.error),
            const SizedBox(width: 10),
            Text(
              _cancelling ? 'Cancelling…' : 'Cancel Transfer',
              style: TextStyle(
                color: _cancelling
                    ? AppTheme.mutedOf(context)
                    : AppTheme.error,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Done button ───────────────────────────────────────────────────────────────
class _DoneButton extends StatelessWidget {
  final VoidCallback onDone;
  const _DoneButton({required this.onDone});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onDone,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: AppTheme.success.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: AppTheme.success.withValues(alpha: 0.4)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_rounded, size: 18, color: AppTheme.success),
            SizedBox(width: 10),
            Text(
              'Done',
              style: TextStyle(
                color: AppTheme.success,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
