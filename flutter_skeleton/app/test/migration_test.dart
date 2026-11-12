import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sq;

import 'package:amore/data/db/app_database.dart';
import 'package:amore/data/migration/legacy_migrator.dart';
import 'package:amore/src/rust/api/migration.dart';
import 'package:amore/src/rust/frb_generated.dart';

/// Stage-2 acceptance test:
///  1. build a legacy minis.db with the Swift schema,
///  2. migrate it read-only into a Drift database,
///  3. verify counts in Rust,
///  4. assert the legacy file is untouched.
void main() {
  setUpAll(() async => RustLib.init());

  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('amore_mig_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('migrates sessions/messages and verifies counts in Rust', () async {
    final legacyPath = p.join(tmp.path, 'minis.db');
    final legacy = sq.sqlite3.open(legacyPath);
    legacy.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY, title TEXT, model_id TEXT NOT NULL,
        created_at REAL NOT NULL, updated_at REAL NOT NULL
      )''');
    legacy.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
        parts_json TEXT NOT NULL, created_at REAL NOT NULL,
        token_usage TEXT, sort_order INTEGER NOT NULL
      )''');
    legacy.execute(
      "INSERT INTO sessions VALUES ('s1','迁移测试','m1',1.0,2.0)",
    );
    legacy.execute(
      "INSERT INTO messages VALUES ('m1','s1','user','[]',1.0,NULL,0)",
    );
    legacy.execute(
      "INSERT INTO messages VALUES ('m2','s1','assistant','[]',2.0,NULL,1)",
    );
    legacy.dispose();

    final before = File(legacyPath).readAsBytesSync();

    final appDb = AppDatabase(NativeDatabase.memory());
    final migrator = LegacyMigrator(appDb);
    await migrator.migrate(legacyPath: legacyPath);

    final counts = await migrator.migratedCounts();
    expect(counts['sessions'], 1);
    expect(counts['messages'], 2);

    // Cross-check in Rust — the same verification the app will run on device.
    final report = verifyMigration(
      counts: [
        TableCount(table: 'sessions', legacy: 1, migrated: counts['sessions']!),
        TableCount(table: 'messages', legacy: 2, migrated: counts['messages']!),
      ],
    );
    expect(report.ok, isTrue);
    expect(report.totalLegacy, 3);

    // The legacy file must be byte-identical: opened read-only, never written.
    expect(File(legacyPath).readAsBytesSync(), before);

    await appDb.close();
  });
}
