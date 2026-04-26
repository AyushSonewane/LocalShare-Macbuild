import 'dart:async';
import 'package:flutter/material.dart';
import '../models/transfer_item.dart';
import '../theme/app_theme.dart';

class TransferCard extends StatefulWidget {
  final TransferItem item;
  final VoidCallback? onDismiss;
  final VoidCallback? onOpen;

  const TransferCard({
    super.key,
    required this.item,
    this.onDismiss,
    this.onOpen,
  });

  @override
  State<TransferCard> createState() => _TransferCardState();
}

class _TransferCardState extends State<TransferCard> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    if (widget.item.status == TransferStatus.inProgress) {
      _refreshTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didUpdateWidget(TransferCard old) {
    super.didUpdateWidget(old);
    if (widget.item.status == TransferStatus.inProgress &&
        _refreshTimer == null) {
      // Item transitioned to inProgress (e.g. pending → inProgress in multi-file)
      _refreshTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        if (mounted) setState(() {});
      });
    } else if (widget.item.status != TransferStatus.inProgress) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Color get _statusColor {
    switch (widget.item.status) {
      case TransferStatus.completed:
        return AppTheme.success;
      case TransferStatus.failed:
        return AppTheme.error;
      case TransferStatus.inProgress:
        return AppTheme.accentSecondary;
      case TransferStatus.cancelled:
        return AppTheme.warning;
      default:
        return AppTheme.textMuted;
    }
  }

  IconData get _statusIcon {
    switch (widget.item.status) {
      case TransferStatus.completed:
        return Icons.check_circle_rounded;
      case TransferStatus.failed:
        return Icons.error_rounded;
      case TransferStatus.inProgress:
        return widget.item.direction == TransferDirection.sending
            ? Icons.upload_rounded
            : Icons.download_rounded;
      case TransferStatus.cancelled:
        return Icons.cancel_rounded;
      default:
        return Icons.hourglass_empty_rounded;
    }
  }

  IconData get _fileIcon {
    final ext = widget.item.fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
        return Icons.image_rounded;
      case 'mp4':
      case 'mkv':
      case 'avi':
      case 'mov':
        return Icons.videocam_rounded;
      case 'mp3':
      case 'wav':
      case 'flac':
        return Icons.audio_file_rounded;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip_rounded;
      case 'dart':
      case 'py':
      case 'js':
      case 'ts':
      case 'json':
        return Icons.code_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceOf(context), // ← adaptive
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderOf(context)), // ← adaptive
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // File icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_fileIcon, color: _statusColor, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.fileName,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          item.direction == TransferDirection.sending
                              ? Icons.arrow_upward_rounded
                              : Icons.arrow_downward_rounded,
                          size: 11,
                          color: item.direction == TransferDirection.sending
                              ? AppTheme.accentPrimary
                              : AppTheme.accentSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${item.direction == TransferDirection.sending ? "To" : "From"} ${item.peerName}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(width: 8),
                        Text('•', style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(width: 8),
                        Text(item.fileSizeLabel,
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Status icon
              Icon(_statusIcon, color: _statusColor, size: 20),
              if (widget.onDismiss != null) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: widget.onDismiss,
                  child: const Icon(Icons.close_rounded,
                      color: AppTheme.textMuted, size: 18),
                ),
              ],
            ],
          ),

          // Progress bar (only when transferring)
          if (item.status == TransferStatus.inProgress ||
              (item.status == TransferStatus.completed &&
                  item.fileSize > 0)) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: item.progress,
                backgroundColor: AppTheme.surfaceBorder,
                valueColor: AlwaysStoppedAnimation<Color>(_statusColor),
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${item.transferredLabel} / ${item.fileSizeLabel}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                if (item.status == TransferStatus.inProgress) ...[
                  Text(
                    item.speedLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.accentSecondary,
                        ),
                  ),
                  const SizedBox(width: 8),
                  Text('ETA: ${item.etaLabel}',
                      style: Theme.of(context).textTheme.bodySmall),
                ] else
                  Text(
                    '${(item.progress * 100).toStringAsFixed(0)}%',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: _statusColor),
                  ),
              ],
            ),
          ],

          // Error message
          if (item.status == TransferStatus.failed &&
              item.errorMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 14, color: AppTheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item.errorMessage!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.error,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Open file button for completed receives
          if (item.status == TransferStatus.completed &&
              item.direction == TransferDirection.receiving &&
              widget.onOpen != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: widget.onOpen,
                icon: const Icon(Icons.open_in_new_rounded, size: 14),
                label: const Text('Open File'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
