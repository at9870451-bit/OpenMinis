import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Reads the three agent-runtime surfaces that live inside the sandbox:
/// skills, memory and MCP server config.
///
/// Paths mirror the Swift implementation
/// (`Documents/alpine-rootfs/data/var/minis/...`). When the sandbox is not
/// present (bare Flutter build) the same layout is created under
/// `Documents/minis/` so the pages are usable and testable without the native
/// host.
class AgentStore {
  AgentStore(this.root);

  /// `.../var/minis`
  final Directory root;

  Directory get skillsDir => Directory(p.join(root.path, 'skills'));
  Directory get memoryDir => Directory(p.join(root.path, 'memory'));
  File get mcpConfigFile =>
      File(p.join(root.path, 'mcp-servers', 'servers.json'));

  static Future<AgentStore> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final sandbox = Directory(
      p.join(docs.path, 'alpine-rootfs', 'data', 'var', 'minis'),
    );
    if (sandbox.existsSync()) return AgentStore(sandbox);
    final fallback = Directory(p.join(docs.path, 'minis', 'var', 'minis'));
    fallback.createSync(recursive: true);
    return AgentStore(fallback);
  }

  // MARK: - Skills

  Future<List<SkillEntry>> listSkills() async {
    if (!skillsDir.existsSync()) return const [];
    final out = <SkillEntry>[];
    for (final entity in skillsDir.listSync()) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      final skillFile = File(p.join(entity.path, 'SKILL.md'));
      out.add(SkillEntry(
        id: name,
        name: name,
        description: skillFile.existsSync()
            ? _frontMatterField(skillFile.readAsStringSync(), 'description')
            : null,
        path: entity.path,
      ));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<String> readSkill(String id) async {
    final f = File(p.join(skillsDir.path, id, 'SKILL.md'));
    return f.existsSync() ? f.readAsStringSync() : '';
  }

  // MARK: - Memory

  Future<List<MemoryEntry>> listMemory() async {
    if (!memoryDir.existsSync()) return const [];
    final out = <MemoryEntry>[];
    for (final entity in memoryDir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final stat = entity.statSync();
      out.add(MemoryEntry(
        id: p.basenameWithoutExtension(entity.path),
        title: p.basenameWithoutExtension(entity.path),
        modifiedAt: stat.modified,
        path: entity.path,
        sizeBytes: stat.size,
      ));
    }
    // Most recent first — the Swift app shows today's log at the top.
    out.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return out;
  }

  Future<String> readMemory(String path) async {
    final f = File(path);
    return f.existsSync() ? f.readAsStringSync() : '';
  }

  // MARK: - MCP servers

  Future<List<McpServer>> listMcpServers() async {
    if (!mcpConfigFile.existsSync()) return const [];
    try {
      final decoded = jsonDecode(mcpConfigFile.readAsStringSync());
      final list = decoded is List
          ? decoded
          : (decoded is Map && decoded['servers'] is List
              ? decoded['servers'] as List
              : const []);
      final out = <McpServer>[];
      for (var i = 0; i < list.length; i++) {
        final raw = list[i];
        if (raw is! Map) continue;
        final name = (raw['name'] ?? raw['id'] ?? 'server ${i + 1}').toString();
        out.add(McpServer(
          id: name,
          name: name,
          url: (raw['url'] ?? raw['command'] ?? '').toString(),
          enabled: raw['enabled'] as bool? ?? true,
          transport: (raw['transport'] ?? raw['type'] ?? '').toString(),
        ));
      }
      return out;
    } catch (_) {
      // A corrupt file must not take the page down.
      return const [];
    }
  }

  /// Persists the enabled flag back into servers.json, preserving every other
  /// field the user (or the Swift app) wrote.
  Future<void> setMcpEnabled(String id, bool enabled) async {
    if (!mcpConfigFile.existsSync()) return;
    final decoded = jsonDecode(mcpConfigFile.readAsStringSync());
    if (decoded is! List) return;
    for (final raw in decoded) {
      if (raw is Map && (raw['name'] ?? raw['id']).toString() == id) {
        raw['enabled'] = enabled;
      }
    }
    await mcpConfigFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(decoded),
    );
  }

  /// Reads `description:` out of YAML front matter without a YAML dependency.
  static String? _frontMatterField(String source, String field) {
    final lines = source.split('\n');
    if (lines.isEmpty || lines.first.trim() != '---') return null;
    for (var i = 1; i < lines.length && i < 40; i++) {
      final line = lines[i];
      if (line.trim() == '---') break;
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      if (line.substring(0, idx).trim() == field) {
        return line.substring(idx + 1).trim();
      }
    }
    return null;
  }
}

class SkillEntry {
  const SkillEntry({
    required this.id,
    required this.name,
    required this.path,
    this.description,
  });

  final String id;
  final String name;
  final String path;
  final String? description;
}

class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.title,
    required this.modifiedAt,
    required this.path,
    required this.sizeBytes,
  });

  final String id;
  final String title;
  final DateTime modifiedAt;
  final String path;
  final int sizeBytes;
}

class McpServer {
  const McpServer({
    required this.id,
    required this.name,
    required this.url,
    required this.enabled,
    required this.transport,
  });

  final String id;
  final String name;
  final String url;
  final bool enabled;
  final String transport;
}
