import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'dart:io';
import '../models/transfer_item.dart';
import '../services/file_transfer_service.dart';
import '../theme/app_theme.dart';
import '../widgets/transfer_card.dart';

/// Full-screen transfer progress screen shown on the receiver side.
class ReceiveScreen extends StatefulWidget {
  final FileTransferService transferService;
  final String senderName;

  /// The IDs of the TransferItems that belong to this receive session.
  final List<String> transferIds;

  const ReceiveScreen({
    super.key,
    required this.transferService,
    required this.senderName,
    required this.transferIds,
  });

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  @override
  void initState() {
    super.initState();
    widget.transferService.addListener(_onTransferChanged);
  }

  @override
  void dispose() {
    widget.transferService.removeListener(_onTransferChanged);
    super.dispose();
  }

  void _onTransferChanged() {
    if (mounted) setState(() {});
  }

  List<TransferItem> get _sessionTransfers {
    final idSet = widget.transferIds.toSet();
    return widget.transferService.transfers
        .where((t) => idSet.contains(t.id))
        .toList();
  }

  bool get _allDone {
    final items = _sessionTransfers;
    return items.isNotEmpty &&
        items.every((t) =>
            t.status == TransferStatus.completed ||
            t.status == TransferStatus.failed ||
            t.status == TransferStatus.cancelled);
  }

  bool get _allCompleted =>
      _sessionTransfers.every((t) => t.status == TransferStatus.completed);

  bool get _anyCancelledOrFailed => _sessionTransfers.any((t) =>
      t.status == TransferStatus.cancelled || t.status == TransferStatus.failed);

  void _openFile(String path) {
    if (Platform.isWindows) {
      Process.run('explorer', [path]);
    } else if (Platform.isMacOS) {
      Process.run('open', [path]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [path]);
    } else {
      OpenFilex.open(path);
    }
  }

  /// Shows a confirmation dialog then cancels the receive if confirmed.
  Future<void> _confirmCancel(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceOf(ctx),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Cancel Transfer?'),
        content: const Text(
          'The partially received file will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Continue Receiving'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
                foregroundColor: AppTheme.error),
            child: const Text('Cancel Transfer'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      widget.transferService.cancelCurrentReceive();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _sessionTransfers;
    final allDone = _allDone;

    // Aggregate progress
    int totalBytes = 0;
    int transferredBytes = 0;
    for (final item in items) {
      totalBytes += item.fileSize;
      transferredBytes += item.bytesTransferred;
    }
    final overallProgress =
        totalBytes > 0 ? (transferredBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
    final completedCount =
        items.where((t) => t.status == TransferStatus.completed).length;

    // Header appearance depends on final state
    final Color headerIconColor;
    final IconData headerIcon;
    final String headerTitle;
    final String headerSubtitle;

    if (!allDone) {
      headerIcon = Icons.download_rounded;
      headerIconColor = AppTheme.accentSecondary;
      headerTitle = 'Receiving Files';
      headerSubtitle = 'From ${widget.senderName}';
    } else if (_allCompleted) {
      headerIcon = Icons.check_circle_rounded;
      headerIconColor = AppTheme.success;
      headerTitle = 'Transfer Complete';
      headerSubtitle = '$completedCount of ${items.length} files received';
    } else {
      headerIcon = Icons.cancel_rounded;
      headerIconColor = Colors.orange;
      headerTitle = _anyCancelledOrFailed
          ? 'Transfer Interrupted'
          : 'Transfer Complete';
      headerSubtitle = '$completedCount of ${items.length} files received';
    }

    // Intercept the Android/hardware back button so it triggers cancel
    // rather than navigating away while a transfer is in progress.
    return PopScope(
      canPop: allDone,
      onPopInvoked: (didPop) {
        if (!didPop && !allDone) {
          _confirmCancel(context);
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.bgOf(context),
        body: SafeArea(
          child: Column(
            children: [
              // ── Back / close button row ───────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      // Always enabled: back = cancel when in progress,
                      //                 back = pop when done.
                      onPressed: allDone
                          ? () => Navigator.of(context).pop()
                          : () => _confirmCancel(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const Spacer(),
                  ],
                ),
              ),

              // ── Header with overall status ────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: headerIconColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(headerIcon, color: headerIconColor, size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            headerTitle,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            headerSubtitle,
                            style: TextStyle(
                              color: AppTheme.secondaryOf(context),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!allDone)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),

              // ── Overall progress bar ──────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: overallProgress,
                        backgroundColor: AppTheme.borderOf(context),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          allDone
                              ? (_allCompleted ? AppTheme.success : Colors.orange)
                              : AppTheme.accentSecondary,
                        ),
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          '$completedCount / ${items.length} files',
                          style: TextStyle(
                            color: AppTheme.secondaryOf(context),
                            fontSize: 11,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${(overallProgress * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            color: allDone
                                ? (_allCompleted
                                    ? AppTheme.success
                                    : Colors.orange)
                                : AppTheme.accentSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // ── File list with per-file progress ──────────────────
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: items.length,
                  itemBuilder: (ctx, i) => TransferCard(
                    key: ValueKey(items[i].id),
                    item: items[i],
                    onOpen: items[i].status == TransferStatus.completed &&
                            items[i].savePath != null
                        ? () => _openFile(items[i].savePath!)
                        : null,
                  ),
                ),
              ),

              // ── Sender info ───────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Icon(Icons.person_rounded,
                        size: 14, color: AppTheme.mutedOf(context)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'From: ${widget.senderName}',
                        style: TextStyle(
                            color: AppTheme.mutedOf(context), fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Action button ─────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
                child: allDone
                    ? _DoneButton(onDone: () => Navigator.of(context).pop())
                    : _CancelButton(onCancel: () => _confirmCancel(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Cancel button (shown while receive is in progress) ────────────────────────
class _CancelButton extends StatelessWidget {
  final VoidCallback onCancel;
  const _CancelButton({required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final errorColor = AppTheme.error;
    return GestureDetector(
      onTap: onCancel,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: errorColor.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: errorColor.withValues(alpha: 0.40)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cancel_outlined, size: 18, color: errorColor),
            const SizedBox(width: 10),
            Text(
              'Cancel Transfer',
              style: TextStyle(
                color: errorColor,
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
