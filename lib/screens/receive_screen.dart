import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'dart:io';
import '../models/transfer_item.dart';
import '../services/file_transfer_service.dart';
import '../theme/app_theme.dart';
import '../widgets/transfer_card.dart';

/// Full-screen transfer progress screen shown on the receiver side,
/// mirroring the sender's progress view from SendScreen.
class ReceiveScreen extends StatefulWidget {
  final FileTransferService transferService;
  final String senderName;

  /// The IDs of the TransferItems that belong to this receive session.
  /// We filter the service's transfer list by these IDs.
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

    return Scaffold(
      backgroundColor: AppTheme.bgOf(context),
      body: SafeArea(
        child: Column(
          children: [
            // ── Back button row ────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed:
                        allDone ? () => Navigator.of(context).pop() : null,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const Spacer(),
                ],
              ),
            ),

            // ── Header with overall status ──────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: allDone
                          ? AppTheme.success.withValues(alpha: 0.12)
                          : AppTheme.accentSecondary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      allDone
                          ? Icons.check_circle_rounded
                          : Icons.download_rounded,
                      color:
                          allDone ? AppTheme.success : AppTheme.accentSecondary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          allDone ? 'Transfer Complete' : 'Receiving Files',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          allDone
                              ? '$completedCount of ${items.length} files received'
                              : 'From ${widget.senderName}',
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

            // ── Overall progress bar ───────────────────────────────
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
                        allDone ? AppTheme.success : AppTheme.accentSecondary,
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
                              ? AppTheme.success
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

            // ── File list with per-file progress ───────────────────
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

            // ── Sender info ────────────────────────────────────────
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

            // ── Action button ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
              child: allDone
                  ? _DoneButton(onDone: () => Navigator.of(context).pop())
                  : _ReceivingIndicator(),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Receiving indicator (while transfer is in progress) ───────────────────────
class _ReceivingIndicator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: AppTheme.accentSecondary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
        border:
            Border.all(color: AppTheme.accentSecondary.withValues(alpha: 0.4)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTheme.accentSecondary,
            ),
          ),
          SizedBox(width: 10),
          Text(
            'Receiving…',
            style: TextStyle(
              color: AppTheme.accentSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
        ],
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
