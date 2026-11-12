import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/amore_theme.dart';
import '../features/settings/appearance_page.dart';
import 'home_shell.dart';

class AmoreApp extends ConsumerWidget {
  const AmoreApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Amore',
      debugShowCheckedModeBanner: false,
      theme: AmoreTheme.theme(),
      darkTheme: AmoreTheme.theme(),
      themeMode: mode,
      home: const HomeShell(),
    );
  }
}
