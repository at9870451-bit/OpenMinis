import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/amore_theme.dart';
import '../data/chat_models.dart';
import '../features/chat/chat_controller.dart';
import '../features/chat/chat_page.dart';
import '../features/sidebar/sidebar_drawer.dart';
import '../main.dart' show chatControllerProvider;

/// Root shell: the conversation is a card that recedes while the glass sidebar
/// slides in from the left. Progress `p` drives every layer, so the drag is
/// frame-synced rather than a binary animation.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, this.sessions = const []});

  final List<ChatSessionSummary> sessions;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

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
                      onSend: (t) =>
                          ref.read(chatControllerProvider.notifier).send(t),
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
                sessions: widget.sessions,
                selectedId: null,
                onSelect: (id) => _closeDrawer(),
                onNewChat: () {
                  _closeDrawer();
                  ref.read(chatControllerProvider.notifier).stop();
                },
                onSettings: _closeDrawer,
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
