import 'package:flutter/material.dart';

import '../../core/theme/amore_theme.dart';
import 'appearance_page.dart';
import 'providers_page.dart';
import 'storage_page.dart';

/// Settings root, mirroring the section order of the SwiftUI app.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AmoreTheme.groupedBackground,
      appBar: AppBar(
        backgroundColor: AmoreTheme.groupedBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Settings',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _section(context, 'Models', [
            _row(
              context,
              icon: Icons.key_outlined,
              title: 'Providers & API Keys',
              subtitle: 'Catalog served by the Rust core',
              onTap: () => _push(context, const ProvidersPage()),
            ),
          ]),
          _section(context, 'Appearance', [
            _row(
              context,
              icon: Icons.contrast,
              title: 'Theme & Text Size',
              subtitle: 'Light, dark or follow the system',
              onTap: () => _push(context, const AppearancePage()),
            ),
          ]),
          _section(context, 'Data', [
            _row(
              context,
              icon: Icons.storage_outlined,
              title: 'Storage',
              subtitle: 'Chat database and cache',
              onTap: () => _push(context, const StoragePage()),
            ),
          ]),
          _section(context, 'Agent Runtime', [
            _row(context, icon: Icons.build_outlined, title: 'Agent Tools',
                subtitle: 'Native bridge (stage 5)'),
            _row(context, icon: Icons.people_outline, title: 'Sub Agents',
                subtitle: 'Native bridge (stage 5)'),
            _row(context, icon: Icons.extension_outlined, title: 'Skills',
                subtitle: 'Stage 5+'),
            _row(context, icon: Icons.memory_outlined, title: 'Memory',
                subtitle: 'Stage 5+'),
          ]),
          _section(context, 'About', [
            _row(context, icon: Icons.info_outline, title: 'Amore',
                subtitle: 'Flutter + Rust · 1.15'),
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
