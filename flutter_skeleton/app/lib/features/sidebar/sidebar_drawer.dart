import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/amore_theme.dart';
import '../../data/chat_models.dart';

/// ChatGPT-style sidebar: an independent glass layer that slides in from the
/// left while the conversation behind it shrinks and dims.
class SidebarDrawer extends StatelessWidget {
  const SidebarDrawer({
    super.key,
    required this.sessions,
    required this.selectedId,
    required this.onSelect,
    required this.onNewChat,
    required this.onSettings,
  });

  final List<ChatSessionSummary> sessions;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onNewChat;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      // Rounded only on the trailing edge — the panel emerges from the screen
      // edge, so the leading corners must stay square.
      borderRadius: const BorderRadius.horizontal(
        right: Radius.circular(AmoreTheme.rPanel),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: AmoreTheme.glass(0.72),
            border: Border(
              right: BorderSide(
                color: Colors.white.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
          ),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context),
                const Divider(height: 0.5, color: AmoreTheme.separator),
                Expanded(child: _sessionList(context)),
                _bottomBar(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
      child: Row(
        children: [
          const Text(
            'Amore',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: AmoreTheme.textPrimary,
            ),
          ),
          const Spacer(),
          _circleButton(
            icon: Icons.add,
            onTap: onNewChat,
            tooltip: 'New chat',
          ),
        ],
      ),
    );
  }

  Widget _sessionList(BuildContext context) {
    if (sessions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 0),
        child: Text(
          'No conversations yet',
          style: TextStyle(fontSize: 14, color: AmoreTheme.textSecondary),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      itemCount: sessions.length,
      itemBuilder: (context, i) {
        final s = sessions[i];
        final selected = s.id == selectedId;
        return _SessionRow(
          session: s,
          selected: selected,
          onTap: () => onSelect(s.id),
        );
      },
    );
  }

  Widget _bottomBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AmoreTheme.separator, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: onNewChat,
              child: Container(
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AmoreTheme.accent,
                  borderRadius: BorderRadius.circular(23),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.edit_outlined, size: 17, color: Colors.white),
                    SizedBox(width: 8),
                    Text(
                      'Chat',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _circleButton(
            icon: Icons.settings_outlined,
            onTap: onSettings,
            tooltip: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _circleButton({
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.05),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 18, color: AmoreTheme.textPrimary),
        ),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final ChatSessionSummary session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AmoreTheme.rChip),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        margin: const EdgeInsets.symmetric(vertical: 1),
        decoration: BoxDecoration(
          color: selected ? Colors.black.withValues(alpha: 0.06) : null,
          borderRadius: BorderRadius.circular(AmoreTheme.rChip),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15.5,
                color: AmoreTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _relative(session.updatedAt),
              style: const TextStyle(
                fontSize: 12,
                color: AmoreTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
  }
}
