import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'features/chat/chat_controller.dart';
import 'src/rust/frb_generated.dart';

/// Boot sequence that can never produce a blank screen.
///
/// `RustLib.init()` loads the native core. If the static library is missing
/// (e.g. a build that forgot to link it) the call throws — the old code awaited
/// it before `runApp`, so the app showed nothing at all. Now the UI always
/// renders and the failure is surfaced as a banner instead.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Object? rustError;
  try {
    await RustLib.init();
  } catch (e, st) {
    rustError = e;
    debugPrint('RustLib.init failed: $e\n$st');
  }

  runApp(ProviderScope(child: AmoreApp(rustError: rustError)));
}

/// Riverpod wiring for the conversation controller.
final chatControllerProvider =
    StateNotifierProvider<ChatController, ChatState>((ref) => ChatController());
