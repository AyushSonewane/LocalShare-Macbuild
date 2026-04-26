import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/transfer_item.dart';
import '../services/file_transfer_service.dart';
import '../theme/app_theme.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final transferService = context.watch<FileTransferService>();
    // Only show finished transfers (not active/pending ones)
    final transfers = transferService.transfers
        .where((t) =>
            t.status == TransferStatus.completed ||
            t.status == TransferStatus.failed ||
            t.status == TransferStatus.cancelled)
        .toList();

    return Scaffold(
      backgroundColor: AppTheme.bgOf(context),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.arrow_back_rounded,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'History',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const Spacer(),
                  if (transfers.isNotEmpty)
                    TextButton(
                      onPressed: () =>
                          _confirmClearAll(context, transferService),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        foregroundColor: AppTheme.error,
                      ),
                      child: const Text(
                        'Clear all',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // ── List ──────────────────────────────────────────────────────
            Expanded(
              child: transfers.isEmpty
                  ? _EmptyHistory()
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                      itemCount: transfers.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (ctx, i) {
                        final t = transfers[i];
                        return _HistoryRow(
                          item: t,
                          onDelete: () => transferService.removeTransfer(t.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearAll(
      BuildContext context, FileTransferService service) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surfaceOf(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Clear all history?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(
          'This will remove all transfer records. This cannot be undone.',
          style: TextStyle(color: AppTheme.secondaryOf(context), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel',
                style: TextStyle(color: AppTheme.secondaryOf(context))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear all',
                style: TextStyle(
                    color: AppTheme.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok == true) service.clearAll();
  }
}

// ── History row ───────────────────────────────────────────────────────────────
class _HistoryRow extends StatelessWidget {
  final TransferItem item;
  final VoidCallback onDelete;
  const _HistoryRow({required this.item, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final isSending = item.direction == TransferDirection.sending;
    final Color arrowColor =
        isSending ? AppTheme.accentPrimary : AppTheme.success;
    final Color arrowBg = arrowColor.withValues(alpha: 0.10);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderOf(context)),
      ),
      child: Row(
        children: [
          // Direction arrow badge
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: arrowBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isSending
                  ? Icons.north_east_rounded // ↗ outgoing
                  : Icons.south_west_rounded, // ↙ incoming
              size: 18,
              color: arrowColor,
            ),
          ),

          const SizedBox(width: 12),

          // Info column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Direction label + peer name
                RichText(
                  text: TextSpan(
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    children: [
                      TextSpan(
                        text: isSending ? 'to:  ' : 'from:  ',
                        style: TextStyle(
                          color: AppTheme.secondaryOf(context),
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      TextSpan(
                        text: item.peerName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),

                const SizedBox(height: 3),

                // File name + size
                Text(
                  '${item.fileName}  ·  ${item.fileSizeLabel}',
                  style: TextStyle(
                    color: AppTheme.mutedOf(context),
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Status chip
          _StatusChip(status: item.status),

          const SizedBox(width: 4),

          // Delete button
          IconButton(
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline_rounded,
                size: 18, color: AppTheme.mutedOf(context)),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }
}

// ── Status chip ───────────────────────────────────────────────────────────────
class _StatusChip extends StatelessWidget {
  final TransferStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      TransferStatus.completed => ('Done', AppTheme.success),
      TransferStatus.failed => ('Failed', AppTheme.error),
      TransferStatus.cancelled => ('Cancelled', AppTheme.warning),
      TransferStatus.inProgress => ('Active', AppTheme.accentPrimary),
      TransferStatus.pending => ('Pending', AppTheme.textMuted),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────
class _EmptyHistory extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppTheme.surfaceOf(context),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.borderOf(context)),
            ),
            child: Icon(Icons.history_rounded,
                size: 32, color: AppTheme.mutedOf(context)),
          ),
          const SizedBox(height: 16),
          Text('No transfers yet',
              style: TextStyle(
                  color: AppTheme.secondaryOf(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text('Completed transfers will appear here.',
              style: TextStyle(color: AppTheme.mutedOf(context), fontSize: 12)),
        ],
      ),
    );
  }
}
