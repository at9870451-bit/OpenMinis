import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:amore/data/agent_store.dart';

/// The Agent Runtime pages are only useful if they read real files. These tests
/// build the same directory layout the sandbox uses and assert the parsing.
void main() {
  late Directory tmp;
  late AgentStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('amore_agent_');
    store = AgentStore(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('skills are listed with their front-matter description', () async {
    final dir = Directory(p.join(tmp.path, 'skills', 'pdf-tools'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'SKILL.md')).writeAsStringSync(
      '---\nname: pdf-tools\ndescription: Extract text from PDFs\n---\n\nBody',
    );
    // A dot-folder must be ignored.
    Directory(p.join(tmp.path, 'skills', '.hidden')).createSync(recursive: true);

    final skills = await store.listSkills();
    expect(skills.length, 1);
    expect(skills.single.name, 'pdf-tools');
    expect(skills.single.description, 'Extract text from PDFs');

    expect(await store.readSkill('pdf-tools'), contains('Body'));
  });

  test('memory lists markdown files newest first', () async {
    final dir = Directory(p.join(tmp.path, 'memory'))..createSync(recursive: true);
    final old = File(p.join(dir.path, '2026-01-01.md'))
      ..writeAsStringSync('old');
    old.setLastModifiedSync(DateTime(2026, 1, 1));
    final recent = File(p.join(dir.path, '2026-02-01.md'))
      ..writeAsStringSync('recent');
    recent.setLastModifiedSync(DateTime(2026, 2, 1));
    File(p.join(dir.path, 'notes.txt')).writeAsStringSync('ignored');

    final entries = await store.listMemory();
    expect(entries.length, 2);
    expect(entries.first.title, '2026-02-01');
  });

  test('mcp servers parse and the enabled flag round-trips', () async {
    final dir = Directory(p.join(tmp.path, 'mcp-servers'))
      ..createSync(recursive: true);
    final file = File(p.join(dir.path, 'servers.json'));
    file.writeAsStringSync(jsonEncode([
      {'name': 'filesystem', 'url': 'npx -y fs', 'enabled': true},
      {'name': 'search', 'url': 'https://mcp.example.com', 'enabled': false},
    ]));

    var servers = await store.listMcpServers();
    expect(servers.length, 2);
    expect(servers.first.name, 'filesystem');
    expect(servers.last.enabled, isFalse);

    await store.setMcpEnabled('search', true);
    servers = await store.listMcpServers();
    expect(servers.last.enabled, isTrue);

    // Unrelated fields must survive the rewrite.
    final raw = jsonDecode(file.readAsStringSync()) as List;
    expect((raw.last as Map)['url'], 'https://mcp.example.com');
  });

  test('a corrupt servers.json degrades to an empty list', () async {
    final dir = Directory(p.join(tmp.path, 'mcp-servers'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'servers.json')).writeAsStringSync('{not json');
    expect(await store.listMcpServers(), isEmpty);
  });
}
