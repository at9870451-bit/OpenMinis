import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/amore_theme.dart';
import '../data/chat_models.dart';
import '../data/chat_repository.dart';
import '../features/chat/chat_controller.dart';
import '../features/chat/chat_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sidebar/sidebar_drawer.dart';
import '../main.dart' show chatControllerProvider;

/// Root shell: the conversation is a card that recedes while the glass sidebar
/// slides in from the left. Progress `p` drives every layer, so the drag is
/// frame-synced rather than a binary animation.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

/// Opened once per app run; the same instance is shared by the sidebar and the
/// chat controller so a saved message is visible in both immediately.
final repositoryProvider = FutureProvider<ChatRepository>((ref) async {
  return openRepository();
});

/// Sessions for the sidebar, refreshed after every chat.
final sessionsProvider = FutureProvider<List<ChatSessionSummary>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return repo.sessions();
});

class _HomeShellState extends ConsumerState<HomeShell> {
  static const double _drawerFraction = 0.78;

  double _p = 0; // 0 closed, 1 open
  bool _dragging = false;

  void _settle() {
    setState(() {
      _dragging = false;
      _p = _p > 0.5 ? 1 : 0;
    });
  }

  void _openDrawer() => setState(() => _p = 1);
  void _closeDrawer() => setState(() => _p = 0);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final drawerWidth = size.width * _drawerFraction;
    final chat = ref.watch(chatControllerProvider);
    final sessions = ref.watch(sessionsProvider);

    // Attach the repository to the controller once it is ready, so messages
    // are persisted and history can be reopened.
    ref.listen(repositoryProvider, (previous, next) {
      next.whenData((repo) =>
          ref.read(chatControllerProvider.notifier).attachRepository(repo));
    });

    return Scaffold(
      backgroundColor: AmoreTheme.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              transform: Matrix4.identity()
                ..translate(size.width * 0.10 * _p, 0.0)
                ..scale(1 - 0.06 * _p),
              transformAlignment: Alignment.center,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24 * _p),
                child: Stack(
                  children: [
                    ChatPage(
                      messages: chat.messages,
                      streaming: chat.streaming,
                      onRegenerate: () => ref
                          .read(chatControllerProvider.notifier)
                          .regenerateLast(),
                      onSend: (t) async {
                        await ref.read(chatControllerProvider.notifier).send(t);
                        ref.invalidate(sessionsProvider);
                      },
                      onOpenSidebar: _openDrawer,
                    ),
                    if (_p > 0)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: Colors.black.withValues(alpha: 0.18 * _p),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_p > 0)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeDrawer,
                child: const SizedBox.expand(),
              ),
            ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: drawerWidth,
            child: AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(
                -drawerWidth * (1 - _p),
                0,
                0,
              ),
              child: SidebarDrawer(
                sessions: sessions.valueOrNull ?? const [],
                selectedId: ref.read(chatControllerProvider).messages.isEmpty
                    ? null
                    : null,
                onSelect: (id) async {
                  _closeDrawer();
                  final repo = await ref.read(repositoryProvider.future);
                  final controller = ref.read(chatControllerProvider.notifier);
                  controller.attachRepository(repo);
                  await controller.openSession(id);
                },
                onNewChat: () {
                  _closeDrawer();
                  ref.read(chatControllerProvider.notifier).newChat();
                },
                onSettings: () {
                  _closeDrawer();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsPage()),
                  );
                },
              ),
            ),
          ),
          if (_p == 0)
            Positioned(
              left: 0,
              top: 96,
              bottom: 96,
              width: 24,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) => setState(() => _dragging = true),
                onHorizontalDragUpdate: (d) {
                  setState(() {
                    _p = (_p + d.delta.dx / drawerWidth).clamp(0.0, 1.0);
                  });
                },
                onHorizontalDragEnd: (_) => _settle(),
              ),
            ),
        ],
      ),
    );
  }
}
