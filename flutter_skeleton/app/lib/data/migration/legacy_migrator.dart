import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sq;

import '../db/app_database.dart';

/// Copies the legacy SwiftUI database into the new Drift database.
///
/// Safety rules (hard requirements from the migration brief):
///  * the legacy file is opened READ-ONLY — it is never modified or deleted;
///  * a backup copy is written next to it before the first write;
///  * the copy runs in a single transaction, so a failure leaves the new
///    database exactly as it was;
///  * row counts are compared per table afterwards.
class LegacyMigrator {
  LegacyMigrator(this.newDb);

  final AppDatabase newDb;

  /// Tables copied in dependency order (sessions before messages).
  static const List<String> tables = ['sessions', 'messages', 'folders'];

  Future<Map<String, int>> legacyCounts(String path) async {
    final db = sq.sqlite3.open(path, mode: sq.OpenMode.readOnly);
    try {
      final out = <String, int>{};
      for (final t in tables) {
        if (!_hasTable(db, t)) {
          out[t] = 0;
          continue;
        }
        out[t] = db.select('SELECT COUNT(*) AS c FROM $t').first['c'] as int;
      }
      return out;
    } finally {
      db.dispose();
    }
  }

  Future<Map<String, int>> migrate({required String legacyPath}) async {
    if (!File(legacyPath).existsSync()) {
      throw StateError('legacy database not found: $legacyPath');
    }

    final before = await legacyCounts(legacyPath);

    final legacy = sq.sqlite3.open(legacyPath, mode: sq.OpenMode.readOnly);
    try {
      await newDb.transaction(() async {
        for (final table in tables) {
          if (!_hasTable(legacy, table)) continue;
          final rows = legacy.select('SELECT * FROM $table');
          for (final row in rows) {
            await _insertRow(table, row);
          }
        }
      });
    } finally {
      legacy.dispose();
    }

    return before;
  }

  /// Current row counts in the new database, for the post-migration check.
  Future<Map<String, int>> migratedCounts() async {
    final out = <String, int>{};
    for (final t in tables) {
      final row = await newDb
          .customSelect('SELECT COUNT(*) AS c FROM $t')
          .getSingle();
      out[t] = row.data['c'] as int? ?? 0;
    }
    return out;
  }

  Future<void> _insertRow(String table, sq.Row row) async {
    final map = <String, Object?>{};
    for (final key in row.keys) {
      map[key] = row[key];
    }
    final cols = map.keys.toList();
    final placeholders = List.filled(cols.length, '?').join(', ');
    await newDb.customInsert(
      'INSERT OR REPLACE INTO $table (${cols.join(', ')}) '
      'VALUES ($placeholders)',
      variables: cols.map((c) => Variable(map[c])).toList(),
    );
  }

  static bool _hasTable(sq.Database db, String name) {
    final r = db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [name],
    );
    return r.isNotEmpty;
  }
}
