import 'package:flutter/material.dart';

import '../../core/theme/amore_theme.dart';
import '../../data/agent_store.dart';
import '../chat/markdown_message.dart';

/// Shared chrome for the three Agent Runtime pages.
class _AgentScaffold extends StatelessWidget {
  const _AgentScaffold({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AmoreTheme.groupedBackground,
      appBar: AppBar(
        backgroundColor: AmoreTheme.groupedBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        centerTitle: true,
        actions: trailing == null ? null : [trailing!],
      ),
      body: child,
    );
  }
}

Widget _empty(String text) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: AmoreTheme.textSecondary),
        ),
      ),
    );

// MARK: - Skills

class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key, required this.store});

  final AgentStore store;

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  List<SkillEntry>? _skills;

  @override
  void initState() {
    super.initState();
    widget.store.listSkills().then((v) {
      if (mounted) setState(() => _skills = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final skills = _skills;
    return _AgentScaffold(
      title: 'Skills',
      child: skills == null
          ? const Center(child: CircularProgressIndicator())
          : skills.isEmpty
              ? _empty('No skills installed.\n\nDrop a folder with SKILL.md into '
                  'var/minis/skills to add one.')
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: skills.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final s = skills[i];
                    return _card(
                      onTap: () async {
                        final body = await widget.store.readSkill(s.id);
                        if (!context.mounted) return;
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => _DocumentPage(
                            title: s.name,
                            body: body,
                          ),
                        ));
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.name,
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: AmoreTheme.textPrimary)),
                          if (s.description != null) ...[
                            const SizedBox(height: 4),
                            Text(s.description!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13,
                                    color: AmoreTheme.textSecondary)),
                          ],
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

// MARK: - Memory

class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key, required this.store});

  final AgentStore store;

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  List<MemoryEntry>? _entries;

  @override
  void initState() {
    super.initState();
    widget.store.listMemory().then((v) {
      if (mounted) setState(() => _entries = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return _AgentScaffold(
      title: 'Memory',
      child: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
              ? _empty('No memory files yet.')
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    return _card(
                      onTap: () async {
                        final body = await widget.store.readMemory(e.path);
                        if (!context.mounted) return;
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) =>
                              _DocumentPage(title: e.title, body: body),
                        ));
                      },
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(e.title,
                                    style: const TextStyle(
                                        fontSize: 15.5,
                                        color: AmoreTheme.textPrimary)),
                                const SizedBox(height: 3),
                                Text(
                                  '${_fmtBytes(e.sizeBytes)} · '
                                  '${e.modifiedAt.toString().split('.').first}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AmoreTheme.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              size: 18, color: AmoreTheme.textSecondary),
                        ],
                      ),
                    );
                  },
                ),
    );
  }

  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

// MARK: - MCP

class McpPage extends StatefulWidget {
  const McpPage({super.key, required this.store});

  final AgentStore store;

  @override
  State<McpPage> createState() => _McpPageState();
}

class _McpPageState extends State<McpPage> {
  List<McpServer>? _servers;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await widget.store.listMcpServers();
    if (mounted) setState(() => _servers = v);
  }

  @override
  Widget build(BuildContext context) {
    final servers = _servers;
    return _AgentScaffold(
      title: 'MCP Servers',
      child: servers == null
          ? const Center(child: CircularProgressIndicator())
          : servers.isEmpty
              ? _empty('No MCP servers configured.\n\n'
                  'Add entries to var/minis/mcp-servers/servers.json.')
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: servers.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final s = servers[i];
                    return _card(
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s.name,
                                    style: const TextStyle(
                                        fontSize: 15.5,
                                        color: AmoreTheme.textPrimary)),
                                const SizedBox(height: 3),
                                Text(
                                  s.url.isEmpty ? s.transport : s.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AmoreTheme.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: s.enabled,
                            activeThumbColor: Colors.white,
                            activeTrackColor: AmoreTheme.accent,
                            onChanged: (v) async {
                              await widget.store.setMcpEnabled(s.id, v);
                              await _load();
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

// MARK: - Shared bits

Widget _card({required Widget child, VoidCallback? onTap}) {
  final inner = Padding(padding: const EdgeInsets.all(14), child: child);
  return Material(
    color: AmoreTheme.background,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AmoreTheme.rCard),
      side: const BorderSide(color: AmoreTheme.separator, width: 0.5),
    ),
    child: onTap == null ? inner : InkWell(onTap: onTap, child: inner),
  );
}

class _DocumentPage extends StatelessWidget {
  const _DocumentPage({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return _AgentScaffold(
      title: title,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: body.trim().isEmpty
            ? _empty('This file is empty.')
            : MarkdownMessage(text: body),
      ),
    );
  }
}
