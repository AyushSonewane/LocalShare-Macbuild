import 'dart:async';
import 'dart:io';
import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import '../models/device_info.dart';
import '../models/file_source.dart';
import '../models/incoming_request.dart';
import '../models/transfer_item.dart';
import '../services/file_transfer_service.dart';
import '../services/discovery_service.dart';
import '../services/share_intent_service.dart';
import '../theme/app_theme.dart';
import '../theme/app_routes.dart';
import '../utils/device_code.dart';
import '../widgets/transfer_card.dart';
import '../widgets/drag_drop_overlay.dart';
import 'receive_screen.dart';
import 'send_screen.dart'; // also exports deviceIcon()
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final DeviceInfo selfDevice;
  const HomeScreen({super.key, required this.selfDevice});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  bool _isRefreshing = false;
  StreamSubscription<IncomingRequest>? _requestSub;

  /// Files shared via OS share sheet, already converted to [FileSource]s
  /// (content URI streams — zero cache copy on Android).
  List<FileSource> _sharedFileSources = [];

  /// Files dropped globally onto the app window (Windows/desktop).
  /// Stored as [FileSource] so they go directly into the transfer pipeline.
  List<FileSource> _pendingDropFiles = [];

  /// True while the user is hovering a drag over the window.
  bool _isDragHovering = false;

  /// Number of files being dragged (for overlay preview).
  int _dragFileCount = 0;

  /// First file name being dragged (for overlay preview).
  String? _dragFirstFileName;

  /// True while dropped folders are being recursively indexed.
  bool _isIndexingDrop = false;

  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _tab);
    _subscribeToIncomingRequests();

    // Check for pending share-intent files on first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumeShareIntent();
      // Listen for future share intents while already on this screen.
      context.read<ShareIntentService>().addListener(_onShareIntentChanged);
      context.read<DiscoveryService>().setReceivingMode(_tab == 0);
    });
  }

  void _onShareIntentChanged() {
    _consumeShareIntent();
  }

  /// If the [ShareIntentService] has pending files, consume them, switch to
  /// the Send tab, and hold the paths until the user picks a target device.
  void _consumeShareIntent() {
    final shareService = context.read<ShareIntentService>();
    if (!shareService.hasPendingFiles) return;

    final sources = shareService.consumePendingFileSources();
    if (sources.isEmpty) return;

    setState(() {
      _sharedFileSources = sources;
    });
    // Auto-switch to Send tab so the user can pick a device.
    _switchTab(1);
  }

  void _subscribeToIncomingRequests() {
    final ts = context.read<FileTransferService>();
    _requestSub = ts.incomingRequests.listen(_onIncomingRequest);
  }

  /// Called on the main isolate whenever a new transfer request arrives.
  void _onIncomingRequest(IncomingRequest req) {
    if (!mounted) {
      req.reject();
      return;
    }
    // Switch to Receive tab and re-broadcast receive mode
    if (_tab != 0) {
      _switchTab(0);
    }
    _showAcceptDialogAndNavigate(req);
  }

  /// Shows the accept/reject dialog, then navigates to [ReceiveScreen] on accept.
  Future<void> _showAcceptDialogAndNavigate(IncomingRequest req) async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AcceptDialog(request: req),
    );
    if (accepted != true || !mounted) return;

    // Wait for the service to create TransferItems and report their IDs
    try {
      final ids = await req.transferIds.timeout(
        const Duration(seconds: 5),
      );
      if (!mounted || ids.isEmpty) return;

      final ts = context.read<FileTransferService>();
      AppRoutes.push(
        context,
        ReceiveScreen(
          transferService: ts,
          senderName: req.senderName,
          transferIds: ids,
        ),
      );
    } catch (_) {
      // Timeout or error — items are still visible on the receive tab
    }
  }

  void _switchTab(int i) {
    if (_tab == i) return;
    setState(() {
      _tab = i;
    });
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
    context.read<DiscoveryService>().setReceivingMode(i == 0);
  }

  // ── Global drag-and-drop (Windows/desktop) ─────────────────────────────────

  /// Entry point for files dropped anywhere on the app window.
  ///
  /// Guards:
  /// - Active send in progress → show snackbar, ignore drop
  /// - Active receive in progress → warn user, ignore drop
  /// - Otherwise: scan files/folders async, switch to Send tab, show banner
  Future<void> _onGlobalDrop(DropDoneDetails details) async {
    setState(() => _isDragHovering = false);

    if (details.files.isEmpty) return;

    final ts = context.read<FileTransferService>();

    // Guard: active send in progress
    if (ts.isSending) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A send is already in progress. Cancel it first.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // Guard: active receive in progress
    final hasActiveReceive = ts.transfers.any((t) =>
        t.direction == TransferDirection.receiving &&
        (t.status == TransferStatus.inProgress ||
            t.status == TransferStatus.pending));
    if (hasActiveReceive) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A file is being received. Wait for it to complete.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // Start async indexing — show spinner in the banner
    setState(() => _isIndexingDrop = true);

    // Switch to Send tab immediately so user sees the device list
    _switchTab(1);

    // Scan files/folders on a background isolate to avoid UI freeze
    final newSources = await _indexDroppedItems(details.files);

    if (!mounted) return;

    if (newSources.isEmpty) {
      setState(() => _isIndexingDrop = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No files found in the dropped items.'),
            duration: Duration(seconds: 2)),
      );
      return;
    }

    setState(() {
      // Merge with any existing pending drops, deduplicating by path
      final existing = {for (final f in _pendingDropFiles) f.path};
      final deduped =
          newSources.where((s) => !existing.contains(s.path)).toList();
      _pendingDropFiles = [..._pendingDropFiles, ...deduped];
      _isIndexingDrop = false;
    });
  }

  /// Recursively indexes dropped XFiles into [FileSource] list.
  /// Runs synchronously but called after a frame so UI stays responsive.
  static Future<List<FileSource>> _indexDroppedItems(
      List<XFile> xfiles) async {
    final result = <FileSource>[];
    for (final xf in xfiles) {
      final f = File(xf.path);
      FileStat stat;
      try {
        stat = f.statSync();
      } catch (_) {
        continue;
      }
      if (stat.type == FileSystemEntityType.directory) {
        result.addAll(_scanDir(Directory(xf.path)));
      } else if (stat.type == FileSystemEntityType.file) {
        result.add(FileSource(
          name: xf.name,
          size: stat.size,
          path: xf.path,
        ));
      }
    }
    return result;
  }

  static List<FileSource> _scanDir(Directory dir) {
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

  void _onPageChanged(int index) {
    if (_tab == index) return;
    setState(() {
      _tab = index;
    });
    context.read<DiscoveryService>().setReceivingMode(index == 0);
  }

  @override
  void dispose() {
    context.read<ShareIntentService>().removeListener(_onShareIntentChanged);
    // Leave receive mode when screen closes
    context.read<DiscoveryService>().setReceivingMode(false);
    _requestSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transferService = context.watch<FileTransferService>();
    final discoveryService = context.watch<DiscoveryService>();
    // Issue 1 fix: double-guard to exclude self by both ID and IP,
    // preventing the self-send glitch when _self is null during startup.
    final selfId = widget.selfDevice.id;
    final selfIp = widget.selfDevice.ip;
    final peers = discoveryService.peers
        .where((p) =>
            p.isReceiving && p.id != selfId && p.ip != selfIp)
        .toList();
    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    Widget scaffold = Scaffold(
      backgroundColor: AppTheme.bgOf(context),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // ── Header ──────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 20, 0),
                  child: Row(
                    children: [
                      Text(
                        'LocalShare',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () => AppRoutes.push(
                            context,
                            SettingsScreen(
                                selfIp: widget.selfDevice.ip,
                                selfName: widget.selfDevice.name)),
                        icon: Icon(Icons.settings_outlined,
                            color: AppTheme.secondaryOf(context), size: 22),
                        tooltip: 'Settings',
                      ),
                    ],
                  ),
                ),
                // ── Main content ─────────────────────────────────────────
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: _onPageChanged,
                    physics: const ClampingScrollPhysics(),
                    children: [
                      _buildReceiveTab(context, transferService),
                      _buildSendTab(context, peers, transferService),
                    ],
                  ),
                ),
                // ── Bottom pill bar ──────────────────────────────────────
                _BottomPillBar(selected: _tab, onTap: _switchTab),
                const SizedBox(height: 24),
              ],
            ),

            // ── Global drag-hover overlay (premium) ───────────────────
            AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              opacity: _isDragHovering ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_isDragHovering,
                child: DragDropOverlay(
                  isHovering: _isDragHovering,
                  fileCount: _dragFileCount,
                  firstFileName: _dragFirstFileName,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // Wrap entire window in DropTarget on desktop only
    if (isDesktop) {
      return DropTarget(
        onDragDone: _onGlobalDrop,
        onDragEntered: (_) => setState(() {
          _isDragHovering = true;
        }),
        onDragExited: (_) => setState(() {
          _isDragHovering = false;
          _dragFileCount = 0;
          _dragFirstFileName = null;
        }),
        child: scaffold,
      );
    }
    return scaffold;
  }

  // ── Receive tab ───────────────────────────────────────────────────────────
  Widget _buildReceiveTab(
      BuildContext context, FileTransferService transferService) {
    // Only show actively in-progress / pending transfers on the receive tab.
    // Completed / failed / cancelled items are visible only in history.
    final activeReceived = transferService.transfers
        .where((t) =>
            t.direction == TransferDirection.receiving &&
            (t.status == TransferStatus.inProgress ||
                t.status == TransferStatus.pending))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 16, 0),
          child: Row(
            children: [
              Text('Incoming Files',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              // Device code badge — sender can identify this device by #XXX
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Your code',
                    style: TextStyle(
                      color: AppTheme.mutedOf(context),
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.accentPrimary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color:
                              AppTheme.accentPrimary.withValues(alpha: 0.30)),
                    ),
                    child: Text(
                      deviceCode(widget.selfDevice.ip),
                      style: const TextStyle(
                        color: AppTheme.accentPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'monospace',
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: activeReceived.isEmpty
              ? _ReceivePlaceholder()
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: activeReceived.length,
                  itemBuilder: (ctx, i) {
                    final t = activeReceived[i];
                    return TransferCard(
                      key: ValueKey(t.id),
                      item: t,
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ── Send tab ──────────────────────────────────────────────────────────────
  Widget _buildSendTab(
    BuildContext context,
    List<DeviceInfo> peers,
    FileTransferService transferService,
  ) {
    final discoveryService = context.read<DiscoveryService>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),

        // ── Pending files banner (share intent OR global drag-drop) ─────
        if (_sharedFileSources.isNotEmpty ||
            _pendingDropFiles.isNotEmpty ||
            _isIndexingDrop) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.accentPrimary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: AppTheme.accentPrimary.withValues(alpha: 0.30)),
              ),
              child: Row(
                children: [
                  if (_isIndexingDrop)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppTheme.accentPrimary),
                    )
                  else
                    const Icon(Icons.attach_file_rounded,
                        size: 18, color: AppTheme.accentPrimary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _isIndexingDrop
                          ? 'Scanning dropped files…'
                          : _bannerText,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (!_isIndexingDrop)
                    GestureDetector(
                      onTap: () => setState(() {
                        _sharedFileSources = [];
                        _pendingDropFiles = [];
                      }),
                      child: Icon(Icons.close_rounded,
                          size: 16, color: AppTheme.mutedOf(context)),
                    ),
                ],
              ),
            ),
          ),
        ],

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 12, 0),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Nearby Devices',
                      style: Theme.of(context).textTheme.titleMedium),
                  if (_isRefreshing)
                    Text('Scanning…',
                        style: TextStyle(
                            color: AppTheme.mutedOf(context), fontSize: 11)),
                ],
              ),
              const Spacer(),
              Tooltip(
                message: 'Refresh device list',
                child: AnimatedRotation(
                  turns: _isRefreshing ? 1 : 0,
                  duration: const Duration(milliseconds: 800),
                  child: IconButton(
                    onPressed: _isRefreshing
                        ? null
                        : () => _doRefresh(discoveryService),
                    icon: Icon(
                      Icons.refresh_rounded,
                      size: 22,
                      color: _isRefreshing
                          ? AppTheme.mutedOf(context)
                          : AppTheme.secondaryOf(context),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: peers.isEmpty
              ? _NoPeersPlaceholder()
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  itemCount: peers.length,
                  itemBuilder: (ctx, i) {
                    final peer = peers[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _DeviceTile(
                        name: peer.name,
                        code: deviceCode(peer.ip),
                        platform: peer.platform,
                        onTap: () =>
                            _navigateToSend(ctx, peer, transferService),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _doRefresh(DiscoveryService discoveryService) async {
    setState(() => _isRefreshing = true);
    await discoveryService.forceRefresh();
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted) setState(() => _isRefreshing = false);
  }

  /// Banner text summarizing pending files from both share intents and drops.
  String get _bannerText {
    final total = _sharedFileSources.length + _pendingDropFiles.length;
    if (total == 0) return '';
    final sources = <String>[];
    if (_sharedFileSources.isNotEmpty) {
      sources.add(
          '${_sharedFileSources.length} shared file${_sharedFileSources.length > 1 ? 's' : ''}');
    }
    if (_pendingDropFiles.isNotEmpty) {
      sources.add(
          '${_pendingDropFiles.length} dropped file${_pendingDropFiles.length > 1 ? 's' : ''}');
    }
    return '${sources.join(' + ')} ready — tap a device to send';
  }

  void _navigateToSend(
      BuildContext context, DeviceInfo target, FileTransferService ts) {
    // Merge share-intent FileSources and drag-dropped FileSources.
    final sharedSources = List<FileSource>.from(_sharedFileSources);
    final droppedSources = List<FileSource>.from(_pendingDropFiles);

    if (_sharedFileSources.isNotEmpty || _pendingDropFiles.isNotEmpty) {
      setState(() {
        _sharedFileSources = [];
        _pendingDropFiles = [];
      });
    }

    AppRoutes.push(
      context,
      SendScreen(
        target: target,
        transferService: ts,
        // Both share-intent and drag-drop sources go via initialFileSources —
        // they are already FileSource objects with zero-copy stream factories.
        initialFileSources: [...sharedSources, ...droppedSources],
      ),
    );
  }

}

// ── Accept / Reject dialog ────────────────────────────────────────────────────
class _AcceptDialog extends StatelessWidget {
  final IncomingRequest request;
  const _AcceptDialog({required this.request});

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final fileCount = request.files.length;
    final totalLabel =
        '$fileCount ${fileCount == 1 ? 'file' : 'files'}  ·  ${_fmtBytes(request.totalSize)}';

    return AlertDialog(
      backgroundColor: AppTheme.surfaceOf(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.accentPrimary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.file_download_rounded,
                color: AppTheme.accentPrimary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              fileCount == 1 ? 'Incoming File' : 'Incoming Files ($fileCount)',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(
              icon: Icons.person_rounded,
              label: 'From',
              value: request.senderName),
          const SizedBox(height: 10),
          _InfoRow(
              icon: Icons.data_usage_rounded,
              label: 'Total',
              value: totalLabel),
          const SizedBox(height: 10),
          // File list
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: request.files.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (_, i) {
                final f = request.files[i];
                return Row(
                  children: [
                    Icon(Icons.insert_drive_file_rounded,
                        size: 14, color: AppTheme.accentPrimary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(f.name,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurface),
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 6),
                    Text(_fmtBytes(f.size),
                        style: TextStyle(
                            fontSize: 11, color: AppTheme.mutedOf(context))),
                  ],
                );
              },
            ),
          ),
          Divider(color: AppTheme.borderOf(context), height: 24),
          Text(
            'Do you want to receive ${fileCount == 1 ? 'this file' : 'these files'}?',
            style:
                TextStyle(color: AppTheme.secondaryOf(context), fontSize: 13),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () {
              request.reject();
              Navigator.of(context).pop(false);
            },
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AppTheme.borderOf(context)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Decline',
                style: TextStyle(
                    color: AppTheme.error, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () {
              request.accept();
              Navigator.of(context).pop(true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentPrimary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              elevation: 0,
            ),
            child: const Text('Accept',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppTheme.secondaryOf(context)),
        const SizedBox(width: 8),
        Text('$label: ',
            style: TextStyle(
                color: AppTheme.secondaryOf(context),
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ],
    );
  }
}

// ── Bottom pill bar ───────────────────────────────────────────────────────────
class _BottomPillBar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onTap;
  const _BottomPillBar({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: AppTheme.surfaceOf(context),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: AppTheme.borderOf(context)),
        ),
        child: Stack(
          children: [
            // Sliding indicator pill
            AnimatedAlign(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutBack,
              alignment:
                  selected == 0 ? Alignment.centerLeft : Alignment.centerRight,
              child: FractionallySizedBox(
                widthFactor: 0.5,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.onSurface,
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                ),
              ),
            ),
            // Tab labels (on top of indicator)
            Row(
              children: [
                _PillTabLabel(
                  label: 'Receive',
                  selected: selected == 0,
                  onTap: () => onTap(0),
                ),
                _PillTabLabel(
                  label: 'Send',
                  selected: selected == 1,
                  onTap: () => onTap(1),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PillTabLabel extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _PillTabLabel(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              color: selected
                  ? Theme.of(context).scaffoldBackgroundColor
                  : AppTheme.secondaryOf(context),
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}

// ── Device tile ───────────────────────────────────────────────────────────────
class _DeviceTile extends StatelessWidget {
  final String name;
  /// Short session code derived from IP, e.g. "#283".
  final String code;
  final String platform;
  final VoidCallback? onTap;

  const _DeviceTile({
    required this.name,
    required this.code,
    this.platform = '',
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final surf = AppTheme.surfaceOf(context);
    final border = AppTheme.borderOf(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: surf,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Icon(
              deviceIcon(platform),
              size: 18,
              color: AppTheme.secondaryOf(context),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Show short session code instead of raw IP
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.accentPrimary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                code,
                style: const TextStyle(
                  color: AppTheme.accentPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.arrow_forward_ios_rounded,
                size: 12, color: AppTheme.mutedOf(context)),
          ],
        ),
      ),
    );
  }
}

// ── Placeholders ──────────────────────────────────────────────────────────────
class _ReceivePlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget lottie = Lottie.asset(
      'assets/animations/Loader cat.json',
      width: 320,
      height: 229,
      fit: BoxFit.contain,
      repeat: true,
      // Only hide shadows in dark mode (opacity = 0)
      delegates: isDark
          ? LottieDelegates(
              values: [
                ValueDelegate.opacity(['Ombre', '**'], value: 0),
                ValueDelegate.opacity(['Queue Ombre', '**'], value: 0),
              ],
            )
          : null,
    );

    // In dark mode, boost brightness so the dark-navy cat is visible
    if (isDark) {
      lottie = ColorFiltered(
        colorFilter: const ColorFilter.matrix([
          // Multiply RGB channels by ~2.5× — dark navy becomes medium blue
          2.5, 0,   0,   0, 0,
          0,   2.5, 0,   0, 0,
          0,   0,   2.5, 0, 0,
          0,   0,   0,   1, 0,
        ]),
        child: lottie,
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          lottie,
          const SizedBox(height: 8),
          Text('Waiting for files…',
              style: TextStyle(
                  color: AppTheme.secondaryOf(context), fontSize: 14)),
          const SizedBox(height: 4),
          Text('Accept a transfer request to see it here.',
              style: TextStyle(color: AppTheme.mutedOf(context), fontSize: 12)),
        ],
      ),
    );
  }
}

class _NoPeersPlaceholder extends StatelessWidget {
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
            child: Icon(Icons.wifi_find_rounded,
                size: 32, color: AppTheme.mutedOf(context)),
          ),
          const SizedBox(height: 16),
          Text('Scanning for devices…',
              style: TextStyle(
                  color: AppTheme.secondaryOf(context), fontSize: 14)),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text('Open LocalShare on another device on the same Wi-Fi.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: AppTheme.mutedOf(context), fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
