import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/tcp_service.dart';
import '../theme/app_routes.dart';
import '../theme/app_theme.dart';
import 'history_screen.dart';

class SettingsScreen extends StatefulWidget {
  final String selfIp;
  final String selfName;
  const SettingsScreen(
      {super.key, this.selfIp = '---', this.selfName = 'This Device'});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameCtrl;
  bool _editingName = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsService>();
    // Pre-fill with persisted name or the passed-in selfName
    final storedName = settings.deviceName;
    _nameCtrl = TextEditingController(
        text: storedName.isNotEmpty ? storedName : widget.selfName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _saveName() {
    context.read<SettingsService>().setDeviceName(_nameCtrl.text);
    setState(() => _editingName = false);
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final isDark = settings.themeMode == ThemeMode.dark;

    return Scaffold(
      backgroundColor: AppTheme.bgOf(context),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 14, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_rounded, size: 26),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => AppRoutes.push(context, const HistoryScreen()),
                    icon: Icon(Icons.history_rounded,
                        size: 26, color: AppTheme.secondaryOf(context)),
                    tooltip: 'History',
                  ),
                ],
              ),
            ),

            Expanded(
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 22),
                children: [
                  const SizedBox(height: 8),

                  // ── Appearance ──────────────────────────────────────────
                  _SectionTitle('Appearance'),
                  const SizedBox(height: 12),
                  _RadioOption(
                    icon: Icons.light_mode_rounded,
                    label: 'Light',
                    selected: !isDark,
                    onTap: () => context
                        .read<SettingsService>()
                        .setThemeMode(ThemeMode.light),
                  ),
                  const SizedBox(height: 10),
                  _RadioOption(
                    icon: Icons.dark_mode_rounded,
                    label: 'Dark',
                    selected: isDark,
                    onTap: () => context
                        .read<SettingsService>()
                        .setThemeMode(ThemeMode.dark),
                  ),

                  const SizedBox(height: 30),

                  // ── Save Location ───────────────────────────────────────
                  _SectionTitle('Save Location'),
                  const SizedBox(height: 12),

                  // Current saved location card
                  _Card(
                    child: Row(
                      children: [
                        Icon(Icons.folder_outlined,
                            size: 22,
                            color: AppTheme.secondaryOf(context)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Current Saved Location',
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  )),
                              const SizedBox(height: 3),
                              Text(
                                settings.customSavePath != null
                                    ? _shortenPath(settings.customSavePath!)
                                    : 'Default downloads folder',
                                style: TextStyle(
                                    color: AppTheme.mutedOf(context),
                                    fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _OutlineButton(
                    icon: Icons.edit_location_alt_outlined,
                    label: 'Change Location',
                    onTap: () => _pickFolder(context, settings),
                  ),
                  if (settings.customSavePath != null) ...[
                    const SizedBox(height: 10),
                    _OutlineButton(
                      icon: Icons.restore_rounded,
                      label: 'Reset to default',
                      onTap: () =>
                          context.read<SettingsService>().resetSavePath(),
                      isDestructive: true,
                    ),
                  ],

                  const SizedBox(height: 30),

                  // ── Advanced Options ────────────────────────────────────
                  _SectionTitle('Advanced Options'),
                  const SizedBox(height: 12),

                  // Device Name (editable)
                  _Card(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Device Name',
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15)),
                              const SizedBox(height: 6),
                              _editingName
                                  ? TextField(
                                      controller: _nameCtrl,
                                      autofocus: true,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface,
                                          fontSize: 15),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 10),
                                        hintText: 'Enter device name',
                                        hintStyle: TextStyle(
                                            color: AppTheme.mutedOf(context),
                                            fontSize: 14),
                                        filled: true,
                                        fillColor: AppTheme.bgOf(context),
                                        border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          borderSide: BorderSide(
                                              color:
                                                  AppTheme.borderOf(context)),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          borderSide: BorderSide(
                                              color:
                                                  AppTheme.borderOf(context)),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          borderSide: const BorderSide(
                                              color: AppTheme.accentPrimary,
                                              width: 1.5),
                                        ),
                                      ),
                                      onSubmitted: (_) => _saveName(),
                                    )
                                  : Text(
                                      settings.deviceName,
                                      style: TextStyle(
                                          color:
                                              AppTheme.secondaryOf(context),
                                          fontSize: 14),
                                    ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        _editingName
                            ? GestureDetector(
                                onTap: _saveName,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: AppTheme.accentPrimary,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Text('Save',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14)),
                                ),
                              )
                            : GestureDetector(
                                onTap: () =>
                                    setState(() => _editingName = true),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: AppTheme.bgOf(context),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                        color: AppTheme.borderOf(context)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.edit_rounded,
                                          size: 15,
                                          color:
                                              AppTheme.secondaryOf(context)),
                                      const SizedBox(width: 5),
                                      Text('Edit',
                                          style: TextStyle(
                                              color: AppTheme.secondaryOf(
                                                  context),
                                              fontWeight: FontWeight.w500,
                                              fontSize: 13)),
                                    ],
                                  ),
                                ),
                              ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 10),

                  // IP + Port row
                  Row(
                    children: [
                      Expanded(
                        child: _InfoBox(label: 'IP:', value: widget.selfIp),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child:
                            _InfoBox(label: 'Port:', value: '$kTransferPort'),
                      ),
                    ],
                  ),

                  // ── Save Media to Gallery (Android only) ────────────────
                  if (Platform.isAndroid) ...[
                    const SizedBox(height: 10),
                    _Card(
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              color: settings.saveToGallery
                                  ? AppTheme.accentPrimary.withValues(alpha: 0.15)
                                  : AppTheme.borderOf(context).withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.photo_library_rounded,
                              size: 20,
                              color: settings.saveToGallery
                                  ? AppTheme.accentPrimary
                                  : AppTheme.secondaryOf(context),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Save media to gallery',
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'Images, videos & audio appear in gallery apps',
                                  style: TextStyle(
                                    color: AppTheme.mutedOf(context),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch(
                            value: settings.saveToGallery,
                            onChanged: (v) => context
                                .read<SettingsService>()
                                .setSaveToGallery(v),
                            activeThumbColor: AppTheme.accentPrimary,
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFolder(
      BuildContext context, SettingsService settings) async {
    if (Platform.isAndroid) {
      // FilePicker returns SAF content URIs on Android which can't be used
      // as real file paths. Show a bottom sheet with real writable directories.
      await _showAndroidFolderPicker(context, settings);
    } else {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir != null) await settings.setSavePath(dir);
    }
  }

  /// Shows a bottom sheet on Android with pre-defined writable directories.
  Future<void> _showAndroidFolderPicker(
      BuildContext context, SettingsService settings) async {
    // Real paths we can write to on Android (no SAF needed).
    const base = '/storage/emulated/0';
    final options = [
      _FolderOption(
          label: 'Downloads › LocalShare',
          subtitle: 'Default — visible everywhere',
          icon: Icons.download_rounded,
          path: '$base/Download/LocalShare'),
      _FolderOption(
          label: 'Documents › LocalShare',
          subtitle: 'Internal storage / Documents',
          icon: Icons.description_outlined,
          path: '$base/Documents/LocalShare'),
      _FolderOption(
          label: 'Pictures › LocalShare',
          subtitle: 'Internal storage / Pictures',
          icon: Icons.image_outlined,
          path: '$base/Pictures/LocalShare'),
      _FolderOption(
          label: 'Movies › LocalShare',
          subtitle: 'Internal storage / Movies',
          icon: Icons.movie_outlined,
          path: '$base/Movies/LocalShare'),
      _FolderOption(
          label: 'Music › LocalShare',
          subtitle: 'Internal storage / Music',
          icon: Icons.music_note_outlined,
          path: '$base/Music/LocalShare'),
    ];

    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surfaceOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.borderOf(ctx),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Choose Save Folder',
                      style: TextStyle(
                          color: Theme.of(ctx).colorScheme.onSurface,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 12),
              ...options.map((opt) => ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 22, vertical: 2),
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: settings.customSavePath == opt.path
                            ? AppTheme.accentPrimary.withValues(alpha: 0.15)
                            : AppTheme.borderOf(ctx).withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(opt.icon,
                          size: 20,
                          color: settings.customSavePath == opt.path
                              ? AppTheme.accentPrimary
                              : AppTheme.secondaryOf(ctx)),
                    ),
                    title: Text(opt.label,
                        style: TextStyle(
                            color: Theme.of(ctx).colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                    subtitle: Text(opt.subtitle,
                        style: TextStyle(
                            color: AppTheme.mutedOf(ctx), fontSize: 12)),
                    trailing: settings.customSavePath == opt.path
                        ? Icon(Icons.check_circle_rounded,
                            color: AppTheme.accentPrimary, size: 20)
                        : null,
                    onTap: () async {
                      Navigator.of(ctx).pop();
                      await settings.setSavePath(opt.path);
                    },
                  )),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  String _shortenPath(String path) {
    final parts = path.replaceAll('\\', '/').split('/');
    if (parts.length <= 3) return path;
    return '…/${parts.sublist(parts.length - 2).join('/')}';
  }
}

// ── Helper widgets ──────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceOf(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderOf(context)),
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurface,
        fontSize: 19,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _RadioOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RadioOption({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: AppTheme.surfaceOf(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : AppTheme.borderOf(context),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 22,
                color: selected
                    ? Theme.of(context).colorScheme.onSurface
                    : AppTheme.secondaryOf(context)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w400,
                  fontSize: 16,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurface),
          ],
        ),
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  const _OutlineButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDestructive
        ? AppTheme.error
        : AppTheme.secondaryOf(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.surfaceOf(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.borderOf(context)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 10),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w500,
                    fontSize: 15)),
          ],
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  final String label;
  final String value;
  const _InfoBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceOf(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderOf(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: AppTheme.secondaryOf(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 5),
          Text(value,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

/// Data class for Android folder picker options.
class _FolderOption {
  final String label;
  final String subtitle;
  final IconData icon;
  final String path;
  const _FolderOption({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.path,
  });
}
