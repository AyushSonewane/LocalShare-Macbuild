import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uri_content/uri_content.dart';
import '../models/device_info.dart';
import '../models/file_source.dart';
import '../models/transfer_item.dart';
import '../services/file_transfer_service.dart';
import '../theme/app_theme.dart';
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

  const SendScreen({
    super.key,
    required this.target,
    required this.transferService,
    this.initialFilePaths = const [],
  });

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  List<PlatformFile> _selectedFiles = [];
  bool _isSending = false;

  // Live transfer items shown during an active send
  final List<TransferItem> _activeTransfers = [];

  /// True once a send finishes (success, fail, or cancel) — shows Done button.
  bool _sendFinished = false;

  @override
  void initState() {
    super.initState();
    // Pre-populate with files from share intent if any.
    if (widget.initialFilePaths.isNotEmpty) {
      _selectedFiles = widget.initialFilePaths.map((path) {
        final file = File(path);
        return PlatformFile(
          name: file.uri.pathSegments.last,
          path: path,
          size: file.existsSync() ? file.lengthSync() : 0,
        );
      }).toList();
    }
  }

  // ── File picking ─────────────────────────────────────────────────────────────

  /// [append] = true → merge with existing list. false → replace.
  Future<void> _pickFiles({bool append = false}) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;
    setState(() {
      if (append) {
        // Merge, deduplicating by path
        final existing = {for (final f in _selectedFiles) f.path};
        final newOnes =
            result.files.where((f) => !existing.contains(f.path)).toList();
        _selectedFiles = [..._selectedFiles, ...newOnes];
      } else {
        _selectedFiles = result.files;
      }
    });
  }
  // ── Build FileSource from a PlatformFile ─────────────────────────────────────

  /// Converts a [PlatformFile] to a [FileSource].
  ///
  /// On Android, if the file has a `content://` identifier, we create a
  /// stream factory via [UriContent] so the file bytes are streamed directly
  /// from the content provider — no cache copy needed for the actual transfer.
  /// On desktop platforms, we just use the filesystem path.
  static FileSource _toFileSource(PlatformFile pf) {
    Stream<List<int>> Function()? factory;
    if (Platform.isAndroid && pf.identifier != null) {
      final uri = Uri.parse(pf.identifier!);
      factory = () => UriContent().getContentStream(uri);
    }
    return FileSource(
      name: pf.name,
      size: pf.size,
      path: pf.path,
      streamFactory: factory,
    );
  }

  // ── Send ─────────────────────────────────────────────────────────────────────

  Future<void> _send() async {
    if (_selectedFiles.isEmpty || _isSending) return;
    setState(() {
      _isSending = true;
      _sendFinished = false;
      _activeTransfers.clear();
    });

    final sources = _selectedFiles.map(_toFileSource).toList();

    if (sources.isNotEmpty) {
      await widget.transferService.sendFiles(
        fileSources: sources,
        target: widget.target,
        onItemsReady: (items) {
          if (mounted) {
            setState(() {
              _activeTransfers.addAll(items);
            });
          }
        },
      );
    }

    if (mounted) {
      setState(() {
        _isSending = false;
        _sendFinished = true;
      });
    }
    // No auto-pop — show Done button instead.
  }

  void _cancel() {
    widget.transferService.cancelCurrentSend();
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
                      'Sending to: ${widget.target.name}  (${widget.target.ip})',
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
    // While sending — show Cancel button
    if (_isSending && _activeTransfers.isNotEmpty) {
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
    return Padding(
      key: const ValueKey('picker'),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Main drop zone
          Expanded(
            child: GestureDetector(
              onTap: () => _pickFiles(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceOf(context),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _selectedFiles.isNotEmpty
                        ? AppTheme.accentPrimary.withValues(alpha: 0.5)
                        : AppTheme.borderOf(context),
                    width: _selectedFiles.isNotEmpty ? 1.5 : 1,
                  ),
                ),
                child: _selectedFiles.isEmpty
                    ? _EmptyFileZone()
                    : _FileList(
                        files: _selectedFiles,
                        onReplace: () => _pickFiles(),
                        onAddMore: () => _pickFiles(append: true),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
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
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add_rounded, size: 48, color: AppTheme.mutedOf(context)),
          const SizedBox(height: 12),
          Text('Tap to select files',
              style: TextStyle(
                  color: AppTheme.secondaryOf(context),
                  fontSize: 15,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text('Any file type supported',
              style: TextStyle(color: AppTheme.mutedOf(context), fontSize: 12)),
        ],
      ),
    );
  }
}

// ── File list with Add More / Replace ─────────────────────────────────────────
class _FileList extends StatelessWidget {
  final List<PlatformFile> files;
  final VoidCallback onReplace;
  final VoidCallback onAddMore;
  const _FileList(
      {required this.files, required this.onReplace, required this.onAddMore});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header row
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          child: Row(
            children: [
              Text('${files.length} file${files.length > 1 ? "s" : ""}',
                  style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              // Add More button
              TextButton.icon(
                onPressed: onAddMore,
                style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    visualDensity: VisualDensity.compact),
                icon: Icon(Icons.add_rounded,
                    size: 15, color: AppTheme.accentPrimary),
                label: Text('Add More',
                    style: TextStyle(
                        color: AppTheme.accentPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
              // Change (replace) button
              TextButton(
                onPressed: onReplace,
                style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    visualDensity: VisualDensity.compact),
                child: Text('Change',
                    style: TextStyle(
                        color: AppTheme.secondaryOf(context), fontSize: 12)),
              ),
            ],
          ),
        ),
        Divider(color: AppTheme.borderOf(context), height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: files.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (ctx, i) {
              final f = files[i];
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.bgOf(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.borderOf(context)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.insert_drive_file_rounded,
                        size: 20, color: AppTheme.accentPrimary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(f.name,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis),
                          Text(_fmtBytes(f.size),
                              style: TextStyle(
                                  color: AppTheme.mutedOf(context),
                                  fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
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
class _CancelButton extends StatelessWidget {
  final VoidCallback onCancel;
  const _CancelButton({required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onCancel,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: AppTheme.error.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: AppTheme.error.withValues(alpha: 0.4)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cancel_rounded, size: 18, color: AppTheme.error),
            SizedBox(width: 10),
            Text(
              'Cancel Transfer',
              style: TextStyle(
                color: AppTheme.error,
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
