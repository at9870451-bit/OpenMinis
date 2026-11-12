import 'package:drift/drift.dart' show UpdateKind, Variable;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'chat_models.dart';
import 'db/app_database.dart';

/// Real reads/writes against the Drift database. The schema matches the legacy
/// Swift `minis.db`, so migrated rows show up here unchanged.
class ChatRepository {
  ChatRepository(this.db);

  final AppDatabase db;

  static String pathFor(String documentsDir) =>
      p.join(documentsDir, 'amore_flutter.db');

  Future<List<ChatSessionSummary>> sessions() async {
    final rows = await db.customSelect(
      'SELECT id, title, updated_at FROM sessions ORDER BY updated_at DESC',
    ).get();
    return [
      for (final r in rows)
        ChatSessionSummary(
          id: r.data['id'] as String,
          title: (r.data['title'] as String?)?.trim().isNotEmpty == true
              ? r.data['title'] as String
              : 'New Chat',
          updatedAt: _date(r.data['updated_at']),
        ),
    ];
  }

  Future<List<ChatMessage>> messages(String sessionId) async {
    final rows = await db.customSelect(
      'SELECT id, session_id, role, parts_json, created_at, sort_order '
      'FROM messages WHERE session_id = ? ORDER BY sort_order ASC',
      variables: [Variable(sessionId)],
    ).get();
    return [
      for (final r in rows)
        ChatMessage(
          id: r.data['id'] as String,
          sessionId: r.data['session_id'] as String,
          role: r.data['role'] as String,
          text: _extractText(r.data['parts_json'] as String?),
          createdAt: _date(r.data['created_at']),
          sortOrder: (r.data['sort_order'] as int?) ?? 0,
        ),
    ];
  }

  Future<void> createSession(String id, {String title = 'New Chat'}) async {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    await db.customInsert(
      'INSERT OR REPLACE INTO sessions (id, title, model_id, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?)',
      variables: [
        Variable(id),
        Variable(title),
        Variable('unset'),
        Variable(now),
        Variable(now),
      ],
    );
  }

  Future<void> upsertMessage(ChatMessage m) async {
    await db.customInsert(
      'INSERT OR REPLACE INTO messages '
      '(id, session_id, role, parts_json, created_at, sort_order) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      variables: [
        Variable(m.id),
        Variable(m.sessionId),
        Variable(m.role),
        Variable('[{"type":"text","text":${_jsonString(m.text)}}]'),
        Variable(m.createdAt.millisecondsSinceEpoch / 1000.0),
        Variable(m.sortOrder),
      ],
    );
  }

  Future<void> touchSession(String id) async {
    await db.customUpdate(
      'UPDATE sessions SET updated_at = ? WHERE id = ?',
      variables: [
        Variable(DateTime.now().millisecondsSinceEpoch / 1000.0),
        Variable(id),
      ],
      updateKind: UpdateKind.update,
    );
  }

  static DateTime _date(Object? raw) {
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch((raw * 1000).round());
    }
    return DateTime.now();
  }

  /// Legacy parts_json is a JSON array of blocks; take the first text block.
  static String _extractText(String? partsJson) {
    if (partsJson == null || partsJson.isEmpty) return '';
    // Cheap path first: most rows are a single text block.
    final marker = '"text":';
    final i = partsJson.indexOf(marker);
    if (i < 0) return '';
    final start = partsJson.indexOf('"', i + marker.length);
    if (start < 0) return '';
    final buf = StringBuffer();
    var j = start + 1;
    while (j < partsJson.length) {
      final c = partsJson[j];
      if (c == r'\') {
        j += 2;
        continue;
      }
      if (c == '"') break;
      buf.write(c);
      j++;
    }
    return buf.toString();
  }

  static String _jsonString(String s) {
    final escaped = s
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n');
    return '"$escaped"';
  }
}

/// Opens the app database (created on first use).
Future<ChatRepository> openRepository() async {
  final dir = await getApplicationDocumentsDirectory();
  final db = AppDatabase.open(ChatRepository.pathFor(dir.path));
  return ChatRepository(db);
}
