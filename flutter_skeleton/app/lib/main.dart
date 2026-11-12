import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'features/chat/chat_controller.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const ProviderScope(child: AmoreApp()));
}

/// Riverpod wiring for the conversation controller.
final chatControllerProvider =
    StateNotifierProvider<ChatController, ChatState>((ref) => ChatController());
