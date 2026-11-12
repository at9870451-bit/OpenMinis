import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import 'tables.dart';

part 'app_database.g.dart';

/// The new (Flutter) database. It never opens the legacy file for writing —
/// migration reads the old minis.db read-only and copies rows in.
@DriftDatabase(tables: [Sessions, Messages, Folders])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  AppDatabase.open(String path) : super(NativeDatabase(File(path)));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_messages_session '
            'ON messages(session_id, sort_order)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_msg_sess_role_sort '
            'ON messages(session_id, role, sort_order DESC)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_sessions_updated_at '
            'ON sessions(updated_at DESC)',
          );
        },
      );
}

String defaultDatabasePath(String documentsDir) =>
    p.join(documentsDir, 'amore_flutter.db');
