import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/theme/amore_theme.dart';
import '../../data/db/app_database.dart';

/// Real numbers from the Drift database — not placeholders.
class StoragePage extends StatefulWidget {
  const StoragePage({super.key});

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  String? _path;
  int? _sessions;
  int? _messages;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = p.join(dir.path, 'amore_flutter.db');
      final db = AppDatabase.open(path);
      final s = await db.customSelect('SELECT COUNT(*) c FROM sessions').getSingle();
      final m = await db.customSelect('SELECT COUNT(*) c FROM messages').getSingle();
      await db.close();
      if (!mounted) return;
      setState(() {
        _path = path;
        _sessions = s.data['c'] as int? ?? 0;
        _messages = m.data['c'] as int? ?? 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AmoreTheme.groupedBackground,
      appBar: AppBar(
        backgroundColor: AmoreTheme.groupedBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Storage',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        centerTitle: true,
      ),
      body: _error != null
          ? Center(
              child: Text(_error!,
                  style: const TextStyle(color: AmoreTheme.danger)))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Material(
                  color: AmoreTheme.background,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AmoreTheme.rCard),
                    side: const BorderSide(color: AmoreTheme.separator, width: 0.5),
                  ),
                  child: Column(
                    children: [
                      _stat('Sessions', _sessions),
                      const Divider(height: 0.5, color: AmoreTheme.separator),
                      _stat('Messages', _messages),
                      const Divider(height: 0.5, color: AmoreTheme.separator),
                      ListTile(
                        title: const Text('Database',
                            style: TextStyle(
                                fontSize: 15, color: AmoreTheme.textPrimary)),
                        subtitle: Text(
                          _path ?? '…',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: AmoreTheme.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _stat(String label, int? value) => ListTile(
        title: Text(label,
            style: const TextStyle(fontSize: 15, color: AmoreTheme.textPrimary)),
        trailing: Text(
          value?.toString() ?? '…',
          style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AmoreTheme.textPrimary),
        ),
      );
}
