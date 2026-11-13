import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/theme/amore_theme.dart';
import '../../data/chat_models.dart';
import 'message_bubble.dart';

/// Conversation surface: message list + floating composer.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.messages,
    required this.onSend,
    required this.onOpenSidebar,
    this.onRegenerate,
    this.onEdit,
    this.placeholder,
    this.streaming = false,
  });

  final List<ChatMessage> messages;
  final ValueChanged<String> onSend;
  final VoidCallback onOpenSidebar;
  final VoidCallback? onRegenerate;
  final ValueChanged<String>? onEdit;
  final String? placeholder;
  final bool streaming;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final str = AppStrings.of(context);
    return Scaffold(
      backgroundColor: AmoreTheme.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _navBar(),
            Expanded(
              child: widget.messages.isEmpty
                  ? _emptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      itemCount: widget.messages.length,
                      itemBuilder: (context, i) => GestureDetector(
                        onLongPress: () =>
                            _showActions(context, widget.messages[i]),
                        child: MessageBubble(message: widget.messages[i]),
                      ),
                    ),
            ),
            _composer(),
          ],
        ),
      ),
    );
  }

  Widget _navBar() {
    final str = AppStrings.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AmoreTheme.separator, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onOpenSidebar,
            icon: const Icon(Icons.menu, size: 22),
            color: AmoreTheme.textPrimary,
            tooltip: 'History',
          ),
          const Spacer(),
          Text(
            str.appName,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AmoreTheme.textPrimary,
            ),
          ),
          const Spacer(),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _emptyState() {
    final str = AppStrings.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: AmoreTheme.secondaryBackground,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome,
                size: 28, color: AmoreTheme.accent),
          ),
          const SizedBox(height: 16),
          Text(
            str.howCanIHelp,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: AmoreTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            str.emptySubtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: AmoreTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    final str = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: AmoreTheme.background,
      child: Container(
        decoration: BoxDecoration(
          color: AmoreTheme.glass(0.82),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AmoreTheme.separator, width: 0.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 18,
              offset: Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _circle(Icons.add, onTap: () {}),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(
                    fontSize: 16, color: AmoreTheme.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: widget.placeholder ?? str.messageHint,
                  hintStyle: const TextStyle(
                      fontSize: 16, color: AmoreTheme.textSecondary),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            _hasText
                ? _sendButton()
                : _circle(Icons.mic_none, onTap: () {}),
          ],
        ),
      ),
    );
  }

  /// Long-press actions, mirroring the SwiftUI message menu.
  void _showActions(BuildContext context, ChatMessage message) {
    final str = AppStrings.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AmoreTheme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined, size: 20),
              title: Text(str.copy),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: message.text));
                if (sheet.mounted) Navigator.of(sheet).pop();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(str.copied),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                }
              },
            ),
            if (message.isUser && widget.onEdit != null)
              ListTile(
                leading: const Icon(Icons.edit_outlined, size: 20),
                title: Text(str.edit),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _controller.text = message.text;
                  setState(() {});
                  _focus.requestFocus();
                  widget.onEdit!(message.text);
                },
              ),
            if (!message.isUser && widget.onRegenerate != null)
              ListTile(
                leading: const Icon(Icons.refresh, size: 20),
                title: Text(str.regenerate),
                onTap: () {
                  Navigator.of(sheet).pop();
                  widget.onRegenerate!();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _sendButton() {
    return GestureDetector(
      onTap: _send,
      child: Container(
        width: 34,
        height: 34,
        decoration: const BoxDecoration(
          color: AmoreTheme.accent,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.arrow_upward, size: 18, color: Colors.white),
      ),
    );
  }

  Widget _circle(IconData icon, {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(17),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.05),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 18, color: AmoreTheme.textSecondary),
      ),
    );
  }
}
