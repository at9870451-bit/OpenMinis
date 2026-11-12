import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amore/data/chat_models.dart';
import 'package:amore/data/chat_repository.dart';
import 'package:amore/data/db/app_database.dart';

/// Real CRUD against an in-memory Drift database: create a session, write
/// messages, read them back in order, and refresh the sidebar ordering.
void main() {
  late AppDatabase db;
  late ChatRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ChatRepository(db);
  });
  tearDown(() async => db.close());

  test('sessions round-trip with title and ordering', () async {
    await repo.createSession('s1', title: 'First chat');
    await repo.createSession('s2', title: 'Second chat');
    await repo.touchSession('s1'); // newest update wins

    final list = await repo.sessions();
    expect(list.length, 2);
    expect(list.first.id, 's1');
    expect(list.first.title, 'First chat');
  });

  test('messages keep order and text survives parts_json', () async {
    await repo.createSession('s1', title: 'Demo');
    final now = DateTime.now();
    await repo.upsertMessage(ChatMessage(
      id: 'm2',
      sessionId: 's1',
      role: 'assistant',
      text: '你好，世界',
      createdAt: now,
      sortOrder: 1,
    ));
    await repo.upsertMessage(ChatMessage(
      id: 'm1',
      sessionId: 's1',
      role: 'user',
      text: 'hello "quoted" line\nbreak',
      createdAt: now,
      sortOrder: 0,
    ));

    final msgs = await repo.messages('s1');
    expect(msgs.length, 2);
    expect(msgs.first.id, 'm1');
    expect(msgs.first.text, 'hello "quoted" line\nbreak');
    expect(msgs.last.text, '你好，世界');
  });

  test('upsert is idempotent on the same id', () async {
    await repo.createSession('s1');
    final m = ChatMessage(
      id: 'm1',
      sessionId: 's1',
      role: 'assistant',
      text: 'v1',
      createdAt: DateTime.now(),
      sortOrder: 0,
    );
    await repo.upsertMessage(m);
    await repo.upsertMessage(m.copyWith(text: 'v2'));
    final msgs = await repo.messages('s1');
    expect(msgs.length, 1);
    expect(msgs.single.text, 'v2');
  });
}
