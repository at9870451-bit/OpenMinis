import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/theme/amore_theme.dart';
import '../../core/native/ish_probe.dart';
import '../../data/agent_store.dart';
import '../agent/agent_pages.dart';
import 'appearance_page.dart';
import 'providers_page.dart';
import 'storage_page.dart';

/// One AgentStore per app run; pages share it so a toggle is visible elsewhere.
final agentStoreProvider = FutureProvider<AgentStore>((ref) => AgentStore.open());

/// Settings root, mirroring the section order of the SwiftUI app.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  Future<void> _openAgentPage(
    BuildContext context,
    WidgetRef ref,
    Widget Function(AgentStore) build,
  ) async {
    final store = await ref.read(agentStoreProvider.future);
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => build(store)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final str = AppStrings.of(context);
    return Scaffold(
      backgroundColor: AmoreTheme.groupedBackground,
      appBar: AppBar(
        backgroundColor: AmoreTheme.groupedBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(str.settings,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _section(context, str.models, [
            _row(
              context,
              icon: Icons.key_outlined,
              title: str.providersApiKeys,
              subtitle: str.providersSubtitle,
              onTap: () => _push(context, const ProvidersPage()),
            ),
          ]),
          _section(context, str.appearance, [
            _row(
              context,
              icon: Icons.contrast,
              title: str.themeTextSize,
              subtitle: str.themeSubtitle,
              onTap: () => _push(context, const AppearancePage()),
            ),
          ]),
          _section(context, str.data, [
            _row(
              context,
              icon: Icons.storage_outlined,
              title: str.storage,
              subtitle: str.storageSubtitle,
              onTap: () => _push(context, const StoragePage()),
            ),
          ]),
          _section(context, str.agentRuntime, [
            _row(context, icon: Icons.build_outlined, title: str.agentTools,
                subtitle: 'Native bridge (stage 5)'),
            _row(context, icon: Icons.people_outline, title: str.subAgents,
                subtitle: 'Native bridge (stage 5)'),
            _row(
              context,
              icon: Icons.extension_outlined,
              title: str.skills,
              subtitle: 'var/minis/skills',
              onTap: () => _openAgentPage(
                  context, ref, (store) => SkillsPage(store: store)),
            ),
            _row(
              context,
              icon: Icons.memory_outlined,
              title: str.memory,
              subtitle: 'var/minis/memory',
              onTap: () => _openAgentPage(
                  context, ref, (store) => MemoryPage(store: store)),
            ),
            _row(
              context,
              icon: Icons.hub_outlined,
              title: str.mcpServers,
              subtitle: 'mcp-servers/servers.json',
              onTap: () => _openAgentPage(
                  context, ref, (store) => McpPage(store: store)),
            ),
          ]),
          _section(context, str.about, [
            _row(
              context,
              icon: Icons.info_outline,
              title: str.appName,
              subtitle: IshProbe.isLinked
                  ? 'Flutter + Rust · iSH kernel linked'
                  : 'Flutter + Rust · 1.15',
            ),
          ]),
        ],
      ),
    );
  }

  static void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Widget _section(BuildContext context, String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: AmoreTheme.textSecondary,
            ),
          ),
        ),
        Material(
          color: AmoreTheme.background,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AmoreTheme.rCard),
            side: const BorderSide(color: AmoreTheme.separator, width: 0.5),
          ),
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                rows[i],
                if (i != rows.length - 1)
                  const Divider(
                    height: 0.5,
                    indent: 52,
                    color: AmoreTheme.separator,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: AmoreTheme.accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 16, color: AmoreTheme.accent),
      ),
      title: Text(title,
          style: const TextStyle(fontSize: 15.5, color: AmoreTheme.textPrimary)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style: const TextStyle(
                  fontSize: 12, color: AmoreTheme.textSecondary)),
      trailing: onTap == null
          ? null
          : const Icon(Icons.chevron_right,
              size: 18, color: AmoreTheme.textSecondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
    );
  }
}
