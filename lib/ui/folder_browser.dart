import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/mirror_validator.dart';

/// A folder picker for platforms without one that returns a path (Android).
///
/// Lists the subfolders of the current folder, shows whether it holds a
/// mirror (`resolveMirrorRoot`), and pops with the chosen path.
class FolderBrowser extends StatefulWidget {
  const FolderBrowser({super.key, required this.roots, this.initial});

  /// Top-level storage folders (main storage, removable cards).
  final List<String> roots;

  /// Folder to open first; defaults to the first root.
  final String? initial;

  @override
  State<FolderBrowser> createState() => _FolderBrowserState();
}

class _FolderBrowserState extends State<FolderBrowser> {
  late String _dir;
  List<String> _children = const [];
  String? _error;
  bool _isMirror = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _open(initial != null && Directory(initial).existsSync() ? initial : widget.roots.first);
  }

  bool get _atRoot => widget.roots.any((root) => p.equals(root, _dir));

  void _open(String dir) {
    List<String> children = const [];
    String? error;
    try {
      children =
          Directory(dir)
              .listSync(followLinks: false)
              .whereType<Directory>()
              .map((d) => d.path)
              .where((path) => !p.basename(path).startsWith('.'))
              .toList()
            ..sort((a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
    } on FileSystemException catch (e) {
      error = 'Cannot open this folder: ${e.osError?.message ?? e.message}';
    }
    setState(() {
      _dir = dir;
      _children = children;
      _error = error;
      _isMirror = resolveMirrorRoot(dir) != null;
    });
  }

  String _label(String path) {
    final index = widget.roots.indexOf(path);
    if (index == 0) return 'Internal storage';
    if (index > 0) return 'SD card ${widget.roots.length > 2 ? index : ''}'.trim();
    return p.basename(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final root = widget.roots.firstWhere((r) => p.isWithin(r, _dir) || p.equals(r, _dir), orElse: () => _dir);
    final shown = p.equals(root, _dir) ? _label(root) : p.join(_label(root), p.relative(_dir, from: root));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose the mirror folder'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.roots.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final r in widget.roots)
                      ChoiceChip(label: Text(_label(r)), selected: p.equals(r, root), onSelected: (_) => _open(r)),
                  ],
                ),
              ),
            ListTile(
              leading: Icon(
                _isMirror ? Icons.check_circle : Icons.folder_open,
                color: _isMirror ? Colors.green : theme.colorScheme.onSurfaceVariant,
              ),
              title: Text(shown, style: theme.textTheme.titleSmall),
              subtitle: Text(
                _isMirror
                    ? 'Mirror found: use this folder'
                    : 'Open the folder that contains playgta5.com (or playgta5.com itself)',
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                    )
                  : ListView(
                      children: [
                        if (!_atRoot)
                          ListTile(
                            leading: const Icon(Icons.arrow_upward),
                            title: const Text('..'),
                            onTap: () => _open(p.dirname(_dir)),
                          ),
                        for (final child in _children)
                          ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(p.basename(child)),
                            onTap: () => _open(child),
                          ),
                        if (_children.isEmpty)
                          const Padding(padding: EdgeInsets.all(24), child: Text('No folders here.')),
                      ],
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                key: const Key('use-folder'),
                onPressed: () => Navigator.of(context).pop(_dir),
                icon: const Icon(Icons.check),
                label: const Text('Use this folder'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
